//! The colour picker (eyedropper, I): a loupe at the pointer shows the
//! pixel grid and the colour under it; a click copies it as `#RRGGBB`,
//! Shift+click as `rgb(r, g, b)`, Alt+click makes it the annotation
//! colour. Picked colours are kept in the colour popover's history.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const theme = @import("../theme.zig");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const color = @import("color.zig");

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;

const cells = 11;

pub fn toggle(ed: *Editor) !void {
    if (ed.tools.mode == .eyedropper) {
        ed.tools.mode = .none;
    } else {
        try ed.settle();
        ed.closePopover();
        ed.tools.mode = .eyedropper;
    }
    ed.needs_render = true;
}

/// The composed pixel (annotations included) under buffer point `m`.
fn colorAt(ed: *const Editor, m: Point) ?u32 {
    const ip = ed.pn().view.toImg(m);
    if (ip.x < 0 or ip.y < 0 or ip.x >= ed.img.width or ip.y >= ed.img.height) return null;
    return ed.layer[@as(usize, @intCast(ip.y)) * ed.img.width + @as(usize, @intCast(ip.x))] | 0xFF000000;
}

/// A click while picking. True when it was the picker's.
pub fn onPress(ed: *Editor) !bool {
    if (ed.tools.mode != .eyedropper) return false;
    const c = colorAt(ed, ed.mouse) orelse return true;
    ed.tools.history.add(c);
    if (ed.mod_alt) return useColor(ed, c);
    try copy(ed, c, if (ed.mod_shift) .rgb else .hex);
    return true;
}

/// Make `c` the annotation colour (and the selected shape's).
pub fn useColor(ed: *Editor, c: u32) !bool {
    ed.custom_color = c;
    ed.custom_active = true;
    try ed.applyColor();
    var buf: [16]u8 = undefined;
    var msg: [48]u8 = undefined;
    ed.tools.toast.show(.info, std.fmt.bufPrint(&msg, "{s} is the annotation colour", .{color.hex(&buf, c)}) catch "", 2400);
    ed.tools.toast.swatch = c;
    ed.needs_render = true;
    return true;
}

fn copy(ed: *Editor, c: u32, f: color.Format) !void {
    var buf: [32]u8 = undefined;
    const s = color.format(&buf, c, f);
    const owned = try ed.alloc.dupe(u8, s);
    ed.win.setClipboardText(owned) catch |e| {
        ed.alloc.free(owned);
        std.log.warn("colour picker: copy failed: {t}", .{e});
        ed.tools.toast.show(.problem, "Copy failed", 2400);
        return;
    };
    std.log.info("colour picker: copied {s}", .{s});
    var msg: [64]u8 = undefined;
    ed.tools.toast.show(.done, std.fmt.bufPrint(&msg, "{s} copied", .{s}) catch s, 2400);
    ed.tools.toast.swatch = c;
    ed.needs_render = true;
}

fn cellSize(ed: *const Editor) i32 {
    return @max(5, ed.sc(11));
}

/// The loupe and its label, beside the pointer.
pub fn loupeRect(ed: *const Editor) ?Rect {
    if (ed.tools.mode != .eyedropper or !ed.isMousePane() or ed.help_open) return null;
    const m = ed.mouse;
    if (!ed.screenRect().contains(m.x, m.y)) return null;
    const size = cellSize(ed) * cells;
    const label_h = text_mod.height(theme.font_small * ed.uf()) + ed.sc(12);
    const total_h = size + ed.sc(6) + label_h;
    const w: i32 = @intCast(ed.pn().width);
    const h: i32 = @intCast(ed.pn().height);
    const off = ed.sc(22);
    var x = m.x + off;
    var y = m.y + off;
    if (x + size > w) x = m.x - off - size;
    if (y + total_h > h) y = m.y - off - total_h;
    return .{ .x = x, .y = y, .w = size, .h = total_h };
}

