//! The look of what is drawn next and of the edit target (the text
//! being edited or the selected shape): tool, colour, stroke width and
//! style, applied with undo that coalesces quick repeats.

const std = @import("std");
const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const ui = @import("../editor_ui.zig");
const session = @import("session.zig");
const caches = @import("caches.zig");
const selection = @import("selection.zig");
const text_edit = @import("text_edit.zig");

const Editor = editor.Editor;
const Tool = editor.Tool;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;

/// Apply `op(shape, arg)` to the text being edited or the selected
/// shape, with undo (coalescing repeats of the same `kind`).
pub fn editTarget(ed: *Editor, kind: u8, comptime op: anytype, arg: anytype) !void {
    if (ed.text) |t| {
        op(&ed.doc.shapes.items[t.idx], arg);
        ed.needs_render = true;
        return;
    }
    const i = ed.selected orelse return;
    const now = session.nowMs();
    if (!(ed.coalesce.kind == kind and now - ed.coalesce.ms < 1200)) try ed.doc.checkpoint();
    ed.coalesce = .{ .kind = kind, .ms = now };
    const before = ed.doc.shapes.items[i].bounds();
    op(&ed.doc.shapes.items[i], arg);
    try caches.recompose(ed, Rect.unite(before, ed.doc.shapes.items[i].bounds()));
}

/// The next tweak gets an undo step of its own.
pub fn breakCoalescing(ed: *Editor) void {
    ed.coalesce.kind = 0;
}

pub fn setTool(ed: *Editor, t: Tool) !void {
    try text_edit.endText(ed);
    selection.deselectShape(ed);
    ed.tool = t;
    ed.needs_render = true;
}

pub fn setThickness(ed: *Editor, t: i32) !void {
    const nt = std.math.clamp(t, 1, 32);
    if (nt == ed.thickness) return;
    ed.thickness = nt;
    ed.needs_render = true;
    const it = ed.imgThickness();
    try editTarget(ed, 1, struct {
        fn f(s: *Shape, v: i32) void {
            s.thickness = v;
        }
    }.f, it);
}

pub fn applyColor(ed: *Editor) !void {
    try editTarget(ed, 2, struct {
        fn f(s: *Shape, c: u32) void {
            s.color = c;
        }
    }.f, ed.color());
}

/// Palette colour `c` for the next shape and the target.
pub fn pickPaletteColor(ed: *Editor, c: u4) !void {
    ed.color_idx = c;
    ed.custom_active = false;
    try applyColor(ed);
}

/// The colour picker's colour for the next shape and the target.
pub fn applyPickerColor(ed: *Editor) !void {
    ed.custom_color = ui.pickerColor(ed);
    ed.custom_active = true;
    try applyColor(ed);
}

/// The tool whose style the style controls change: the target's, else
/// the active one.
fn styleTarget(ed: *const Editor) Tool {
    if (ed.text) |t| return ed.doc.shapes.items[t.idx].tool;
    if (ed.selected) |i| return ed.doc.shapes.items[i].tool;
    return ed.tool;
}

/// Outline -> filled -> rounded outline -> rounded filled (text: pill).
pub fn cycleStyle(ed: *Editor) !void {
    const target_tool = styleTarget(ed);
    const old = ed.styles.get(target_tool);
    const style: u2 = switch (target_tool) {
        .rect => old +% 1,
        else => (old ^ 1) & 1,
    };
    try setStyle(ed, target_tool, style);
}

/// Bit 0: filled (text: background pill); bit 1: rounded (rectangles).
fn setStyle(ed: *Editor, target_tool: Tool, style_in: u2) !void {
    const style: u2 = if (target_tool == .rect) style_in else style_in & 1;
    ed.styles.set(target_tool, style);
    breakCoalescing(ed);
    try editTarget(ed, 3, struct {
        fn f(s: *Shape, st: u2) void {
            s.filled = (st & 1) != 0 and (s.tool == .rect or s.tool == .ellipse);
            s.rounded = (st & 2) != 0 and s.tool == .rect;
            s.pill = (st & 1) != 0 and s.tool == .text;
        }
    }.f, style);
    ed.needs_render = true;
}

/// A style segment of the popover: outline/filled, plain/pill, rounded.
pub fn applyStyleSeg(ed: *Editor, sg: ui.Seg) !void {
    const target = styleTarget(ed);
    const old = ed.styles.get(target);
    switch (sg) {
        .outline, .plain => try setStyle(ed, target, old & 2),
        .filled, .pill => try setStyle(ed, target, old | 1),
        .rounded => try setStyle(ed, target, old ^ 2),
        else => unreachable,
    }
}

/// A redaction mode segment: blur, pixelate or solid, for the active
/// redaction tool and a selected redaction.
pub fn applyRedactionSeg(ed: *Editor, t: Tool) !void {
    if (ed.tool.isRedaction()) ed.tool = t;
    const i = ed.selected orelse return;
    if (!ed.doc.shapes.items[i].tool.isRedaction()) return;
    breakCoalescing(ed);
    try editTarget(ed, 4, struct {
        fn f(s: *Shape, v: Tool) void {
            if (s.tool.isRedaction()) s.tool = v;
        }
    }.f, t);
}
