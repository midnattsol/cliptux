//! Path-based file operations (std.fs now requires an Io instance; raw
//! syscalls are simpler here).

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const io = @import("io.zig");

const fd_t = common.fd_t;
const check = common.check;
const pathZ = common.pathZ;
const openPath = common.openPath;

pub fn openRead(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

pub fn openRw(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
}

pub fn openAppend(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
}

pub fn createWrite(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
}

/// Create a new file that must not exist yet (O_EXCL, no symlink
/// following). Fails with error.PathAlreadyExists otherwise.
pub fn createExclusive(path: []const u8, mode: u32) !fd_t {
    return openPath(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, mode);
}

/// Write a whole new file with O_EXCL; removes the partial file on error.
pub fn writeFileExclusive(path: []const u8, data: []const u8, mode: u32) !void {
    const fd = try createExclusive(path, mode);
    errdefer unlink(path) catch {};
    defer io.close(fd);
    try io.writeAll(fd, data);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try createWrite(path);
    defer io.close(fd);
    try io.writeAll(fd, data);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try openRead(path);
    defer io.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try io.read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > max) return error.FileTooBig;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// Read a small file into `buf`, with no allocator; error.FileTooBig
/// when it does not fit.
pub fn readFileBuf(path: []const u8, buf: []u8) ![]u8 {
    const fd = try openRead(path);
    defer io.close(fd);
    var len: usize = 0;
    while (true) {
        if (len == buf.len) {
            var probe: [1]u8 = undefined;
            if (try io.read(fd, &probe) != 0) return error.FileTooBig;
            break;
        }
        const n = try io.read(fd, buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub fn unlink(path: []const u8) !void {
    var buf: [common.path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    _ = try check(linux.unlinkat(linux.AT.FDCWD, p.ptr, 0));
}

pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var oldz: [common.path_max]u8 = undefined;
    var newz: [common.path_max]u8 = undefined;
    const old = try pathZ(&oldz, old_path);
    const new = try pathZ(&newz, new_path);
    _ = try check(linux.renameat(linux.AT.FDCWD, old.ptr, linux.AT.FDCWD, new.ptr));
}

/// Seconds since the epoch of a file's last change; null when missing.
pub fn mtimeSec(path: []const u8) ?i64 {
    var buf: [common.path_max]u8 = undefined;
    const p = pathZ(&buf, path) catch return null;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.mtime.sec;
}

pub fn fileSize(path: []const u8) !u64 {
    var buf: [common.path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .SIZE = true }, &stx));
    return stx.size;
}

/// The permission bits of `path` (0o777 and the like); null when it
/// cannot be read.
pub fn fileMode(path: []const u8) ?u32 {
    var buf: [common.path_max]u8 = undefined;
    const p = pathZ(&buf, path) catch return null;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MODE = true }, &stx)) != .SUCCESS) return null;
    return stx.mode & 0o7777;
}

/// Create a symbolic link at `path` pointing to `target`.
pub fn symlink(target: []const u8, path: []const u8) !void {
    var tbuf: [common.path_max]u8 = undefined;
    var pbuf: [common.path_max]u8 = undefined;
    const t = try pathZ(&tbuf, target);
    const p = try pathZ(&pbuf, path);
    _ = try check(linux.symlinkat(t.ptr, linux.AT.FDCWD, p.ptr));
}