pub fn drawLoupe(ed: *Editor, canvas: *Canvas) void {
    const r = loupeRect(ed) orelse return;
    const f = ed.uf();
    const cell = cellSize(ed);
    const size = cell * cells;
    const lr = Rect{ .x = r.x, .y = r.y, .w = size, .h = size };
    canvas.fillRoundRectAA(lr.x - ed.sc(2), lr.y - ed.sc(1), size + ed.sc(4), size + ed.sc(4), 10 * f, 0x40000000);
    drawCells(ed, canvas, lr, cell);
    shapes.roundRectRing(canvas, lr.expand(ed.sc(3)), 10 * f + @as(f64, @floatFromInt(ed.sc(3))), @as(f64, @floatFromInt(ed.sc(6))) + 1, 0xFF1C1C1E);
    shapes.roundRectRing(canvas, lr, 8 * f, 1.5 * f, 0xE6FFFFFF);
    drawLabel(ed, canvas, r, size);
}

fn drawCells(ed: *Editor, canvas: *Canvas, lr: Rect, cell: i32) void {
    const half: i32 = cells / 2;
    const ip = ed.pn().view.toImg(ed.mouse);
    const iw: i32 = @intCast(ed.img.width);
    const ih: i32 = @intCast(ed.img.height);
    var cy: i32 = 0;
    while (cy < cells) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < cells) : (cx += 1) {
            const sx = ip.x - half + cx;
            const sy = ip.y - half + cy;
            const c: u32 = if (sx < 0 or sy < 0 or sx >= iw or sy >= ih) 0xFF101010 else ed.layer[@as(usize, @intCast(sy)) * ed.img.width + @as(usize, @intCast(sx))];
            canvas.fillRect(lr.x + cx * cell, lr.y + cy * cell, cell, cell, c | 0xFF000000);
        }
    }
    // the pixel grid, and the picked pixel framed in black and white
    var g: i32 = 1;
    while (g < cells) : (g += 1) {
        canvas.fillRect(lr.x + g * cell, lr.y, 1, lr.h, 0x1FFFFFFF);
        canvas.fillRect(lr.x, lr.y + g * cell, lr.w, 1, 0x1FFFFFFF);
    }
    const c0 = Rect{ .x = lr.x + half * cell, .y = lr.y + half * cell, .w = cell, .h = cell };
    canvas.rectOutline(c0.x - 2, c0.y - 2, c0.w + 4, c0.h + 4, 1, 0xFF000000);
    canvas.rectOutline(c0.x - 1, c0.y - 1, c0.w + 2, c0.h + 2, 1, 0xFFFFFFFF);
}

fn drawLabel(ed: *Editor, canvas: *Canvas, r: Rect, size: i32) void {
    const f = ed.uf();
    const th = ed.theme;
    const c = colorAt(ed, ed.mouse) orelse return;
    var buf: [16]u8 = undefined;
    const label = color.hex(&buf, c);
    const fs = theme.font_small * f;
    const sw = ed.sc(12);
    const lw = sw + ed.sc(6) + text_mod.width(fs, label) + ed.sc(20);
    const lh = text_mod.height(fs) + ed.sc(12);
    const lx = r.x + @divTrunc(size - lw, 2);
    const ly = r.y + size + ed.sc(6);
    canvas.fillRoundRectAA(lx, ly, lw, lh, @as(f64, @floatFromInt(lh)) / 2, th.pill_bg);
    const scy = ly + @divTrunc(lh - sw, 2);
    canvas.fillRoundRectAA(lx + ed.sc(10), scy, sw, sw, 3 * f, c);
    canvas.rectOutline(lx + ed.sc(10), scy, sw, sw, 1, 0x40FFFFFF);
    text_mod.draw(canvas, lx + ed.sc(10) + sw + ed.sc(6), ly + @divTrunc(lh - text_mod.height(fs), 2), fs, th.pill_fg, label);
}
