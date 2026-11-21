//! Text metrics: line widths, line height and ascent.

const std = @import("std");
const ttf = @import("../ttf.zig");
const bidi = @import("../bidi.zig");
const render = @import("../render.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");

const Canvas = render.Canvas;
const Style = state_mod.Style;
const bitmapScale = state_mod.bitmapScale;

pub fn width(size_px: f64, s: []const u8) i32 {
    return widthStyled(size_px, .regular, s);
}

pub fn widthStyled(size_px: f64, style: Style, s: []const u8) i32 {
    return widthDir(size_px, style, s, .auto);
}

pub fn widthDir(size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) i32 {
    return widthRange(size_px, style, s, 0, s.len, dir);
}

/// Width of the line made of bytes [la, lb) of paragraph `s`.
pub fn widthRange(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, dir: bidi.Direction) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s[@min(la, s.len)..@min(lb, s.len)]);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    layout.ensureShaped(st, size_px, style, s, dir) catch return 0;
    const total = layout.rangeAdvance(st, la, lb);
    if (!(total < 1e9)) return std.math.maxInt(i32) / 2;
    return @intFromFloat(@ceil(total));
}

pub fn height(size_px: f64) i32 {
    return heightStyled(size_px, .regular);
}

pub fn heightStyled(size_px: f64, style: Style) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const h = st.slots[st.styleSlot(style)].font.lineHeightPx(size_px);
    if (!(h >= 0 and h < 1e6)) return 0;
    return @intFromFloat(@ceil(h));
}

/// Distance from the top of a line to its baseline.
pub fn ascent(size_px: f64) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const a = st.slots[st.regular].font.ascentPx(size_px);
    if (!(a >= 0 and a < 1e6)) return 0;
    return @intFromFloat(@round(a));
}
