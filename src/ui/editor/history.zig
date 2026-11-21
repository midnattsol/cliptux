//! Undo, redo and cancel: settling whatever is in progress so the
//! document is consistent, and Escape's (and right click's) "undo the
//! innermost thing in progress".

const editor = @import("../editor.zig");
const tools = @import("../tools/mod.zig");
const caches = @import("caches.zig");
const commands = @import("commands.zig");
const selection = @import("selection.zig");
const text_edit = @import("text_edit.zig");
const drag = @import("drag.zig");
const drawing = @import("drawing.zig");

const Editor = editor.Editor;

/// End whatever is in progress so the document is consistent.
pub fn settle(ed: *Editor) !void {
    try text_edit.endText(ed);
    switch (ed.drag) {
        .drawing => try drawing.commit(ed),
        .moving_shape, .resizing_shape => try drag.onRelease(ed),
        else => {},
    }
    ed.drag = .none;
}

pub fn undo(ed: *Editor) !void {
    try settle(ed);
    ed.selected = null;
    if (try ed.doc.undo()) {
        try tools.afterHistory(ed, true);
        try caches.recomposeAll(ed);
    }
}

pub fn redo(ed: *Editor) !void {
    try settle(ed);
    ed.selected = null;
    if (try ed.doc.redo()) {
        try tools.afterHistory(ed, false);
        try caches.recomposeAll(ed);
    }
}

/// Escape semantics: undo the innermost thing in progress. Returns
/// false when there was nothing left to cancel.
pub fn cancelOne(ed: *Editor) !bool {
    ed.needs_render = true;
    if (closeOverlay(ed)) return true;
    if (tools.cancel(ed)) return true;
    if (ed.drag == .text_width) {
        const tw = ed.drag.text_width;
        ed.drag = .none;
        if (tw.editing) text_edit.cancelWidthDrag(ed, tw) else try revertLifted(ed);
        return true;
    }
    if (ed.text != null) {
        try text_edit.endText(ed);
        return true;
    }
    if (try cancelDrag(ed)) return true;
    return clearFocusOrSelection(ed);
}

/// Close help, the colour picker or the popover, whichever is open.
fn closeOverlay(ed: *Editor) bool {
    if (ed.help_open) {
        ed.help_open = false;
        return true;
    }
    if (ed.picker.open) {
        ed.picker.open = false;
        return true;
    }
    if (ed.popover != .none) {
        commands.closePopover(ed);
        return true;
    }
    return false;
}

/// Undo the lifted shape's change in progress: back to the checkpoint.
fn revertLifted(ed: *Editor) !void {
    ed.lifted = null;
    try ed.doc.revert();
    ed.selected = null;
    try caches.recomposeAll(ed);
}

/// Abandon the drag in progress, if one can be.
fn cancelDrag(ed: *Editor) !bool {
    switch (ed.drag) {
        .none, .picking, .size_slider, .text_select, .text_width => return false,
        .drawing => {
            drawing.discard(ed);
            ed.drag = .none;
        },
        .moving_shape, .resizing_shape => {
            // put the shape back where it was
            if (ed.drag == .resizing_shape) ed.drag.resizing_shape.orig.deinit(ed.alloc);
            ed.drag = .none;
            try revertLifted(ed);
        },
        .selecting, .moving_sel, .resizing_sel => {
            caches.selDirty(ed);
            ed.doc.sel = null;
            ed.drag = .none;
            caches.selDirty(ed);
        },
    }
    return true;
}

/// Nothing in progress: drop keyboard focus, the selected shape, or
/// the selection, in that order.
fn clearFocusOrSelection(ed: *Editor) bool {
    if (ed.focus != null) {
        ed.focus = null;
        return true;
    }
    if (ed.selected != null) {
        selection.deselectShape(ed);
        return true;
    }
    if (ed.doc.sel != null) {
        caches.selDirty(ed);
        ed.doc.sel = null;
        return true;
    }
    return false;
}
