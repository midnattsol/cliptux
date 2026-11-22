//! Direct capture's pixels: wl_shm formats converted to 0xAARRGGBB, and
//! the output transform undone so the picture is upright.

const std = @import("std");

pub const Frame = struct { pixels: []u32, width: u32, height: u32 };

// wl_shm formats (DRM fourcc, except the first two)
pub const fmt_argb8888: u32 = 0;
pub const fmt_xrgb8888: u32 = 1;
pub const fmt_abgr8888: u32 = 0x34324241; // AB24
pub const fmt_xbgr8888: u32 = 0x34324258; // XB24
pub const fmt_argb2101010: u32 = 0x30335241; // AR30
pub const fmt_xrgb2101010: u32 = 0x30335258; // XR30
pub const fmt_abgr2101010: u32 = 0x30334241; // AB30
pub const fmt_xbgr2101010: u32 = 0x30334258; // XB30

/// How good a format is for us: 0 = not understood.
fn formatRank(f: u32) u8 {
    return switch (f) {
        fmt_xrgb8888, fmt_argb8888 => 3,
        fmt_xbgr8888, fmt_abgr8888 => 2,
        fmt_xrgb2101010, fmt_argb2101010, fmt_xbgr2101010, fmt_abgr2101010 => 1,
        else => 0,
    };
}

pub fn preferFormat(have: ?u32, offered: u32) ?u32 {
    const h = if (have) |x| formatRank(x) else 0;
    return if (formatRank(offered) > h) offered else have;
}

/// One 32-bit pixel of `format` as opaque 0xFFRRGGBB.
pub fn convert(format: u32, p: u32) u32 {
    return 0xFF000000 | switch (format) {
        fmt_xrgb8888, fmt_argb8888 => p & 0xFFFFFF,
        fmt_xbgr8888, fmt_abgr8888 => (p & 0x00FF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16),
        fmt_xrgb2101010, fmt_argb2101010 => (((p >> 22) & 0xFF) << 16) | (((p >> 12) & 0xFF) << 8) | ((p >> 2) & 0xFF),
        fmt_xbgr2101010, fmt_abgr2101010 => (((p >> 2) & 0xFF) << 16) | (((p >> 12) & 0xFF) << 8) | ((p >> 22) & 0xFF),
        else => 0,
    };
}

/// The buffer as upright 0xAARRGGBB pixels: formats converted, flipped
/// when y-inverted, and the output's transform applied so the picture
/// reads as the monitor shows it.
pub fn toFrame(gpa: std.mem.Allocator, mem: []const u8, format: u32, w: u32, h: u32, stride: u32, y_invert: bool, transform: u32) !Frame {
    const src = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(src);
    for (0..h) |y| {
        const sy = if (y_invert) h - 1 - y else y;
        const row = mem[sy * stride ..][0 .. w * 4];
        for (0..w) |x| src[y * w + x] = convert(format, std.mem.readInt(u32, row[x * 4 ..][0..4], .little));
    }
    return transformed(gpa, src, w, h, transform);
}

/// Apply a wl_output transform to a buffer: the buffer is what the
/// output's panel scans out, the result what the person sees.
fn transformed(gpa: std.mem.Allocator, src: []const u32, w: u32, h: u32, transform: u32) !Frame {
    const swap = transform & 1 != 0;
    const dw = if (swap) h else w;
    const dh = if (swap) w else h;
    const out = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..dh) |y| for (0..dw) |x| {
        const s = sourceOf(transform, @intCast(x), @intCast(y), w, h);
        out[y * dw + x] = src[@as(usize, s[1]) * w + s[0]];
    };
    return .{ .pixels = out, .width = dw, .height = dh };
}

/// The buffer pixel shown at (x, y) of the transformed picture: for
/// WL_OUTPUT_TRANSFORM_90 the picture's top row is the buffer's left
/// column read bottom to top (checked against sway's screencopy, which
/// hands out the untransformed buffer); "flipped" ones mirror around the
/// vertical axis.
fn sourceOf(transform: u32, x_in: u32, y: u32, w: u32, h: u32) [2]u32 {
    // the mirror applies to the picture, then the rotation is undone
    const swap = transform & 1 != 0;
    const x = if (transform & 4 != 0) (if (swap) h else w) - 1 - x_in else x_in;
    var sx: u32 = undefined;
    var sy: u32 = undefined;
    switch (transform & 3) {
        0 => {
            sx = x;
            sy = y;
        },
        1 => {
            sx = y;
            sy = h - 1 - x;
        },
        2 => {
            sx = w - 1 - x;
            sy = h - 1 - y;
        },
        3 => {
            sx = w - 1 - y;
            sy = x;
        },
        else => unreachable,
    }
    return .{ sx, sy };
}

test "formats convert to opaque RGB" {
    try std.testing.expectEqual(@as(u32, 0xFF112233), convert(fmt_xrgb8888, 0x00112233));
    try std.testing.expectEqual(@as(u32, 0xFF112233), convert(fmt_xbgr8888, 0x00332211));
    // 10 bits per channel: top 8 bits kept
    const r10: u32 = 0x3FC;
    const g10: u32 = 0x204;
    const b10: u32 = 0x004;
    try std.testing.expectEqual(@as(u32, 0xFFFF8101), convert(fmt_xrgb2101010, (r10 << 20) | (g10 << 10) | b10));
    try std.testing.expectEqual(@as(u32, 0xFFFF8101), convert(fmt_xbgr2101010, (b10 << 20) | (g10 << 10) | r10));
    try std.testing.expectEqual(@as(?u32, fmt_xrgb8888), preferFormat(fmt_xbgr2101010, fmt_xrgb8888));
    try std.testing.expectEqual(@as(?u32, fmt_xbgr8888), preferFormat(fmt_xbgr8888, 0x12345678));
}

test "transforms turn the buffer upright" {
    const gpa = std.testing.allocator;
    // a 3x2 buffer: a b c / d e f
    const src = [_]u32{ 'a', 'b', 'c', 'd', 'e', 'f' };
    const cases = [_]struct { t: u32, w: u32, want: []const u8 }{
        .{ .t = 0, .w = 3, .want = "abcdef" },
        .{ .t = 1, .w = 2, .want = "daebfc" },
        .{ .t = 2, .w = 3, .want = "fedcba" },
        .{ .t = 3, .w = 2, .want = "cfbead" },
        .{ .t = 4, .w = 3, .want = "cbafed" },
    };
    for (cases) |cs| {
        const f = try transformed(gpa, &src, 3, 2, cs.t);
        defer gpa.free(f.pixels);
        try std.testing.expectEqual(cs.w, f.width);
        for (f.pixels, cs.want) |p, ch| try std.testing.expectEqual(@as(u32, ch), p);
    }
}
