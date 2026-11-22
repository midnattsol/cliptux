//! The editor's mode strip asked for another capture mode
//! (ui/editor/capmode.zig): the editor eases back to the plain capture
//! and closes, then
//!
//! - Screen: the monitor it chose is delivered like `shotlet fullscreen`
//!   (after_fullscreen: copy, thumbnail or save);
//! - Record: the recording picker opens on this same frozen frame;
//! - Window, Scroll, Timer: that capture starts anew in a fresh shotlet.

const std = @import("std");
const capture = @import("../capture.zig");
const keep_mod = @import("../keep.zig");
const mode_flow = @import("../modes/flow.zig");
const editor_mod = @import("../../ui/editor.zig");
const record_cli = @import("../../record/cli.zig");

const Editor = editor_mod.Editor;

/// Ease the editor out and close its window: nothing of it stays on
/// screen for what comes next.
fn leave(ed: *Editor, win: anytype) void {
    ed.fadeOut() catch |err| std.log.debug("editor fade: {t}", .{err});
    win.closeWindow();
}

pub fn screen(c: mode_flow.Ctx, ed: *Editor, cap: *capture.Capture) !void {
    const r = ed.capmode.screen_rect;
    leave(ed, c.win);
    try mode_flow.deliverScreen(c, cap, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

/// The recording picker over `cap`; `overlays`: the capture came from
/// the GNOME extension (clicks and keys can be shown).
pub fn record(c: mode_flow.Ctx, ed: *Editor, cap: *const capture.Capture, overlays: bool) !void {
    leave(ed, c.win);
    std.log.info("capture mode: record, the picker on this capture", .{});
    try record_cli.pickOnCapture(c.gpa, c.env, cap, overlays);
}

pub fn restart(c: mode_flow.Ctx, ed: *Editor) void {
    leave(ed, c.win);
    keep_mod.spawnSelf(c.env, &.{ed.next_capture.ptr});
}
