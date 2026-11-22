//! The magnifier loupe: the pixels around the pointer, enlarged on a
//! grid, with the coordinates (or the selection size while dragging).

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

pub fn loupeVisible(self: *const Editor) bool {
    if (self.help_open or self.tools.mode != .none) return false;
    const m = self.mouse;
    if (!self.screenRect().contains(m.x, m.y)) return false;
    return switch (self.drag) {
        .selecting, .resizing_sel => true,
        .none => self.doc.sel == null,
        else => false,
    };
}

const loupe_cells = 15;

pub fn loupeRect(self: *const Editor) ?Rect {
    if (!loupeVisible(self)) return null;
    const cell = @max(4, self.sc(8));
    const size = cell * loupe_cells;
    const label_h = text_mod.height(theme.font_small * self.uf()) + self.sc(8);
    const total_h = size + self.sc(6) + label_h;
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const off = self.sc(24);
    var x = self.mouse.x + off;
    var y = self.mouse.y + off;
    if (x + size > w) x = self.mouse.x - off - size;
    if (y + total_h > h) y = self.mouse.y - off - total_h;
    return .{ .x = x, .y = y, .w = size, .h = total_h };
}

/// Everything drawLoupe paints, for the repaint: the dark ring reaches
/// past loupeRect on every side, and the label can be wider than it.
/// (Covering only loupeRect left a trail of ring edges behind the
/// pointer.)
pub fn loupeFootprint(self: *const Editor) ?Rect {
    const r = loupeRect(self) orelse return null;
    const size = r.w;
    const lens = Rect{ .x = r.x, .y = r.y, .w = size, .h = size };
    // the ring is drawn inside lens.expand(ringOut), its anti-aliased
    // edge one pixel further; the shadow stays within that
    var buf: [64]u8 = undefined;
    const label = labelRect(self, r, labelText(self, &buf));
    return Rect.unite(lens.expand(ringOut(self) + 2), label.expand(2));
}

/// How far the dark ring reaches past the magnified pixels.
fn ringOut(self: *const Editor) i32 {
    return self.sc(3);
}

pub fn drawLoupe(self: *Editor, canvas: *Canvas) void {
    const r = loupeRect(self) orelse return;
    const f = self.uf();
    const cell = @max(4, self.sc(8));
    const size = cell * loupe_cells;
    const ip = self.pn().view.toImg(self.mouse);
    canvas.fillRoundRectAA(r.x - self.sc(2), r.y - self.sc(1), size + self.sc(4), size + self.sc(4), 10 * f, 0x40000000);
    drawCells(self, canvas, r, cell, ip);
    drawGrid(self, canvas, r, cell);
    // rounded window onto the pixels: mask the corners with a ring
    const lr = Rect{ .x = r.x, .y = r.y, .w = size, .h = size };
    shapes_mod.roundRectRing(canvas, lr.expand(ringOut(self)), 10 * f + ff(ringOut(self)), ff(self.sc(6)) + 1, 0xFF1C1C1E);
    shapes_mod.roundRectRing(canvas, lr, 8 * f, 1.5 * f, 0xE6FFFFFF);
    drawLabel(self, canvas, r);
}

/// The pixels around image point `ip`, one `cell` square each (dark
/// outside the image).
fn drawCells(self: *const Editor, canvas: *Canvas, r: Rect, cell: i32, ip: Point) void {
    const half: i32 = loupe_cells / 2;
    const iw: i32 = @intCast(self.img.width);
    const ih: i32 = @intCast(self.img.height);
    var cy: i32 = 0;
    while (cy < loupe_cells) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < loupe_cells) : (cx += 1) {
            const sx = ip.x - half + cx;
            const sy = ip.y - half + cy;
            const c: u32 = if (sx < 0 or sy < 0 or sx >= iw or sy >= ih)
                0xFF101010
            else
                self.layer[@as(usize, @intCast(sy)) * self.img.width + @as(usize, @intCast(sx))];
            canvas.fillRect(r.x + cx * cell, r.y + cy * cell, cell, cell, c | 0xFF000000);
        }
    }
}

/// Pixel grid and crosshair on the centre pixel.
fn drawGrid(self: *const Editor, canvas: *Canvas, r: Rect, cell: i32) void {
    const size = cell * loupe_cells;
    const half: i32 = loupe_cells / 2;
    var g: i32 = 1;
    while (g < loupe_cells) : (g += 1) {
        canvas.fillRect(r.x + g * cell, r.y, 1, size, 0x14FFFFFF);
        canvas.fillRect(r.x, r.y + g * cell, size, 1, 0x14FFFFFF);
    }
    const c0x = r.x + half * cell;
    const c0y = r.y + half * cell;
    canvas.fillRect(r.x, c0y, size, cell, theme.withAlpha(self.theme.accent, 0x26));
    canvas.fillRect(c0x, r.y, cell, size, theme.withAlpha(self.theme.accent, 0x26));
    canvas.rectOutline(c0x - 1, c0y - 1, cell + 2, cell + 2, 1, 0xFFFFFFFF);
}

/// Coordinates, or the selection size while dragging.
fn labelText(self: *const Editor, buf: []u8) []const u8 {
    const iw: i32 = @intCast(self.img.width);
    const ih: i32 = @intCast(self.img.height);
    const x_sym = if (text_mod.available()) "\u{00D7}" else "x";
    if (self.drag != .none and self.doc.sel != null) {
        const s = self.doc.sel.?.normalized();
        return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ s.w, x_sym, s.h }) catch "?";
    }
    const ip = self.pn().view.toImg(self.mouse);
    return std.fmt.bufPrint(buf, "{d}, {d}", .{ std.math.clamp(ip.x, 0, iw), std.math.clamp(ip.y, 0, ih) }) catch "?";
}

/// The label's pill, centred below the magnified pixels of `r`.
fn labelRect(self: *const Editor, r: Rect, label: []const u8) Rect {
    const fs = theme.font_small * self.uf();
    const lw = text_mod.width(fs, label) + self.sc(20);
    return .{ .x = r.x + @divTrunc(r.w - lw, 2), .y = r.y + r.w + self.sc(6), .w = lw, .h = text_mod.height(fs) + self.sc(8) };
}

/// The label in its pill below.
fn drawLabel(self: *const Editor, canvas: *Canvas, r: Rect) void {
    var buf: [64]u8 = undefined;
    const label = labelText(self, &buf);
    const lr = labelRect(self, r, label);
    const fs = theme.font_small * self.uf();
    canvas.fillRoundRectAA(lr.x, lr.y, lr.w, lr.h, 7 * self.uf(), self.theme.pill_bg);
    text_mod.draw(canvas, r.x + @divTrunc(r.w - text_mod.width(fs, label), 2), lr.y + self.sc(4), fs, self.theme.pill_fg, label);
}
