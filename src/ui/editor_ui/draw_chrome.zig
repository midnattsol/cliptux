//! Chrome over the canvas: the entry point drawing every piece in order,
//! and the edited or selected shape's chrome (dashed frame, handles, the
//! text width handle, the input method's composition).

const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const tools = @import("../tools/mod.zig");
const help = @import("../help.zig");
const selection = @import("selection.zig");
const loupe = @import("loupe.zig");
const draw_toolbar = @import("draw_toolbar.zig");
const draw_popover = @import("draw_popover.zig");
const picker = @import("picker.zig");
const tooltip = @import("tooltip.zig");
const notice = @import("notice.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;
const handlePoints = shapes_mod.handlePoints;

pub fn drawChrome(self: *Editor, canvas: *Canvas) void {
    if (self.text) |t| {
        const f = self.pn().view.rectToBuf(self.doc.shapes.items[t.idx].frame()).expand(self.sc(3));
        dashedRect(canvas, f, 0xCCFFFFFF, 0xCC000000);
        if (self.isMousePane()) drawPreedit(self, canvas);
    }
    if (self.selected) |i| drawShapeChrome(self, canvas, i);
    if (self.textHandleShape()) |i| drawTextHandle(self, canvas, i);
    selection.drawSelectionChrome(self, canvas);
    if (self.isMousePane()) loupe.drawLoupe(self, canvas);
    tools.drawChrome(self, canvas);
    if (!self.isTbPane()) return;
    draw_toolbar.drawToolbar(self, canvas);
    if (self.popover != .none and !self.pop_rect.isEmpty()) draw_popover.drawPopover(self, canvas);
    if (self.picker.open and !self.toolbar_rect.isEmpty()) picker.drawPicker(self, canvas);
    tooltip.drawTooltip(self, canvas);
    if (self.copy_notice != .none) notice.drawCopyNotice(self, canvas);
    tools.drawTop(self, canvas);
    if (self.help_open) help.draw(self, canvas);
}

pub fn handleDrawRadius(self: *const Editor) f64 {
    return 5.0 * self.uf();
}

pub fn shapeChromeRect(self: *const Editor, i: usize) ?Rect {
    const s = &self.doc.shapes.items[i];
    return switch (s.handleKind()) {
        .endpoints => Rect.fromCorners(self.pn().view.toBuf(s.p0), self.pn().view.toBuf(s.p1)),
        else => self.pn().view.rectToBuf(s.frame()).expand(self.sc(3)),
    };
}

fn preeditFs(self: *const Editor) f64 {
    const t = self.text.?;
    return self.doc.shapes.items[t.idx].fontPx() * self.pn().view.scale;
}

/// Where the input method's in-progress composition shows (at the caret).
pub fn preeditRect(self: *Editor) ?Rect {
    const pe = self.win.preedit();
    if (pe.len == 0) return null;
    const c = self.caretRect() orelse return null;
    const fs = preeditFs(self);
    return .{ .x = c.x, .y = c.y, .w = text_mod.width(fs, pe) + self.sc(4), .h = c.h + self.sc(3) };
}

fn drawPreedit(self: *Editor, canvas: *Canvas) void {
    const r = preeditRect(self) orelse return;
    const fs = preeditFs(self);
    canvas.fillRect(r.x, r.y, r.w, r.h, 0xE61C1C1E);
    text_mod.draw(canvas, r.x + self.sc(2), r.y, fs, 0xFFFFFFFF, self.win.preedit());
    canvas.fillRect(r.x, r.bottom() - self.sc(2), r.w, @max(1, self.sc(1)), self.theme.accent);
}

fn dashedRect(canvas: *Canvas, r: Rect, a: u32, b: u32) void {
    const dash: i32 = 4;
    var x = r.x;
    while (x < r.right()) : (x += 1) {
        const c = if (@mod(@divFloor(x - r.x, dash), 2) == 0) a else b;
        canvas.blend(x, r.y, c);
        canvas.blend(x, r.bottom() - 1, c);
    }
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        const c = if (@mod(@divFloor(y - r.y, dash), 2) == 0) a else b;
        canvas.blend(r.x, y, c);
        canvas.blend(r.right() - 1, y, c);
    }
}

/// Footprint of a text box's width handle: a short vertical pill.
pub fn textHandleRect(self: *const Editor, i: usize) Rect {
    const h = self.textWidthHandle(i);
    const hw: i32 = @intFromFloat(@ceil(3.5 * self.uf()));
    const hh: i32 = @intFromFloat(@ceil(9.0 * self.uf()));
    return .{ .x = h.x - hw, .y = h.y - hh, .w = 2 * hw, .h = 2 * hh };
}

/// The width handle: drag to fix the box width, double-click for auto.
/// Filled when the width is fixed, hollow when the box fits its text.
fn drawTextHandle(self: *Editor, canvas: *Canvas, i: usize) void {
    const r = textHandleRect(self, i);
    const fixed = self.doc.shapes.items[i].box_w > 0;
    const rad = ff(r.w) / 2.0;
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, 0xB3000000);
    const in = @max(1, self.sc(1));
    canvas.fillRoundRectAA(r.x + in, r.y + in, r.w - 2 * in, r.h - 2 * in, rad - 1, if (fixed) self.theme.accent else 0xFFFFFFFF);
}

/// A white handle with a soft shadow, like the selection's corners.
pub fn drawHandle(self: *const Editor, canvas: *Canvas, x: f64, y: f64, r: f64) void {
    const f = self.uf();
    canvas.fillCircleAA(x, y + 1.0 * f, r + 1.5 * f, 0x1F000000);
    canvas.fillCircleAA(x, y + 1.0 * f, r + 0.5 * f, 0x40000000);
    canvas.fillCircleAA(x, y, r, self.theme.handle);
}

fn drawShapeChrome(self: *Editor, canvas: *Canvas, i: usize) void {
    const s = &self.doc.shapes.items[i];
    const f = self.uf();
    const hr = handleDrawRadius(self) * 0.9;
    const accent = self.theme.accent;
    switch (s.handleKind()) {
        .endpoints => {
            for ([_]Point{ s.p0, s.p1 }) |p| {
                const b = self.pn().view.toBuf(p);
                drawHandle(self, canvas, ff(b.x), ff(b.y), hr);
                canvas.ringAA(ff(b.x), ff(b.y), hr - 0.75 * f, 1.5 * f, accent);
            }
        },
        else => {
            const r = shapeChromeRect(self, i).?;
            dashedRect(canvas, r, accent, 0x80FFFFFF);
            if (s.handleKind() == .box) {
                for (handlePoints(r)) |p| {
                    drawHandle(self, canvas, ff(p.x), ff(p.y), hr);
                    canvas.ringAA(ff(p.x), ff(p.y), hr - 0.75 * f, 1.5 * f, accent);
                }
            }
        },
    }
}
