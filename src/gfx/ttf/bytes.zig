//! Bounds-checked big-endian reads from untrusted font bytes.

const std = @import("std");

pub fn beU16(d: []const u8, off: usize) error{Truncated}!u16 {
    if (off > d.len or d.len - off < 2) return error.Truncated;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

pub fn beI16(d: []const u8, off: usize) error{Truncated}!i16 {
    return @bitCast(try beU16(d, off));
}

pub fn beU32(d: []const u8, off: usize) error{Truncated}!u32 {
    if (off > d.len or d.len - off < 4) return error.Truncated;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

/// d[off..off+len] when it lies inside d.
pub fn sub(d: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > d.len or d.len - off < len) return null;
    return d[off..][0..len];
}
