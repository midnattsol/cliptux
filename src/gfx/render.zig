//! Software renderer over a 0xAARRGGBB pixel canvas: shapes, blending,
//! pixelation, text. All drawing is clipped to the canvas bounds.
//!
//! `Canvas` holds the pixels and the per-pixel blend; the drawing methods
//! are implemented in render/{basic, aa, stroke, bitmap_font}.zig.

const std = @import("std");
const pixel = @import("render/pixel.zig");
const basic = @import("render/basic.zig");
const aa = @import("render/aa.zig");
const stroke = @import("render/stroke.zig");
const bitmap_font = @import("render/bitmap_font.zig");

pub const Canvas = struct {
    px: []u32,
    w: i32,
    h: i32,
    /// optional w*h coverage scratch buffer enabling the fast stroke path
    mask: []u8 = &.{},

    pub fn init(px: []u32, w: u32, h: u32) Canvas {
        std.debug.assert(px.len >= @as(usize, w) * h);
        return .{ .px = px, .w = @intCast(w), .h = @intCast(h) };
    }

    pub inline fn set(self: *Canvas, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        self.px[@intCast(y * self.w + x)] = color | 0xFF000000;
    }

    pub inline fn blend(self: *Canvas, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i: usize = @intCast(y * self.w + x);
        self.px[i] = blendPixel(self.px[i], color);
    }

    /// Blend with an extra coverage factor in [0,1].
    pub inline fn blendCov(self: *Canvas, x: i32, y: i32, color: u32, cov: f64) void {
        if (!(cov > 0.003)) return;
        const a: f64 = @floatFromInt(color >> 24);
        const scaled: u32 = @intFromFloat(@min(255.0, a * cov + 0.5));
        self.blend(x, y, (color & 0x00FFFFFF) | (scaled << 24));
    }

    pub const blendPixel = pixel.blendPixel;

    // hard-edged primitives
    pub const fillRect = basic.fillRect;
    pub const rectOutline = basic.rectOutline;
    pub const fillCircle = basic.fillCircle;
    pub const line = basic.line;
    pub const arrow = basic.arrow;
    pub const fillTriangle = basic.fillTriangle;
    pub const ellipseOutline = basic.ellipseOutline;
    pub const pixelate = basic.pixelate;

    // anti-aliased primitives
    pub const fillCircleAA = aa.fillCircleAA;
    pub const ringAA = aa.ringAA;
    pub const fillRoundRectAA = aa.fillRoundRectAA;
    pub const strokePolylineAA = stroke.strokePolylineAA;
    pub const fillTriangleAA = aa.fillTriangleAA;
    pub const ellipseRingAA = aa.ellipseRingAA;
    pub const arrowAA = aa.arrowAA;

    // bitmap-font text
    pub const text = bitmap_font.text;
    pub const textWidth = bitmap_font.textWidth;
    pub const textHeight = bitmap_font.textHeight;
};

// keep the moved tests reachable from the test root
comptime {
    _ = @import("render/aa_test.zig");
}

test "fill and blend" {
    var pixels: [16]u32 = @splat(0xFF000000);
    var c = Canvas.init(&pixels, 4, 4);
    c.fillRect(0, 0, 2, 2, 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[3]);
    // 50% white over black ~ 0x7F gray
    c.fillRect(3, 3, 1, 1, 0x80FFFFFF);
    const p = pixels[15];
    try std.testing.expect(((p >> 16) & 0xFF) > 0x70 and ((p >> 16) & 0xFF) < 0x90);
}

test "primitives at extreme coordinates stay in bounds" {
    var px: [8 * 6]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 8, 6);
    var mask: [8 * 6]u8 = @splat(0);
    const big = std.math.maxInt(i32);
    const small = std.math.minInt(i32);
    const ints = [_]i32{ small, -1_000_000, -5, 0, 3, 7, 1_000_000, big };
    const floats = [_]f64{ -1e300, -1e9, -3.5, 0, 4.2, 1e9, 1e300, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (ints) |a| for (ints) |b| {
        c.fillRect(a, b, big, big, 0x80FFFFFF);
        c.fillRect(a, b, a, b, 0xFFFFFFFF);
        c.rectOutline(a, b, big, 9, big, 0xFF00FF00);
        c.rectOutline(b, a, 9, 9, 3, 0x8000FF00);
        c.fillCircle(a, b, 3, 0xFF0000FF);
        c.fillCircle(3, 3, @min(big, @abs(b)), 0xFF0000FF);
        c.line(a, b, b, a, 5, 0xFFFFFFFF);
        c.line(a, b, 3, 3, 1, 0x80FFFFFF);
        c.line(a, b, 4, 2, 7, 0x80FFFFFF);
        c.arrow(a, b, 4, 4, 3, 0xFFFFFFFF);
        c.arrow(4, 4, a, b, big, 0xFFFFFFFF);
        c.fillTriangle(a, b, b, a, 4, 4, 0xFF123456);
        c.ellipseOutline(a, b, 20, 20, 3, 0xFFABCDEF);
        c.ellipseOutline(-10, -10, @min(big, @abs(a)), 30, 1, 0xFFABCDEF);
        c.pixelate(a, b, big, big, b);
        c.fillRoundRectAA(a, b, big, big, 1e300, 0xFF654321);
        c.fillRoundRectAA(a, 2, 5, 5, std.math.nan(f64), 0xFF654321);
        c.ellipseRingAA(a, b, 40, 40, 3, 0xFF00FFFF);
        c.ellipseRingAA(-100, -100, 400, 300, 1e9, 0x8000FFFF);
        c.arrowAA(a, b, 4, 4, 3, 0xFFFF00FF);
        c.arrowAA(4, 4, a, b, big, 0xFFFF00FF);
        c.text(a, b, 3, 0xFFFFFFFF, "Hi\xFF");
        c.text(2, 2, big, 0xFFFFFFFF, "x");
        const pts = [_]struct { x: i32, y: i32 }{ .{ .x = a, .y = b }, .{ .x = 3, .y = 3 }, .{ .x = b, .y = a } };
        c.mask = &.{};
        c.strokePolylineAA(pts[0..], 4, 0x80FFFFFF);
        c.mask = &mask;
        c.strokePolylineAA(pts[0..], 4, 0x80FFFFFF);
        c.strokePolylineAA(pts[0..], 1e300, 0x80FFFFFF);
    };
    for (floats) |f| for (floats) |g| {
        c.fillCircleAA(f, g, 3, 0xFFFFFFFF);
        c.fillCircleAA(3, 3, f, 0xFFFFFFFF);
        c.ringAA(f, g, 2, 1, 0xFFFFFFFF);
        c.ringAA(3, 3, f, g, 0xFFFFFFFF);
        c.fillTriangleAA(f, g, g, f, 4, 4, 0xFFFFFFFF);
        c.ellipseRingAA(1, 1, 6, 4, f, 0xFFFFFFFF);
        c.blendCov(2, 2, 0xFFFFFFFF, f);
    };
    for (mask) |m| try std.testing.expectEqual(@as(u8, 0), m);
}
