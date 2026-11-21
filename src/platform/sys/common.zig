//! Shared plumbing for the syscall wrappers: errno mapping, EINTR retry
//! and NUL-terminated path buffers.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = i32;

/// Longest path (including the NUL) the wrappers accept.
pub const path_max = 4096;

pub fn check(rc: usize) !usize {
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

/// Call the raw syscall `f` with `args`, restarting it on EINTR.
pub inline fn retryIntr(comptime f: anytype, args: anytype) !usize {
    while (true) {
        const rc = @call(.auto, f, args);
        if (linux.errno(rc) == .INTR) continue;
        return try check(rc);
    }
}

/// Copy `path` into `buf` with a NUL terminator.
pub fn pathZ(buf: *[path_max]u8, path: []const u8) error{PathTooLong}![:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// openat(AT_FDCWD, path, flags, mode).
pub fn openPath(path: []const u8, flags: linux.O, mode: linux.mode_t) !fd_t {
    var buf: [path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    const rc = try check(linux.openat(linux.AT.FDCWD, p.ptr, flags, mode));
    return @intCast(rc);
}
