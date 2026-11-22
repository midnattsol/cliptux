//! Unix domain sockets, including fd passing (SCM_RIGHTS).

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const io = @import("io.zig");

const fd_t = common.fd_t;
const check = common.check;
const retryIntr = common.retryIntr;

const SCM_RIGHTS = 0x01;

pub fn socketUnixStream() !fd_t {
    const rc = try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    return @intCast(rc);
}

/// A filesystem unix socket address for `path`.
fn unixAddr(path: []const u8) !linux.sockaddr.un {
    var sa: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (path.len >= sa.path.len) return error.PathTooLong;
    @memcpy(sa.path[0..path.len], path);
    return sa;
}

pub fn connectUnix(fd: fd_t, path: []const u8) !void {
    const sa = try unixAddr(path);
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

/// Bind a listening unix stream socket at `path` (non-blocking accept).
pub fn listenUnix(path: []const u8) !fd_t {
    const fd = try check(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0));
    errdefer io.close(@intCast(fd));
    const sa = try unixAddr(path);
    const rc = linux.bind(@intCast(fd), @ptrCast(&sa), @sizeOf(linux.sockaddr.un));
    if (linux.errno(rc) == .ADDRINUSE) return error.AddressInUse;
    _ = try check(rc);
    _ = try check(linux.listen(@intCast(fd), 8));
    return @intCast(fd);
}

/// Accept one pending connection (null when none is waiting).
pub fn accept(fd: fd_t) !?fd_t {
    const rc = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(rc) == .AGAIN) return null;
    return @intCast(try check(rc));
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
        msg.controllen = @intCast(try packRights(&cmsg_buf, fds));
        msg.control = &cmsg_buf;
    }
    return retryIntr(linux.sendmsg, .{ fd, &msg, linux.MSG.NOSIGNAL });
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
    const n = try retryIntr(linux.recvmsg, .{ fd, &msg, linux.MSG.CMSG_CLOEXEC });
    if (n == 0) return 0;
    try unpackRights(&cmsg_buf, msg.controllen, out_fds, alloc);
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

/// Write one SCM_RIGHTS control message carrying `fds` into `cmsg_buf`;
/// returns the control length to send.
fn packRights(cmsg_buf: *align(8) [256]u8, fds: []const fd_t) !usize {
    const payload_len = fds.len * @sizeOf(fd_t);
    const cmsg_len = cmsgLen(payload_len);
    if (cmsg_len > cmsg_buf.len) return error.TooManyFds;
    const hdr: *cmsghdr = @ptrCast(cmsg_buf);
    hdr.len = cmsg_len;
    hdr.level = linux.SOL.SOCKET;
    hdr.type = SCM_RIGHTS;
    const fd_dest: [*]fd_t = @ptrCast(@alignCast(cmsg_buf[cmsgHdrSpace()..].ptr));
    for (fds, 0..) |f, i| fd_dest[i] = f;
    return cmsgSpace(payload_len);
}

/// Walk the received control messages and append every SCM_RIGHTS fd.
fn unpackRights(cmsg_buf: *align(8) const [256]u8, controllen: usize, out_fds: *std.ArrayList(fd_t), alloc: std.mem.Allocator) !void {
    var off: usize = 0;
    while (off + cmsgHdrSpace() <= controllen) {
        const hdr: *const cmsghdr = @ptrCast(@alignCast(cmsg_buf[off..].ptr));
        if (hdr.len < cmsgHdrSpace()) break;
        if (hdr.level == linux.SOL.SOCKET and hdr.type == SCM_RIGHTS) {
            const payload = hdr.len - cmsgHdrSpace();
            const count = payload / @sizeOf(fd_t);
            const fds_ptr: [*]const fd_t = @ptrCast(@alignCast(cmsg_buf[off + cmsgHdrSpace() ..].ptr));
            for (0..count) |i| try out_fds.append(alloc, fds_ptr[i]);
        }
        off += std.mem.alignForward(usize, hdr.len, @sizeOf(usize));
    }
}
