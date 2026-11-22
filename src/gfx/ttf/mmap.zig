//! Read-only memory mapping of font files.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../../platform/linux/sys.zig");

/// Map the whole file at `path` read-only (12 bytes .. 256 MiB).
pub fn mapFile(path: []const u8) ![]const u8 {
    const fd = try sys.openRead(path);
    defer sys.close(fd);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS) return error.StatFailed;
    if (stx.size < 12 or stx.size > 256 * 1024 * 1024) return error.BadSize;
    const len: usize = @intCast(stx.size);
    const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    const ptr: [*]const u8 = @ptrFromInt(rc);
    return ptr[0..len];
}

pub fn unmap(d: []const u8) void {
    const p: [*]align(std.heap.page_size_min) const u8 = @alignCast(d.ptr);
    _ = linux.munmap(p, d.len);
}
