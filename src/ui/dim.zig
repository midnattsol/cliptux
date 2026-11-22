//! The dim outside a selection over a frozen capture, the same wherever
//! one is drawn (the editor, the record picker, the scrolling capture's
//! picker): the theme's dim, or a stronger one over a dark capture, where
//! the default barely shows and the selection would not stand out.
//!
//! Stable API:
//!   keepFor(px, w, h)            what the dim keeps for a capture, of 256
//!   dimRow(src, dst, keep)       one row darkened
//!   outside(px, w, h, r, keep)   a whole buffer darkened but for r

const std = @import("std");
const theme = @import("theme.zig");
const Rect = @import("shapes.zig").Rect;

/// Mean relative luminance below which a capture counts as dark
/// (about sRGB #595959 as a flat grey).
pub const dark_below: f64 = 0.1;

/// The share of each channel kept outside the selection, of 256 (see
/// dimRow), for a capture of `px` (w x h, 0xAARRGGBB).
pub fn keepFor(px: []const u32, w: u32, h: u32) u32 {
    const a = if (meanLuminance(px, w, h) < dark_below) theme.capture_dim_dark else theme.capture_dim;
    return 255 - (a >> 24);
}

/// `dst` = `src` darkened to `keep`/256, opaque (`dst` may be `src`).
pub fn dimRow(src: []const u32, dst: []u32, keep: u32) void {
    @setRuntimeSafety(false);
    for (src, dst) |p, *d| {
        const rb = ((p & 0x00FF00FF) * keep >> 8) & 0x00FF00FF;
        const g = ((p & 0x0000FF00) * keep >> 8) & 0x0000FF00;
        d.* = 0xFF000000 | rb | g;
    }
}

/// Darken `px` (w x h) to `keep`/256 in place, all but `bright`.
pub fn outside(px: []u32, w: u32, h: u32, bright: ?Rect, keep: u32) void {
    const wi: i32 = @intCast(w);
    for (0..h) |yu| {
        const row = px[yu * w ..][0..w];
        const y: i32 = @intCast(yu);
        const b = bright orelse {
            dimRow(row, row, keep);
            continue;
        };
        if (y < b.y or y >= b.y + b.h) {
            dimRow(row, row, keep);
            continue;
        }
        const x0: usize = @intCast(std.math.clamp(b.x, 0, wi));
        const x1: usize = @intCast(std.math.clamp(b.x + b.w, 0, wi));
        dimRow(row[0..x0], row[0..x0], keep);
        if (x1 > x0) dimRow(row[x1..], row[x1..], keep) else dimRow(row[x0..], row[x0..], keep);
    }
}

/// Mean relative luminance (0..1) of a grid of up to 64 x 64 samples.
pub fn meanLuminance(px: []const u32, w: u32, h: u32) f64 {
    if (w == 0 or h == 0 or px.len < @as(usize, w) * h) return 1;
    const nx: usize = @min(w, 64);
    const ny: usize = @min(h, 64);
    var sum: f64 = 0;
    for (0..ny) |j| {
        const y = (j * h + h / 2) / ny;
        for (0..nx) |i| {
            const x = (i * w + w / 2) / nx;
            sum += theme.luminance(px[y * w + x]);
        }
    }
    return sum / @as(f64, @floatFromInt(nx * ny));
}

test "dark captures are dimmed more" {
    var light: [16 * 9]u32 = @splat(0xFFF2F2F2);
    const dark: [16 * 9]u32 = @splat(0xFF1E1F22);
    try std.testing.expectEqual(@as(u32, 255 - (theme.capture_dim >> 24)), keepFor(&light, 16, 9));
    try std.testing.expectEqual(@as(u32, 255 - (theme.capture_dim_dark >> 24)), keepFor(&dark, 16, 9));
    // a light capture with a little dark content is still light
    for (light[0..20]) |*p| p.* = 0xFF000000;
    try std.testing.expect(meanLuminance(&light, 16, 9) > dark_below);
    try std.testing.expectEqual(@as(f64, 1), meanLuminance(&light, 0, 9));
}

test "outside leaves the bright part alone" {
    var px: [4 * 3]u32 = @splat(0xFFFFFFFF);
    outside(&px, 4, 3, .{ .x = 1, .y = 1, .w = 2, .h = 1 }, 128);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[5]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[6]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), px[4]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), px[7]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), px[1]);
    outside(&px, 4, 3, null, 256);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), px[1]);
}
