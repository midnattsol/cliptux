//! Drawing laid-out text onto a canvas.

const std = @import("std");
const ttf = @import("../ttf.zig");
const bidi = @import("../bidi.zig");
const render = @import("../render.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");

const Canvas = render.Canvas;
const Style = state_mod.Style;
const no_font = state_mod.no_font;

/// Draw text with the top-left corner at (x, y).
pub fn draw(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    drawStyled(canvas, x, y, size_px, color, .regular, s);
}

/// Draw text in a given style (bold and monospace fall back to regular,
/// bold to a synthesized bold, when the system lacks those faces).
/// Right-to-left and mixed text is shaped and drawn in visual order.
pub fn drawStyled(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8) void {
    drawDir(canvas, x, y, size_px, color, style, s, .auto);
}

/// drawStyled with an explicit paragraph direction (for a line wrapped
/// out of a longer paragraph, whose direction comes from the paragraph).
pub fn drawDir(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8, dir: bidi.Direction) void {
    drawRange(canvas, x, y, size_px, color, style, s, 0, s.len, dir);
}

/// Draw the line made of bytes [la, lb) of paragraph `s`, shaped as part
/// of the whole paragraph (see `layout.layout`).
pub fn drawRange(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8, la: usize, lb: usize, dir: bidi.Direction) void {
    const st = if (state_mod.state) |*p| p else {
        canvas.text(x, y, state_mod.bitmapScale(size_px), color, s[@min(la, s.len)..@min(lb, s.len)]);
        return;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return;
    const items = layout.layoutRange(st, size_px, style, s, dir, la, lb) orelse return;
    const primary = st.styleSlot(style);
    const smear: i32 = if (st.fauxBold(style)) state_mod.fauxBoldOffset(size_px) else 0;
    const baseline = @as(f64, @floatFromInt(y)) + st.slots[primary].font.ascentPx(size_px);
    const x0: f64 = @floatFromInt(x);
    const right = @as(f64, @floatFromInt(canvas.w)) + 1024;
    for (items) |item| {
        if (item.slot == no_font) continue;
        const pen = x0 + item.gx;
        // far past the right edge: nothing more can show
        if (x0 + item.x > right) break;
        const g = st.slots[item.slot].font.rasterize(item.gid, size_px) catch continue;
        if (g.w > 0) {
            const gx = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
            const gy = @as(i32, @intFromFloat(@round(baseline + item.gy))) + g.bearing_y;
            var k: i32 = 0;
            while (k <= smear) : (k += 1) blitAlpha(canvas, gx + k, gy, g, color);
        }
    }
}

/// Blend glyph coverage onto the canvas, clipped to the canvas once up
/// front instead of per pixel.
fn blitAlpha(canvas: *Canvas, x0: i32, y0: i32, g: *const ttf.Glyph, color: u32) void {
    const base_a: u32 = color >> 24;
    const gx0 = @max(0, 0 -| x0);
    const gy0 = @max(0, 0 -| y0);
    const gx1 = @min(g.w, canvas.w -| x0);
    const gy1 = @min(g.h, canvas.h -| y0);
    if (gx0 >= gx1 or gy0 >= gy1) return;
    const rgb = color & 0x00FFFFFF;
    var gy = gy0;
    while (gy < gy1) : (gy += 1) {
        const src = g.alpha[@intCast(gy * g.w)..][0..@intCast(g.w)];
        const row: usize = @intCast((y0 + gy) * canvas.w + x0);
        var gx = gx0;
        while (gx < gx1) : (gx += 1) {
            const cov: u32 = src[@intCast(gx)];
            if (cov == 0) continue;
            const a = (base_a * cov + 127) / 255;
            const di = row + @as(usize, @intCast(gx));
            canvas.px[di] = Canvas.blendPixel(canvas.px[di], rgb | (a << 24));
        }
    }
}

test "text survives invalid utf-8 and odd sizes" {
    const measure = @import("measure.zig");
    const offsetForX = @import("caret.zig").offsetForX;
    const alloc = std.testing.allocator;
    state_mod.init(alloc);
    defer state_mod.deinit();
    var px: [64 * 32]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 64, 32);
    const bad = "save\xE2\x82 dir \xFF\xC3";
    draw(&c, 2, 2, 14, 0xFFFFFFFF, bad);
    _ = measure.width(14, bad);
    for ([_]Style{ .regular, .medium, .semibold, .bold, .mono, Style.regular.num() }) |st| {
        drawStyled(&c, -30, -10, 40, 0xFFFFFFFF, st, "Wg漢€");
        drawStyled(&c, 60, 30, 13, 0xFFFFFFFF, st, "edge");
        _ = measure.widthStyled(13, st, "x");
        _ = measure.heightStyled(13, st);
    }
    for ([_]f64{ 0, -5, std.math.nan(f64), std.math.inf(f64), 1e12 }) |sz| {
        draw(&c, 0, 0, sz, 0xFFFFFFFF, "abc");
        _ = measure.width(sz, "abc");
        _ = measure.height(sz);
    }
    try std.testing.expectEqual(@as(usize, 0), offsetForX(14, .regular, "abc", -5));
    try std.testing.expectEqual(@as(usize, 3), offsetForX(14, .regular, "abc", 1000));
}
