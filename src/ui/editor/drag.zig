//! Pointer motion and release: hover feedback when nothing is dragged,
//! else one step of the drag in progress (see types.DragMode), and the
//! end of that drag on release.

const std = @import("std");
const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const textbox = @import("../textbox.zig");
const ui = @import("../editor_ui.zig");
const motion = @import("../motion.zig");
const tools = @import("../tools/mod.zig");
const caretAt = @import("../caret.zig").caretAt;
const hit = @import("hit.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const selection = @import("selection.zig");
const drawing = @import("drawing.zig");
const winpick = @import("winpick.zig");

const Editor = editor.Editor;
const DragMode = editor.DragMode;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;

pub fn onMotion(ed: *Editor) !void {
    const m = ed.mouse;
    const ip = ed.imgAt(m);
    switch (ed.drag) {
        .none => try hover(ed, m),
        .size_slider => try props.setThickness(ed, ui.sliderValue(ed, m)),
        .selecting => dragSelecting(ed, ip),
        .moving_sel => |mv| {
            caches.selDirty(ed);
            ed.doc.sel = mv.orig;
            ed.doc.moveSelection(ip.x - mv.start.x, ip.y - mv.start.y);
            caches.selDirty(ed);
        },
        .resizing_sel => |rs| {
            caches.selDirty(ed);
            ed.doc.sel = shapes_mod.resizeWithHandle(rs.orig, rs.handle, hit.clampImg(ed, ip));
            caches.selDirty(ed);
            tools.afterSelDrag(ed);
        },
        .drawing => try drawing.update(ed, ip),
        .moving_shape => |*mv| dragMovingShape(ed, mv, ip),
        .resizing_shape => |*rs| dragResizingShape(ed, rs, ip),
        .picking => |part| {
            ui.pickAt(ed, part, m);
            try props.applyPickerColor(ed);
        },
        .text_select => if (ed.text) |*t| {
            const h = caretAt(&ed.doc.shapes.items[t.idx], ip);
            t.te.caret = h.off;
            t.upstream = h.upstream;
            ed.needs_render = true;
        },
        .text_width => |tw| dragTextWidth(ed, tw, ip),
    }
}

/// No drag: the hovered button and selection handle.
fn hover(ed: *Editor, m: Point) !void {
    const over: i32 = if (ui.buttonAt(ed, m)) |bi| @intCast(bi) else -1;
    if (over != ed.hover_btn) {
        const t = motion.now();
        ed.hover_prev = ed.hover_btn;
        ed.hover_btn = over;
        ed.hover_since_ms = t;
        ed.hov.snap(0);
        ed.hov.to(1, t);
        ed.needs_render = true;
    }
    const hh = ui.hoverHandle(ed);
    if (hh != ed.sel_hover) {
        ed.sel_hover = hh;
        ed.needs_render = true;
    }
    if (ui.loupeActive(ed)) ed.needs_render = true;
    winpick.hover(ed);
    tools.onHover(ed);
}

/// A new selection from the anchor to `ip` (Shift: square, Alt: from
/// the centre, Space: move it), kept on the image.
fn dragSelecting(ed: *Editor, ip: Point) void {
    caches.selDirty(ed);
    const q = hit.clampImg(ed, ip);
    drawing.spaceMove(ed, q);
    const cs = shapes_mod.dragCorners(ed.drag_anchor, q, ed.mod_shift, ed.mod_alt);
    ed.doc.sel = Rect.intersect(Rect.fromCorners(cs[0], cs[1]), ed.doc.imageRect()) orelse Rect.fromCorners(q, q);
    caches.selDirty(ed);
    winpick.onDrag(ed);
    tools.afterSelDrag(ed);
}

fn dragMovingShape(ed: *Editor, mv: *DragMode.MovingShape, ip: Point) void {
    const i = ed.lifted orelse return;
    const dx = ip.x - mv.start.x - mv.applied.x;
    const dy = ip.y - mv.start.y - mv.applied.y;
    if (dx == 0 and dy == 0) return;
    ed.doc.shapes.items[i].translate(dx, dy);
    mv.applied.x += dx;
    mv.applied.y += dy;
    ed.needs_render = true;
}

fn dragResizingShape(ed: *Editor, rs: *DragMode.ResizingShape, ip: Point) void {
    const i = ed.lifted orelse return;
    const s = &ed.doc.shapes.items[i];
    switch (s.handleKind()) {
        .endpoints => if (rs.handle == 0) {
            s.p0 = ip;
        } else {
            s.p1 = ip;
        },
        .box => s.setFrame(&rs.orig, shapes_mod.resizeWithHandle(rs.orig.frame(), rs.handle, ip).normalized()),
        .none => {},
    }
    ed.needs_render = true;
}

/// A text box's width follows the pointer (not below one glyph).
fn dragTextWidth(ed: *Editor, tw: DragMode.TextWidth, ip: Point) void {
    const s = &ed.doc.shapes.items[tw.idx];
    const pad = s.textPad();
    const minw = textbox.minWidth(s.fontPx());
    if (tw.rtl) {
        // the right edge stays, the left one follows the pointer
        const right = tw.orig_x + tw.orig_w;
        const left = @min(ip.x + pad, right - minw);
        s.p0.x = left;
        s.box_w = right - left;
    } else {
        s.box_w = std.math.clamp(ip.x - pad - s.p0.x, minw, 1 << 20);
    }
    ed.needs_render = true;
}

pub fn onRelease(ed: *Editor) !void {
    const d = ed.drag;
    ed.drag = .none;
    switch (d) {
        .selecting => endSelecting(ed),
        .moving_sel, .resizing_sel => {
            caches.selDirty(ed);
            if (ed.sel_edge) |h| ed.sel_edge = shapes_mod.normalizedHandle(ed.doc.sel.?, h);
            ed.doc.sel = Rect.intersect(ed.doc.sel.?.normalized(), ed.doc.imageRect());
            caches.selDirty(ed);
        },
        .drawing => try drawing.commit(ed),
        .moving_shape => |mv| {
            if (mv.applied.x == 0 and mv.applied.y == 0) ed.doc.dropCheckpoint();
            try selection.unlift(ed);
        },
        .resizing_shape => |rs| {
            var orig = rs.orig;
            orig.deinit(ed.alloc);
            try selection.unlift(ed);
        },
        .text_width => |tw| if (!tw.editing) {
            const s = &ed.doc.shapes.items[tw.idx];
            if (s.box_w == tw.orig_box_w and s.p0.x == tw.orig_x) ed.doc.dropCheckpoint();
            try selection.unlift(ed);
        },
        .picking, .size_slider, .text_select, .none => {},
    }
    ed.needs_render = true;
}

/// A new selection is done. Too small to be one, it was a click: that
/// picks the window under it (when the desktop said where windows are),
/// else the monitor under it when there are several.
fn endSelecting(ed: *Editor) void {
    const s = ed.doc.sel.?.normalized();
    caches.selDirty(ed);
    if (winpick.tiny(ed)) {
        ed.doc.sel = null;
        if (!winpick.clickSelect(ed) and ed.monitors.len > 1) {
            const ip = ed.imgAt(ed.mouse);
            for (ed.monitors) |mon| {
                const r = Rect{ .x = @intCast(mon.x), .y = @intCast(mon.y), .w = @intCast(mon.w), .h = @intCast(mon.h) };
                if (r.contains(ip.x, ip.y)) ed.doc.sel = r;
            }
        }
    } else {
        ed.doc.sel = s;
    }
    caches.selDirty(ed);
    tools.onSelected(ed);
}
