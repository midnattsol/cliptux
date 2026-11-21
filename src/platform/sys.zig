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
        .EXIST => error.PathAlreadyExists, // expected with O_EXCL
        .ACCES, .PERM => error.AccessDenied,
        .CONNREFUSED => error.ConnectionRefused,
        .NOTDIR => error.NotDir,
        .NOTEMPTY => error.DirNotEmpty,
        .TIMEDOUT => error.Timeout,
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

/// Connect to a socket in the Linux abstract namespace. The name has no
/// terminator and its length is part of the address, so the address length
/// must cover exactly the leading NUL plus the name.
pub fn connectUnixAbstract(fd: fd_t, name: []const u8) !void {
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (name.len + 1 > sa.path.len) return error.PathTooLong;
    @memcpy(sa.path[1..][0..name.len], name);
    const len = @offsetOf(linux.sockaddr.un, "path") + 1 + name.len;
    _ = try check(linux.connect(fd, @ptrCast(&sa), @intCast(len)));
}

/// A connected pair of unix stream sockets (close-on-exec).
pub fn socketPair() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    return fds;
}

/// Milliseconds on the monotonic clock; for deadlines.
pub fn monoMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Seconds since the epoch (UTC).
pub fn realtimeSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Fill `buf` from the kernel CSPRNG.
pub fn getRandom(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) {
            // only fails on pre-3.17 kernels; fall back to the clock
            const t: u64 = @bitCast(monoMs() ^ (realtimeSec() << 20));
            for (buf[off..], 0..) |*b, i| b.* = @truncate(t >> @intCast((i % 8) * 8));
            return;
        }
        off += rc;
    }
}

/// Poll timeout until `deadline_ms` (monotonic), or -1 when there is none.
pub fn timeoutUntil(deadline_ms: ?i64) i32 {
    const d = deadline_ms orelse return -1;
    const left = d - monoMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, std.math.maxInt(i32)));
}

/// Wait until `fd` is readable or the deadline passes. Returns false on
/// timeout. Hang-up and errors count as readable so the next read reports
/// them.
pub fn waitReadable(fd: fd_t, deadline_ms: ?i64) !bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const n = try poll(&fds, timeoutUntil(deadline_ms));
    return n > 0;
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

/// Like writeAll, but waits for fds that temporarily reject writes. Wayland
/// clipboard pipes can be non-blocking; closing them after EAGAIN truncates
/// large PNG transfers.
pub fn writeAllBlocking(fd: fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = try poll(&fds, -1);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.BrokenPipe;
        off += n;
    }
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

/// Create a new file that must not exist yet (O_EXCL, no symlink
/// following). Fails with error.PathAlreadyExists otherwise.
pub fn createExclusive(path: []const u8, mode: u32) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, mode));
    return @intCast(rc);
}

/// Write a whole new file with O_EXCL; removes the partial file on error.
pub fn writeFileExclusive(path: []const u8, data: []const u8, mode: u32) !void {
    const fd = try createExclusive(path, mode);
    errdefer unlink(path) catch {};
    defer close(fd);
    try writeAll(fd, data);
}

pub fn fsync(fd: fd_t) void {
    _ = linux.fsync(fd);
}

/// Open a directory for flock() or fsync().
pub fn openDir(path: []const u8) !fd_t {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
    return @intCast(rc);
}

/// Exclusive advisory lock; released by closing the fd.
pub fn lockExclusive(fd: fd_t) !void {
    while (true) {
        const rc = linux.flock(fd, 2); // LOCK_EX
        if (linux.errno(rc) == .INTR) continue;
        _ = try check(rc);
        return;
    }
}

/// Identity of an open file (device + inode).
pub const FileId = struct { dev_major: u32, dev_minor: u32, ino: u64 };

pub fn fileId(fd: fd_t) ?FileId {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .dev_major = stx.dev_major, .dev_minor = stx.dev_minor, .ino = stx.ino };
}

pub fn unlink(path: []const u8) !void {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = try check(linux.unlinkat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, 0));
}

pub fn mkdir(path: []const u8) void {
    mkdirMode(path, 0o755);
}

/// Best-effort mkdir with an explicit mode (existing directories are fine).
pub fn mkdirMode(path: []const u8, mode: u32) void {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = linux.mkdirat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, mode);
}

/// mkdir -p: creates missing parents (0755) and the leaf with `mode`.
pub fn mkdirAll(path: []const u8, mode: u32) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') mkdirMode(path[0..i], 0o755);
    }
    mkdirMode(path, mode);
}

/// Create a fresh private directory `<TMPDIR or /tmp>/<prefix>-<random>`.
/// Used by tests so parallel or repeated runs never share state.
pub fn makeTempDir(alloc: std.mem.Allocator, base: []const u8, prefix: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        getRandom(&rnd);
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}-{x}", .{ base, prefix, std.mem.readInt(u64, &rnd, .little) });
        var pathz: [4096]u8 = undefined;
        if (path.len >= pathz.len) {
            alloc.free(path);
            return error.PathTooLong;
        }
        @memcpy(pathz[0..path.len], path);
        pathz[path.len] = 0;
        const rc = linux.mkdirat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, 0o700);
        if (linux.errno(rc) == .SUCCESS) return path;
        alloc.free(path);
        if (linux.errno(rc) != .EXIST) return error.CannotCreateTempDir;
    }
    return error.CannotCreateTempDir;
}

/// rm -rf for a directory we created (tests only; does not follow symlinks).
pub fn removeTree(path: []const u8) void {
    removeTreeDepth(path, 0);
}

fn removeTreeDepth(path: []const u8, depth: usize) void {
    if (depth > 16) return;
    const dfd = openDir(path) catch {
        unlink(path) catch {};
        return;
    };
    var buf: [4096]u8 align(8) = undefined;
    var names: [64][256]u8 = undefined;
    var lens: [64]usize = undefined;
    var dirs: [64]bool = undefined;
    while (true) {
        // collect a batch, close nothing yet; then delete and re-read
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var count: usize = 0;
        var off: usize = 0;
        while (off < n and count < names.len) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += ent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (name.len >= 256) continue;
            @memcpy(names[count][0..name.len], name);
            lens[count] = name.len;
            dirs[count] = ent.type == 4; // DT_DIR
            count += 1;
        }
        if (count == 0) continue;
        for (0..count) |i| {
            var child: [4096]u8 = undefined;
            const cp = std.fmt.bufPrint(&child, "{s}/{s}", .{ path, names[i][0..lens[i]] }) catch continue;
            if (dirs[i]) removeTreeDepth(cp, depth + 1) else unlink(cp) catch {};
        }
        _ = linux.lseek(dfd, 0, 0); // SEEK_SET: rescan after deletions
    }
    close(dfd);
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, linux.AT.REMOVEDIR);
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
    const rc = try check(linux.openat(linux.AT.FDCWD, pathz[0..path.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600));
    return @intCast(rc);
}

/// Size of an open file.
pub fn fdSize(fd: fd_t) !u64 {
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx));
    return stx.size;
}

pub fn ftruncateFd(fd: fd_t, len: u64) void {
    _ = linux.ftruncate(fd, @intCast(len));
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) void {
    _ = linux.dup2(old_fd, new_fd);
}

pub fn exitProcess(code: u8) noreturn {
    linux.exit(code);
}

pub fn fileSize(path: []const u8) !u64 {
    var pathz: [4096]u8 = undefined;
    if (path.len >= pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, pathz[0..path.len :0].ptr, 0, .{ .SIZE = true }, &stx));
    return stx.size;
}
