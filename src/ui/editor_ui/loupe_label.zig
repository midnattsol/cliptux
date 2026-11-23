//! The magnifier's label, a pill under the lens (the size pill's look),
//! shown on demand (Alt, the colour picker, after C): the pixel's colour
//! as a swatch and `#RRGGBB`, in figures that do not jiggle. After C it
//! says "Copied" instead. Its width is fixed (the widest hex), so it
//! never twitches.

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

const style = selchrome.size_style;
const copied_text = "Copied";

pub const Info = struct {
    /// the pixel's colour
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

/// The swatch (or the check) and the gap after it.
fn lead(ed: *const Editor) [2]i32 {
    return .{ ed.sc(10), ed.sc(6) };
}

fn pad(ed: *const Editor) i32 {
    return ed.sc(9);
}

/// The pill's width and height.
pub fn size(ed: *const Editor) [2]i32 {
    const fs = fontSize(ed);
    const l = lead(ed);
    const body = @max(hexWidth(fs), text_mod.widthStyled(fs, style, copied_text) + ed.sc(2));
    return .{ 2 * pad(ed) + l[0] + l[1] + body, text_mod.height(fs) + ed.sc(8) };
}

pub fn draw(ed: *const Editor, canvas: *Canvas, r: Rect, info: Info) void {
    const th = ed.theme;
    const f = ed.uf();
    const fs = fontSize(ed);
    selchrome.pill(canvas, r, 7 * f, th);
    const ty = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    const l = lead(ed);
    const x0 = r.x + pad(ed);
    const tx = x0 + l[0] + l[1];
    if (info.copied) {
        const ic = ed.sc(12);
        icons.draw(canvas, .check, x0 - ed.sc(1), r.y + @divTrunc(r.h - ic, 2), ic, th.pill_fg);
        text_mod.drawStyled(canvas, tx, ty, fs, th.pill_fg, style, copied_text);
        return;
    }
    var hb: [16]u8 = undefined;
    text_mod.drawStyled(canvas, tx, ty, fs, th.pill_fg, style, color.hex(&hb, info.color));
    const sw = l[0];
    const sy = r.y + @divTrunc(r.h - sw, 2);
    canvas.fillRoundRectAA(x0, sy, sw, sw, 2.5 * f, info.color | 0xFF000000);
    // a hairline keeps a swatch the pill's own colour visible
    shapes_mod.roundRectRing(canvas, .{ .x = x0, .y = sy, .w = sw, .h = sw }, 2.5 * f, @max(1, ff(ed.sc(1)) * 0.75), 0x4DFFFFFF);
}
