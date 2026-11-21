//! Crop mode (C): the selection becomes the crop frame, with handles and
//! a rule-of-thirds grid; the toolbar offers the aspect ratios, Cancel
//! and Apply. Enter applies, Esc leaves the picture as it was.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const crop = @import("crop.zig");
const tools = @import("mod.zig");

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;

pub fn enter(ed: *Editor) !void {
    if (ed.tools.mode == .crop) return apply(ed);
    try ed.settle();
    ed.closePopover();
    ed.selected = null;
    ed.tools.mode = .crop;
    if (ed.doc.sel == null) ed.doc.sel = ed.doc.imageRect();
    try setAspect(ed, ed.tools.aspect);
    ed.selDirty();
    std.log.info("crop: started", .{});
}

pub fn setAspect(ed: *Editor, a: tools.Aspect) !void {
    ed.tools.aspect = a;
    const k = crop.ratio(a) orelse return;
    const s = (ed.doc.sel orelse return).normalized();
    ed.selDirty();
    ed.doc.sel = crop.fitInside(Rect.intersect(s, ed.doc.imageRect()) orelse ed.doc.imageRect(), k);
    ed.selDirty();
}

/// A press while cropping: move or resize the frame, or draw a new one.
pub fn onPress(ed: *Editor) bool {
    if (ed.tools.mode != .crop) return false;
    const m = ed.mouse;
    const ip = clampImg(ed, ed.imgAt(m));
    if (ed.selBuf()) |n| {
        if (shapes.handleAt(n, m, ed.handleRadius())) |h| {
            ed.drag = .{ .resizing_sel = .{ .handle = h, .orig = ed.doc.sel.?.normalized() } };
            return true;
        }
        if (n.contains(m.x, m.y)) {
            ed.drag = .{ .moving_sel = .{ .orig = ed.doc.sel.?.normalized(), .start = ip } };
            return true;
        }
    }
    ed.selDirty();
    ed.doc.sel = .{ .x = ip.x, .y = ip.y, .w = 0, .h = 0 };
    ed.drag = .{ .selecting = ip };
    ed.drag_anchor = ip;
    return true;
}

fn clampImg(ed: *const Editor, p: Point) Point {
    return .{
        .x = std.math.clamp(p.x, 0, @as(i32, @intCast(ed.img.width))),
        .y = std.math.clamp(p.y, 0, @as(i32, @intCast(ed.img.height))),
    };
}

/// The frame follows the pointer at the chosen aspect ratio.
pub fn constrain(ed: *Editor) void {
    if (ed.tools.mode != .crop) return;
    const k = crop.ratio(ed.tools.aspect) orelse return;
    const r = switch (ed.drag) {
        .selecting => crop.fromCorner(ed.drag_anchor, clampImg(ed, ed.imgAt(ed.mouse)), k),
        .resizing_sel => |rs| crop.constrainResize(rs.orig, rs.handle, ed.doc.sel.?, k),
        else => return,
    };
    ed.selDirty();
    ed.doc.sel = Rect.intersect(r, ed.doc.imageRect()) orelse r;
    ed.selDirty();
}

/// Crop the picture to the frame: a marked, undoable change.
pub fn apply(ed: *Editor) !void {
    ed.tools.mode = .none;
    ed.needs_render = true;
    const sel = ed.doc.sel orelse return;
    const r = Rect.intersect(sel.normalized(), ed.doc.imageRect()) orelse return;
    if (r.eql(ed.doc.imageRect()) or r.w < 2 or r.h < 2) return;
    try ed.settle();
    const st = &ed.tools.crops;
    const after = try st.adopt(ed.alloc, try crop.cropImage(ed.alloc, ed.img, r));
    const mark = st.next_mark;
    st.next_mark += 1;
    try st.entries.append(ed.alloc, .{ .mark = mark, .rect = r, .before = ed.img, .after = after });
    try ed.doc.checkpointMarked(mark);
    crop.moveShapes(ed.doc.shapes.items, r);
    ed.doc.sel = .{ .x = 0, .y = 0, .w = @intCast(after.width), .h = @intCast(after.height) };
    try ed.replaceImage(after);
    std.log.info("crop: {d}x{d} at {d},{d}", .{ r.w, r.h, r.x, r.y });
}

/// After an undo or redo: a crop it crossed swaps the picture back.
pub fn afterHistory(ed: *Editor, undone: bool) !void {
    const mark = ed.doc.last_mark;
    ed.doc.last_mark = 0;
    if (mark == 0) return;
    const e = ed.tools.crops.find(mark) orelse return;
    const img = if (undone) e.before else e.after;
    ed.doc.sel = if (undone) e.rect else .{ .x = 0, .y = 0, .w = @intCast(img.width), .h = @intCast(img.height) };
    try ed.replaceImage(img);
}

pub fn overlay(ed: *const Editor) ?Rect {
    if (ed.tools.mode != .crop) return null;
    return (ed.selBuf() orelse return null).expand(ed.handleRadius() + ed.sc(4));
}

/// The frame's thirds and its eight handles.
pub fn draw(ed: *Editor, canvas: *Canvas) void {
    if (ed.tools.mode != .crop) return;
    const s = ed.selBuf() orelse return;
    var i: i32 = 1;
    while (i < 3) : (i += 1) {
        canvas.fillRect(s.x + @divTrunc(s.w * i, 3), s.y, 1, s.h, 0x80FFFFFF);
        canvas.fillRect(s.x, s.y + @divTrunc(s.h * i, 3), s.w, 1, 0x80FFFFFF);
    }
    const f = ed.uf();
    const len: i32 = @min(ed.sc(18), @divTrunc(@min(s.w, s.h), 3));
    const t = @max(2, ed.sc(3));
    // corner brackets, then the edge handles
    for (shapes.handlePoints(s), 0..) |p, k| {
        if (k % 2 == 1) {
            canvas.fillCircleAA(@floatFromInt(p.x), @floatFromInt(p.y), 4.5 * f, 0xFFFFFFFF);
            continue;
        }
        const dx: i32 = if (p.x == s.x) 1 else -1;
        const dy: i32 = if (p.y == s.y) 1 else -1;
        const x0 = if (dx > 0) p.x - t else p.x - len;
        const y0 = if (dy > 0) p.y - t else p.y - len;
        canvas.fillRect(x0, if (dy > 0) p.y - t else p.y, len + t, t, 0xFFFFFFFF);
        canvas.fillRect(if (dx > 0) p.x - t else p.x, y0, t, len + t, 0xFFFFFFFF);
    }
}
