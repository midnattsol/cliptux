//! Editing a text shape in place: starting and ending the edit (with
//! undo), keys and typing, the clipboard, and the text box's width
//! (fitting its text, or fixed so lines wrap).

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../window.zig");
const shapes_mod = @import("../shapes.zig");
const textbox = @import("../textbox.zig");
const caretAt = @import("../caret.zig").caretAt;
const keys = @import("keys.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const hit = @import("hit.zig");
const selection = @import("selection.zig");
const types = @import("types.zig");

const Editor = editor.Editor;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;

/// Edit text shape `i`, the caret at image point `ip` (a new, empty
/// one: at its start).
pub fn startText(ed: *Editor, i: usize, is_new: bool, ip: Point) !void {
    if (!is_new) try ed.doc.checkpoint() else {
        // the empty shape was added before the checkpoint; record the
        // state without it
        var s = ed.doc.shapes.pop().?;
        ed.doc.checkpoint() catch |e| {
            s.deinit(ed.alloc);
            return e;
        };
        ed.doc.shapes.appendAssumeCapacity(s);
    }
    const s = &ed.doc.shapes.items[i];
    const orig = try ed.alloc.dupe(u8, s.str.items);
    const at: textbox.Hit = if (is_new) .{ .off = 0 } else caretAt(s, ip);
    ed.text = .{ .idx = i, .te = .{ .caret = at.off }, .is_new = is_new, .orig = orig, .upstream = at.upstream };
    ed.selected = null;
    if (!is_new) selection.selectShape(ed, i);
    ed.selected = null;
    try selection.lift(ed, i);
    ed.needs_render = true;
}

/// Commit the text being edited: an empty one goes away, an unchanged
/// one leaves no undo step.
pub fn endText(ed: *Editor) !void {
    const t = ed.text orelse return;
    ed.text = null;
    defer ed.alloc.free(t.orig);
    ed.win.setTextInput(false, null) catch {};
    const s = &ed.doc.shapes.items[t.idx];
    const empty = std.mem.trim(u8, s.str.items, " \n").len == 0;
    const unchanged = !t.is_new and std.mem.eql(u8, s.str.items, t.orig);
    ed.lifted = null;
    if (empty) {
        const r = s.bounds();
        ed.doc.remove(t.idx);
        if (t.is_new) ed.doc.dropCheckpoint();
        try caches.recompose(ed, r);
        return;
    }
    // colour or size may still have changed while editing
    if (unchanged and sameAsCheckpoint(ed, t.idx)) ed.doc.dropCheckpoint();
    try caches.paintTop(ed, t.idx);
}

/// Does text shape `i` look as it did at the last checkpoint?
fn sameAsCheckpoint(ed: *Editor, i: usize) bool {
    const before = ed.doc.undo_stack.items[ed.doc.undo_stack.items.len - 1].shapes;
    const s = &ed.doc.shapes.items[i];
    return before.len == ed.doc.shapes.items.len and before[i].color == s.color and
        before[i].thickness == s.thickness and before[i].pill == s.pill and
        before[i].box_w == s.box_w and
        before[i].p0.x == s.p0.x and before[i].p0.y == s.p0.y;
}

/// A key while editing text (see keys_input.onKey for which).
pub fn onTextKey(ed: *Editor, k: window.Key) !void {
    const t = &ed.text.?;
    const buf = &ed.doc.shapes.items[t.idx].str;
    ed.needs_render = true;
    // only Up/Down keep the goal x, only End (and clicks) the affinity
    const goal = t.goal_x;
    const upstream = t.upstream;
    t.goal_x = null;
    t.upstream = false;
    switch (k.code) {
        window.KEY_ESC => try endText(ed),
        window.KEY_ENTER, keys.KEY_KPENTER => {
            if (k.ctrl) try endText(ed) else try t.te.insert(ed.alloc, buf, "\n");
        },
        window.KEY_BACKSPACE => if (k.ctrl) t.te.backspaceWord(buf) else t.te.backspace(buf),
        window.KEY_DELETE => t.te.delete(buf),
        keys.KEY_LEFT => t.te.move(buf.items, if (k.ctrl) .word_left else .left, k.shift),
        keys.KEY_RIGHT => t.te.move(buf.items, if (k.ctrl) .word_right else .right, k.shift),
        keys.KEY_UP, keys.KEY_DOWN, keys.KEY_HOME, keys.KEY_END => try moveByLine(ed, k, goal, upstream),
        keys.KEY_A => if (k.ctrl) t.te.selectAll(buf.items) else try typeText(ed, k),
        keys.KEY_C, keys.KEY_X => if (k.ctrl) try copyTextSelection(ed, k.code == keys.KEY_X) else try typeText(ed, k),
        keys.KEY_MINUS, keys.KEY_EQUAL => if (k.ctrl) try props.setThickness(ed, ed.thickness + @as(i32, if (k.code == keys.KEY_EQUAL) 1 else -1)) else try typeText(ed, k),
        else => try typeText(ed, k),
    }
}

/// Up/Down/Home/End by visual line, across wrapped lines (Ctrl+Home and
/// Ctrl+End: the whole text). `goal` is the x kept across Up/Down,
/// `upstream` the caret's affinity before the key.
fn moveByLine(ed: *Editor, k: window.Key, goal: ?i32, upstream: bool) !void {
    const t = &ed.text.?;
    const s = &ed.doc.shapes.items[t.idx];
    const buf = &s.str;
    if (k.ctrl and (k.code == keys.KEY_HOME or k.code == keys.KEY_END)) {
        t.te.move(buf.items, if (k.code == keys.KEY_HOME) .doc_start else .doc_end, k.shift);
        return;
    }
    var lay = try textbox.Layout.init(ed.alloc, buf.items, s.fontPx(), s.box_w);
    defer lay.deinit(ed.alloc);
    const cur: textbox.Hit = .{ .off = t.te.caret, .upstream = upstream };
    const h = switch (k.code) {
        keys.KEY_HOME => lay.home(cur),
        keys.KEY_END => lay.end(cur),
        else => blk: {
            const gx = goal orelse lay.caretX(buf.items, cur);
            t.goal_x = gx;
            break :blk lay.vertical(buf.items, cur, gx, k.code == keys.KEY_DOWN);
        },
    };
    t.te.moveTo(h.off, k.shift);
    t.upstream = h.upstream;
}

/// Ctrl+C / Ctrl+X: the selected text to the clipboard.
fn copyTextSelection(ed: *Editor, cut: bool) !void {
    const t = &(ed.text orelse return);
    const buf = &ed.doc.shapes.items[t.idx].str;
    const sel = t.te.selectedText(buf.items);
    if (sel.len == 0) return;
    const copy = try ed.alloc.dupe(u8, sel);
    ed.win.setClipboardText(copy) catch |e| {
        ed.alloc.free(copy);
        std.log.warn("copy text failed: {t}", .{e});
        return;
    };
    if (cut) _ = t.te.deleteSelection(buf);
    ed.needs_render = true;
}

/// Paste the clipboard's plain text at the caret, newlines kept.
pub fn pasteText(ed: *Editor) !void {
    const t = &(ed.text orelse return);
    const txt = (ed.win.clipboardText(ed.alloc, 64 * 1024, 400) catch |e| {
        std.log.warn("paste failed: {t}", .{e});
        return;
    }) orelse {
        std.log.info("paste: no text on the clipboard", .{});
        return;
    };
    defer ed.alloc.free(txt);
    try t.te.insert(ed.alloc, &ed.doc.shapes.items[t.idx].str, txt);
    ed.needs_render = true;
}

/// Insert the text key `k` types at the caret.
pub fn typeText(ed: *Editor, k: window.Key) !void {
    if (k.ctrl) return;
    const t = &ed.text.?;
    const txt = k.text();
    if (txt.len == 0) return;
    t.upstream = false;
    t.goal_x = null;
    // typing ends a double-click chain (the next press is a new click)
    ed.last_click.ms = 0;
    try t.te.insert(ed.alloc, &ed.doc.shapes.items[t.idx].str, txt);
}

/// Switch the text with a width handle between fitting its text and a
/// fixed width (its current one), with undo.
pub fn toggleTextWidth(ed: *Editor) !void {
    const i = hit.textHandleShape(ed) orelse return;
    const s = &ed.doc.shapes.items[i];
    if (s.box_w != 0) return setTextAutoWidth(ed, i);
    if (ed.text == null) try ed.doc.checkpoint();
    s.box_w = s.frame().w - 2 * s.textPad();
    ed.needs_render = true;
}

/// Back to fitting the text; right-to-left text keeps its right edge.
fn setTextAutoWidth(ed: *Editor, i: usize) !void {
    const s = &ed.doc.shapes.items[i];
    if (s.box_w == 0) return;
    const editing = ed.text != null;
    if (!editing) try ed.doc.checkpoint();
    const before = s.bounds();
    const rtl = s.textRtl();
    const right = s.p0.x + s.frame().w - 2 * s.textPad();
    s.box_w = 0;
    if (rtl) s.p0.x = right - (s.frame().w - 2 * s.textPad());
    ed.needs_render = true;
    if (!editing) try caches.recompose(ed, Rect.unite(before, s.bounds()));
}

/// A press on text shape `i`'s width handle: start dragging it, or on a
/// double click go back to fitting the text.
pub fn pressTextHandle(ed: *Editor, i: usize, double: bool) !void {
    const s = &ed.doc.shapes.items[i];
    const editing = ed.text != null;
    ed.needs_render = true;
    if (double) return setTextAutoWidth(ed, i);
    if (!editing) {
        try ed.doc.checkpoint();
        try selection.lift(ed, i);
    }
    ed.drag = .{ .text_width = .{
        .idx = i,
        .orig_w = s.frame().w - 2 * s.textPad(),
        .orig_x = s.p0.x,
        .orig_box_w = s.box_w,
        .rtl = s.textRtl(),
        .editing = editing,
    } };
}

/// Escape during a width drag: put the width back.
pub fn cancelWidthDrag(ed: *Editor, tw: types.DragMode.TextWidth) void {
    const s = &ed.doc.shapes.items[tw.idx];
    s.box_w = tw.orig_box_w;
    s.p0.x = tw.orig_x;
}
