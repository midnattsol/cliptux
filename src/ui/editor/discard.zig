//! Closing the editor (Esc with nothing left to cancel, the Close
//! button) never drops annotations silently: with unsaved ones the first
//! attempt only says so, and a second within a few seconds discards them,
//! like the "discard changes?" prompt of macOS editors, without a dialog.

const std = @import("std");
const editor = @import("../editor.zig");
const commands = @import("commands.zig");
const session = @import("session.zig");

const Editor = editor.Editor;

/// How long the second Esc (or Close) has to confirm.
pub const confirm_ms = 4000;

pub const message = "Unsaved annotations \u{00B7} Esc again to discard";

/// Close the editor, or ask first when that would lose annotations.
pub fn close(ed: *Editor) void {
    const now = session.nowMs();
    if (!unsaved(ed) or now < ed.discard_until_ms) return commands.finish(ed, .cancel);
    ed.discard_until_ms = now + confirm_ms;
    ed.tools.toast.show(.problem, message, confirm_ms);
    ed.needs_render = true;
    std.log.info("close: unsaved annotations, waiting for a second Esc to discard them", .{});
}

/// Shapes the person drew in this session (a reopened capture's shapes,
/// already kept in the history, count once changed).
pub fn unsaved(ed: *const Editor) bool {
    return ed.doc.shapes.items.len > 0 and ed.doc.undo_stack.items.len > 0;
}
