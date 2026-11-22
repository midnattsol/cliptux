//! The magnifier's label, a pill under the lens (the size pill's look):
//! the pixel's coordinates on the left, its colour as a swatch and
//! `#RRGGBB` on the right, in figures that do not jiggle. After C it
//! says "Copied" in place of the coordinates. Its width is fixed for the
//! picture (the widest coordinates and hex, or the lens's when that is
//! wider: one column), so it never twitches.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const selchrome = @import("../selchrome.zig");
const color = @import("../tools/color.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

const style = selchrome.size_style;

pub const Info = struct {
    /// the pixel (image coordinates) and its colour
    at: Point,
    color: u32,
    /// the colour was just copied
    copied: bool = false,
};

fn fontSize(ed: *const Editor) f64 {
    return theme.font_small * ed.uf();
}

/// The widest `#RRGGBB`: `#` and six of the widest hex digit.
fn hexWidth(fs: f64) i32 {
    var widest: i32 = 0;
    for ("0123456789ABCDEF") |c| widest = @max(widest, text_mod.widthStyled(fs, style, &.{c}));
    return text_mod.widthStyled(fs, style, "#") + 6 * widest;
}

/// The widest coordinates in this picture (tabular figures: its size).
fn coordsWidth(ed: *const Editor, fs: f64) i32 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}, {d}", .{ ed.img.width, ed.img.height }) catch "0000, 0000";
    return text_mod.widthStyled(fs, style, s);
}

fn swatch(ed: *const Editor) i32 {
    return ed.sc(10);
}

/// The narrowest the pill can be, and its height.
pub fn size(ed: *const Editor) [2]i32 {
    const fs = fontSize(ed);
    const w = 2 * pad(ed) + coordsWidth(ed, fs) + ed.sc(10) + swatch(ed) + ed.sc(5) + hexWidth(fs);
    return .{ w, text_mod.height(fs) + ed.sc(8) };
}

fn pad(ed: *const Editor) i32 {
    return ed.sc(9);
}

pub fn draw(ed: *const Editor, canvas: *Canvas, r: Rect, info: Info) void {
    const th = ed.theme;
    const f = ed.uf();
    const fs = fontSize(ed);
    selchrome.pill(canvas, r, 7 * f, th);
    const ty = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    const x0 = r.x + pad(ed);
    if (info.copied) {
        const ic = ed.sc(12);
        icons.draw(canvas, .check, x0, r.y + @divTrunc(r.h - ic, 2), ic, th.pill_fg);
        text_mod.drawStyled(canvas, x0 + ic + ed.sc(4), ty, fs, th.pill_fg, style, "Copied");
    } else {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}, {d}", .{ info.at.x, info.at.y }) catch "?";
        text_mod.drawStyled(canvas, x0, ty, fs, th.pill_fg, style, s);
    }
    var hb: [16]u8 = undefined;
    const hex = color.hex(&hb, info.color);
    const hx = r.right() - pad(ed) - hexWidth(fs);
    text_mod.drawStyled(canvas, hx, ty, fs, th.pill_fg, style, hex);
    const sw = swatch(ed);
    const sx = hx - ed.sc(5) - sw;
    const sy = r.y + @divTrunc(r.h - sw, 2);
    canvas.fillRoundRectAA(sx, sy, sw, sw, 2.5 * f, info.color | 0xFF000000);
    // a hairline keeps a swatch the pill's own colour visible
    shapes_mod.roundRectRing(canvas, .{ .x = sx, .y = sy, .w = sw, .h = sw }, 2.5 * f, @max(1, ff(ed.sc(1)) * 0.75), 0x4DFFFFFF);
}
