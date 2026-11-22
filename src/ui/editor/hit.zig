//! Hit testing in the current pane: what lies under a buffer point (the
//! chrome, a shape's handles, a text's width handle) and the pointer
//! cursor that goes with it.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const shapes_mod = @import("../shapes.zig");
const ui = @import("../editor_ui.zig");
const tools = @import("../tools/mod.zig");

const Editor = editor.Editor;
const Point = shapes_mod.Point;

/// Is buffer point `m` of the pointer's pane on the toolbar's pane at all?
pub fn onToolbar(ed: *const Editor, m: Point) bool {
    return ui.onChrome(ed, m);
}

/// `p` clamped to the image (edges included).
pub fn clampImg(ed: *const Editor, p: Point) Point {
    return .{
        .x = std.math.clamp(p.x, 0, @as(i32, @intCast(ed.img.width))),
        .y = std.math.clamp(p.y, 0, @as(i32, @intCast(ed.img.height))),
    };
}

/// Image-pixel tolerance for clicking on shapes.
pub fn hitTol(ed: *const Editor) f64 {
    return ed.pn().view.lenToImg(@floatFromInt(ed.sc(5)));
}

/// The width handle of text shape `i`, in buffer pixels: the middle
/// of its right edge, or the left one for right-to-left text.
pub fn textWidthHandle(ed: *const Editor, i: usize) Point {
    const s = &ed.doc.shapes.items[i];
    const f = ed.pn().view.rectToBuf(s.frame()).expand(ed.sc(3));
    return .{ .x = if (s.textRtl()) f.x else f.right() - 1, .y = f.y + @divTrunc(f.h, 2) };
}

/// The text shape that shows a width handle (being edited, or
/// selected), if any.
pub fn textHandleShape(ed: *const Editor) ?usize {
    const i = if (ed.text) |t| t.idx else ed.selected orelse return null;
    if (i >= ed.doc.shapes.items.len or ed.doc.shapes.items[i].tool != .text) return null;
    return i;
}

pub fn textHandleAt(ed: *const Editor, m: Point) ?usize {
    const i = textHandleShape(ed) orelse return null;
    const h = textWidthHandle(ed, i);
    const r = ed.handleRadius();
    if (@abs(m.x - h.x) <= r and @abs(m.y - h.y) <= r) return i;
    return null;
}

/// The handle of shape `i` under `m`: an endpoint or a frame handle.
pub fn shapeHandleAt(ed: *const Editor, i: usize, m: Point) ?u3 {
    const s = &ed.doc.shapes.items[i];
    const r = ed.handleRadius();
    switch (s.handleKind()) {
        .none => return null,
        .endpoints => {
            for ([_]Point{ s.p0, s.p1 }, 0..) |p, k| {
                const b = ed.pn().view.toBuf(p);
                if (@abs(b.x - m.x) <= r and @abs(b.y - m.y) <= r) return @intCast(k);
            }
            return null;
        },
        .box => {
            const f = ed.pn().view.rectToBuf(s.frame());
            // a press inside a small shape moves it rather than resizing
            if (f.w < 4 * r or f.h < 4 * r) {
                if (f.contains(m.x, m.y)) return null;
            }
            return shapes_mod.handleAt(f, m, r);
        },
    }
}

/// The pointer cursor for buffer point `m`.
pub fn cursorFor(ed: *Editor, m: Point) window.Cursor {
    if (onToolbar(ed, m) or ed.help_open) return .arrow;
    if (tools.cursor(ed)) |c| return c;
    if (textHandleAt(ed, m) != null) return .resize_ew;
    if (ed.picker.open and (ed.mouse_pane == ed.tb_pane and ed.picker.rect.contains(m.x, m.y))) return .crosshair;
    if (ed.selected) |i| {
        if (shapeHandleAt(ed, i, m) != null) return .move;
    }
    if (ed.tool == .select) {
        if (selectCursor(ed, m)) |c| return c;
    }
    if (ed.tool == .text and ed.doc.sel != null) return .text;
    return .crosshair;
}

/// The select tool's cursor over a shape or the selection, if any.
fn selectCursor(ed: *Editor, m: Point) ?window.Cursor {
    if (ed.doc.sel != null and ed.doc.hit(ed.imgAt(m), hitTol(ed)) != null) return .move;
    const n = ed.selBuf() orelse return null;
    if (shapes_mod.handleAt(n, m, ed.handleRadius())) |hi| return switch (hi) {
        0, 4 => .resize_nwse,
        2, 6 => .resize_nesw,
        1, 5 => .resize_ns,
        else => .resize_ew,
    };
    if (n.contains(m.x, m.y)) return .move;
    return null;
}
