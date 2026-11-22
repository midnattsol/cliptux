//! How much the editor darkens the capture outside the selection: the
//! theme's dim, or a stronger one over a dark capture, where the default
//! barely shows and the selection would not stand out.

const std = @import("std");
const theme = @import("../theme.zig");

/// Mean relative luminance below which a capture counts as dark
/// (about sRGB #595959 as a flat grey).
pub const dark_below: f64 = 0.1;

/// The share of each channel kept outside the selection, of 256 (see
/// caches.dimRow), for a capture of `px` (w x h, 0xAARRGGBB).
pub fn keepFor(px: []const u32, w: u32, h: u32) u32 {
    const a = if (meanLuminance(px, w, h) < dark_below) theme.capture_dim_dark else theme.capture_dim;
    return 255 - (a >> 24);
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
