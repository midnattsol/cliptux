//! Read-only memory mapping of font files (through api.sys).

const sys = @import("../../platform/api.zig").sys;

/// Map the whole file at `path` read-only (12 bytes .. 256 MiB).
pub fn mapFile(path: []const u8) ![]const u8 {
    return sys.mapFile(path, 12, 256 * 1024 * 1024);
}

pub fn unmap(d: []const u8) void {
    sys.unmapFile(d);
}
