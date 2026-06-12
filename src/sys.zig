//! Thin error-checked wrappers over raw linux syscalls (Zig 0.16 moved most
//! of these out of std.posix).

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = i32;

fn check(rc: usize) !usize {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return rc;
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .INTR => error.Interrupted,
        .NOENT => error.NotFound, // expected for optional files; no logging
        else => {
            std.log.err("syscall failed: {t}", .{e});
            return error.SyscallFailed;
        },
    };
}

pub fn socketUnixStream() !fd_t {
    const rc = try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    return @intCast(rc);
}

pub fn connectUnix(fd: fd_t, path: []const u8) !void {
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= sa.path.len) return error.PathTooLong;
    @memcpy(sa.path[0..path.len], path);
    _ = try check(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un)));
}

pub fn read(fd: fd_t, buf: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        return try check(rc);
    }
}

pub fn write(fd: fd_t, buf: []const u8) !usize {
    while (true) {
        const rc = linux.write(fd, buf.ptr, buf.len);
        if (linux.errno(rc) == .INTR) continue;
        return try check(rc);
    }
}

pub fn writeAll(fd: fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) off += try write(fd, buf[off..]);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn poll(fds: []linux.pollfd, timeout_ms: i32) !usize {
    while (true) {
        const rc = linux.poll(fds.ptr, fds.len, timeout_ms);
        if (linux.errno(rc) == .INTR) continue;
        return try check(rc);
    }
}

pub const pollfd = linux.pollfd;
pub const POLL = linux.POLL;

pub const MFD_CLOEXEC: u32 = 1;

pub fn memfdCreate(name: [*:0]const u8, flags: u32) !fd_t {
    const rc = try check(linux.memfd_create(name, flags));
    return @intCast(rc);
}

pub fn ftruncate(fd: fd_t, len: u64) !void {
    _ = try check(linux.ftruncate(fd, @intCast(len)));
}

pub fn mmapRw(fd: fd_t, len: usize) ![]align(std.heap.page_size_min) u8 {
    const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    _ = try check(rc);
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr[0..len];
}

pub fn munmap(mem: []align(std.heap.page_size_min) const u8) void {
    _ = linux.munmap(mem.ptr, mem.len);
}

/// Send bytes with optional fds as SCM_RIGHTS ancillary data.
pub fn sendWithFds(fd: fd_t, data: []const u8, fds: []const fd_t) !usize {
    var iov = [_]std.posix.iovec_const{.{ .base = data.ptr, .len = data.len }};
    var cmsg_buf: [256]u8 align(8) = @splat(0);
    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (fds.len > 0) {
        const payload_len = fds.len * @sizeOf(fd_t);
        const cmsg_len = cmsgLen(payload_len);
        if (cmsg_len > cmsg_buf.len) return error.TooManyFds;
        const hdr: *cmsghdr = @ptrCast(&cmsg_buf);
        hdr.len = cmsg_len;
        hdr.level = linux.SOL.SOCKET;
        hdr.type = 0x01; // SCM_RIGHTS
        const fd_dest: [*]fd_t = @ptrCast(@alignCast(cmsg_buf[cmsgHdrSpace()..].ptr));
        for (fds, 0..) |f, i| fd_dest[i] = f;
        msg.control = &cmsg_buf;
        msg.controllen = @intCast(cmsgSpace(payload_len));
    }
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        if (linux.errno(rc) == .INTR) continue;
        return try check(rc);
    }
}

/// Receive bytes; any fds received via SCM_RIGHTS are appended to out_fds.
pub fn recvWithFds(fd: fd_t, buf: []u8, out_fds: *std.ArrayList(fd_t), alloc: std.mem.Allocator) !usize {
    var iov = [_]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var cmsg_buf: [256]u8 align(8) = @splat(0);
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };
    var n: usize = 0;
    while (true) {
        const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC);
        if (linux.errno(rc) == .INTR) continue;
        n = try check(rc);
        break;
    }
    if (n == 0) return 0;
    // walk control messages
    var off: usize = 0;
    while (off + cmsgHdrSpace() <= msg.controllen) {
        const hdr: *const cmsghdr = @ptrCast(@alignCast(cmsg_buf[off..].ptr));
        if (hdr.len < cmsgHdrSpace()) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.type == 0x01) {
            const payload = hdr.len - cmsgHdrSpace();
            const count = payload / @sizeOf(fd_t);
            const fds_ptr: [*]const fd_t = @ptrCast(@alignCast(cmsg_buf[off + cmsgHdrSpace() ..].ptr));
            for (0..count) |i| try out_fds.append(alloc, fds_ptr[i]);
        }
        off += std.mem.alignForward(usize, hdr.len, @sizeOf(usize));
    }
    return n;
}

const cmsghdr = extern struct {
    len: usize,
    level: i32,
    type: i32,
};

fn cmsgHdrSpace() usize {
    return std.mem.alignForward(usize, @sizeOf(cmsghdr), @sizeOf(usize));
}
fn cmsgLen(payload: usize) usize {
    return cmsgHdrSpace() + payload;
}
fn cmsgSpace(payload: usize) usize {
    return cmsgHdrSpace() + std.mem.alignForward(usize, payload, @sizeOf(usize));
}

pub fn getuid() u32 {
    return linux.getuid();
}

// --- file helpers (std.fs now requires an Io instance; raw syscalls are simpler here) ---

pub fn openRead(path: []const u8) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    return @intCast(rc);
}

pub fn createWrite(path: []const u8) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644));
    return @intCast(rc);
}

pub fn unlink(path: []const u8) !void {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = try check(linux.unlinkat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, 0));
}

pub fn mkdir(path: []const u8) void {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = linux.mkdirat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, 0o755);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try openRead(path);
    defer close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > max) return error.FileTooBig;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try createWrite(path);
    defer close(fd);
    try writeAll(fd, data);
}

pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var oldz: [4096]u8 = undefined;
    var newz: [4096]u8 = undefined;
    if (old_path.len >= oldz.len or new_path.len >= newz.len) return error.PathTooLong;
    @memcpy(oldz[0..old_path.len], old_path);
    oldz[old_path.len] = 0;
    @memcpy(newz[0..new_path.len], new_path);
    newz[new_path.len] = 0;
    _ = try check(linux.renameat(linux.AT.FDCWD, oldz[0..old_path.len :0].ptr, linux.AT.FDCWD, newz[0..new_path.len :0].ptr));
}

pub fn fork() !i32 {
    const rc = linux.fork();
    _ = try check(rc);
    return @intCast(rc);
}

pub fn setsid() void {
    _ = linux.setsid();
}

pub fn chdirRoot() void {
    _ = linux.chdir("/");
}

pub fn openRw(path: []const u8) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    return @intCast(rc);
}

pub fn openAppend(path: []const u8) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644));
    return @intCast(rc);
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) void {
    _ = linux.dup2(old_fd, new_fd);
}

pub fn exitProcess(code: u8) noreturn {
    linux.exit(code);
}
