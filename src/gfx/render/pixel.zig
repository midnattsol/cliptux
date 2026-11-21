//! Pixel-level helpers shared by the rasterizers: src-over blending,
//! row spans and float-to-pixel coordinate clamping.

const Canvas = @import("../render.zig").Canvas;

/// f64 -> i32 for pixel coordinates: clamps far-off (and NaN) values to
/// +-1e9 so callers never hit an out-of-range @intFromFloat.
pub fn toI32(v: f64) i32 {
    if (!(v > -1e9)) return -1_000_000_000;
    if (v > 1e9) return 1_000_000_000;
    return @intFromFloat(v);
}

/// Exact x/255 for x <= 65407, without a division.
inline fn div255(x: u32) u32 {
    return (x + 128 + ((x + 128) >> 8)) >> 8;
}

/// src-over blend of `src` (with alpha) onto opaque dst.
pub fn blendPixel(dst: u32, src: u32) u32 {
    const a: u32 = src >> 24;
    if (a == 255) return src | 0xFF000000;
    if (a == 0) return dst;
    const inv = 255 - a;
    const sr = (src >> 16) & 0xFF;
    const sg = (src >> 8) & 0xFF;
    const sb = src & 0xFF;
    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;
    const r = div255(sr * a + dr * inv);
    const g = div255(sg * a + dg * inv);
    const b = div255(sb * a + db * inv);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Index range [a, b] (inclusive) of pixels whose centres can lie in
/// [lo, hi], clipped to 0..max-1; null when empty or NaN.
pub fn span(lo: f64, hi: f64, max: i32) ?[2]i32 {
    if (!(lo <= hi)) return null;
    const a = @max(0.0, @floor(lo));
    const b = @min(@as(f64, @floatFromInt(max - 1)), @ceil(hi));
    if (!(a <= b)) return null;
    return .{ @intFromFloat(a), @intFromFloat(b) };
}

/// Blend `color` over pixels xa..xb (inclusive, already clipped) of row y.
pub inline fn hspan(c: *Canvas, xa: i32, xb: i32, y: i32, color: u32) void {
    fillRow(c.px[@intCast(y * c.w + xa)..@intCast(y * c.w + xb + 1)], color);
}

/// Fill a row slice with `color`: a memset when opaque, else src-over.
pub inline fn fillRow(row: []u32, color: u32) void {
    if (color >> 24 == 255) {
        @memset(row, color);
    } else {
        for (row) |*p| p.* = blendPixel(p.*, color);
    }
}
