//! Text in the built-in 5x7 bitmap font, drawn as scaled pixel blocks.

const std = @import("std");
const font = @import("../font.zig");
const utf8 = @import("../utf8.zig");
const Canvas = @import("../render.zig").Canvas;
const fillRect = @import("basic.zig").fillRect;

/// Bitmap-font byte for a codepoint: ASCII as is, anything else '?'.
fn bitmapChar(cp: u21) u8 {
    return if (cp >= 32 and cp <= 126) @intCast(cp) else '?';
}

pub fn text(c: *Canvas, x0: i32, y0: i32, scale: i32, color: u32, s: []const u8) void {
    if (scale >= 2) {
        textSmooth(c, x0, y0, scale, color, s);
        return;
    }
    var pen_x = x0;
    var it = utf8.Iterator.init(s);
    while (it.next()) |cp| {
        if (pen_x >= c.w) break;
        const g = font.glyphFor(bitmapChar(cp));
        for (g, 0..) |row, gy| {
            var gx: u3 = 0;
            while (gx < font.glyph_w) : (gx += 1) {
                if (row & (@as(u8, 0x10) >> gx) != 0) {
                    fillRect(
                        c,
                        pen_x +| @as(i32, gx) *| scale,
                        y0 +| @as(i32, @intCast(gy)) *| scale,
                        scale,
                        scale,
                        color,
                    );
                }
            }
        }
        pen_x +|= (font.glyph_w + 1) *| scale;
    }
}

/// EPX/Scale2x-smoothed text for even scales: doubles the glyph bitmap
/// with diagonal interpolation, then draws blocks of scale/2. Removes the
/// staircase look of the 5x7 font at display sizes.
fn textSmooth(c: *Canvas, x0: i32, y0: i32, scale: i32, color: u32, s: []const u8) void {
    var pen_x = x0;
    var it = utf8.Iterator.init(s);
    while (it.next()) |cp| {
        if (pen_x >= c.w) break;
        const g = font.glyphFor(bitmapChar(cp));
        var gy: i32 = 0;
        while (gy < font.glyph_h) : (gy += 1) {
            var gx: i32 = 0;
            while (gx < font.glyph_w) : (gx += 1) {
                drawQuads(c, pen_x +| gx *| scale, y0 +| gy *| scale, scale, color, epx(g, gx, gy));
            }
        }
        pen_x +|= (font.glyph_w + 1) *| scale;
    }
}

/// Glyph bit at (gx, gy); false outside the glyph.
inline fn glyphBit(glyph: *const font.Glyph, gx: i32, gy: i32) bool {
    if (gx < 0 or gy < 0 or gx >= font.glyph_w or gy >= font.glyph_h) return false;
    return glyph[@intCast(gy)] & (@as(u8, 0x10) >> @intCast(gx)) != 0;
}

/// EPX expansion of glyph cell (gx, gy) into its four subcells:
/// top-left, top-right, bottom-left, bottom-right.
inline fn epx(g: *const font.Glyph, gx: i32, gy: i32) [4]bool {
    const p = glyphBit(g, gx, gy);
    const a = glyphBit(g, gx, gy - 1); // up
    const b = glyphBit(g, gx + 1, gy); // right
    const cl = glyphBit(g, gx - 1, gy); // left
    const d = glyphBit(g, gx, gy + 1); // down
    var q = [4]bool{ p, p, p, p };
    if (cl == a and cl != d and a != b) q[0] = a;
    if (a == b and a != cl and b != d) q[1] = b;
    if (d == cl and d != b and cl != a) q[2] = cl;
    if (b == d and b != a and d != cl) q[3] = d;
    return q;
}

/// Fill the set subcells of the scale x scale block at (bx, by); the
/// first subcell of each axis gets the odd pixel.
inline fn drawQuads(c: *Canvas, bx: i32, by: i32, scale: i32, color: u32, q: [4]bool) void {
    const ha = scale - @divTrunc(scale, 2); // first subcell (ceil)
    const hb = scale - ha; // second subcell
    if (q[0]) fillRect(c, bx, by, ha, ha, color);
    if (q[1]) fillRect(c, bx +| ha, by, hb, ha, color);
    if (q[2]) fillRect(c, bx, by +| ha, ha, hb, color);
    if (q[3]) fillRect(c, bx +| ha, by +| ha, hb, hb, color);
}

pub fn textWidth(scale: i32, s: []const u8) i32 {
    const n: i64 = @intCast(utf8.count(s));
    return @intCast(@min(std.math.maxInt(i32), n * (font.glyph_w + 1) * scale));
}

pub fn textHeight(scale: i32) i32 {
    return font.glyph_h * scale;
}
