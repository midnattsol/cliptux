//! The selected shape: selecting one (the toolbar takes on its look),
//! lifting it out of the layer while it changes, and the edits on it
//! (delete, duplicate, bring to front, nudge). Arrow keys nudge the
//! selection rectangle when no shape is selected.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const shapes_mod = @import("../shapes.zig");
const keys = @import("keys.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const history = @import("history.zig");

const Editor = editor.Editor;
const Shape = shapes_mod.Shape;
const palette = shapes_mod.palette;

/// Logical stroke width for `img_t` image pixels (inverse of imgThickness).
fn logicalThickness(ed: *const Editor, img_t: i32) i32 {
    const t = @as(f64, @floatFromInt(img_t)) * ed.pn().view.scale / ed.uf();
    return std.math.clamp(@as(i32, @intFromFloat(@round(t))), 1, 32);
}

pub fn selectShape(ed: *Editor, i: usize) void {
    ed.selected = i;
    const s = &ed.doc.shapes.items[i];
    // the toolbar reflects the shape, so tweaks start from its values
    ed.thickness = logicalThickness(ed, s.thickness);
    ed.custom_active = true;
    for (palette, 0..) |c, ci| {
        if (c == s.color) {
            ed.color_idx = @intCast(ci);
            ed.custom_active = false;
        }
    }
    if (ed.custom_active) ed.custom_color = s.color;
    ed.styles.set(s.tool, @as(u2, @intFromBool(s.filled or s.pill)) | (@as(u2, @intFromBool(s.rounded)) << 1));
    ed.needs_render = true;
}

pub fn deselectShape(ed: *Editor) void {
    if (ed.selected != null) ed.needs_render = true;
    ed.selected = null;
}

/// Take shape `i` out of the layer so it can change every frame.
pub fn lift(ed: *Editor, i: usize) !void {
    ed.lifted = i;
    try caches.recompose(ed, ed.doc.shapes.items[i].bounds());
}

pub fn unlift(ed: *Editor) !void {
    const i = ed.lifted orelse return;
    ed.lifted = null;
    try caches.paintTop(ed, i);
}

pub fn deleteSelected(ed: *Editor) !void {
    try history.settle(ed);
    const i = ed.selected orelse return;
    ed.selected = null;
    try ed.doc.checkpoint();
    const r = ed.doc.shapes.items[i].bounds();
    ed.doc.remove(i);
    try caches.recompose(ed, r);
}

pub fn duplicateSelected(ed: *Editor) !void {
    try history.settle(ed);
    const i = ed.selected orelse return;
    try ed.doc.checkpoint();
    const off: i32 = @max(4, @as(i32, @intFromFloat(@round(ed.pn().view.lenToImg(@floatFromInt(ed.sc(14)))))));
    const n = try ed.doc.duplicate(i, off, off);
    ed.selected = n;
    try caches.paintTop(ed, n);
}

pub fn bringSelectedToFront(ed: *Editor) !void {
    try history.settle(ed);
    const i = ed.selected orelse return;
    if (i + 1 == ed.doc.shapes.items.len) return;
    try ed.doc.checkpoint();
    ed.selected = ed.doc.bringToFront(i);
    try caches.recompose(ed, ed.doc.shapes.items[ed.selected.?].bounds());
}

/// Arrow keys: nudge the selected shape, else move the selection (Alt:
/// resize it); Shift steps 10 pixels.
pub fn arrowKey(ed: *Editor, k: window.Key) !void {
    const step: i32 = if (k.shift) 10 else 1;
    const dx: i32 = switch (k.code) {
        keys.KEY_LEFT => -step,
        keys.KEY_RIGHT => step,
        else => 0,
    };
    const dy: i32 = switch (k.code) {
        keys.KEY_UP => -step,
        keys.KEY_DOWN => step,
        else => 0,
    };
    if (ed.selected != null and !k.alt) {
        try props.editTarget(ed, 4, struct {
            fn f(s: *Shape, d: [2]i32) void {
                s.translate(d[0], d[1]);
            }
        }.f, [2]i32{ dx, dy });
        return;
    }
    if (ed.doc.sel == null) return;
    caches.selDirty(ed);
    if (k.alt) ed.doc.resizeSelection(dx, dy) else ed.doc.moveSelection(dx, dy);
    caches.selDirty(ed);
}
