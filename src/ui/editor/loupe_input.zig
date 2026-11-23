//! The magnifier's keys and wheel (editor_ui/loupe.zig): while it is
//! wanted in the capture screen (shown or not), C copies the pixel's
//! colour as `#RRGGBB` (the label says so), and the wheel or - = zoom it
//! (the colour picker's lens zooms too); while Ctrl shows it, Ctrl+wheel
//! and Ctrl+- = zoom it too. Holding Alt shows that colour
//! (editor_ui/loupe.zig reads the held modifier). C is matched like the
//! mode strip's letters, by the key's place (where a US layout has it).
//! While the magnifier is wanted it wins over C for crop: there is no
//! selection to crop yet, or one is being dragged.
//!
//! It also feeds the magnifier Ctrl (editor_ui/loupe_hold.zig): any other
//! key with Ctrl down is a shortcut and keeps it away, but for its own
//! keys (arrows nudging an edge, - = zooming) and Shift and Alt; a click
//! or wheel notch before it shows does too.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const config = @import("../../app/config.zig");
const ui = @import("../editor_ui.zig");
const motion = @import("../motion.zig");
const color = @import("../tools/color.zig");

const Editor = editor.Editor;

/// Every key event, before it does anything: Ctrl held, or a shortcut
/// made with it.
pub fn track(ed: *Editor, k: window.Key) void {
    const h = &ed.loupe.hold;
    switch (k.code) {
        .ctrl_left, .ctrl_right => if (k.pressed) h.press(motion.now()) else h.release(),
        .none => return,
        else => {
            if (!k.pressed or !h.down) return;
            // Ctrl came up while another window had the keyboard
            if (!k.ctrl) h.release() else if (!keepsHold(k)) h.cancel();
        },
    }
    ed.needs_render = true;
}

/// Keys that may come with Ctrl held for the magnifier: its own, and
/// Shift and Alt (they shape a drag and step arrows by 10; a shortcut
/// made with them ends in another key).
fn keepsHold(k: window.Key) bool {
    return switch (k.code) {
        .left, .right, .up, .down, .minus, .equal, .kp_minus, .kp_plus => true,
        .shift_left, .shift_right, .alt_left, .alt_right => true,
        else => false,
    };
}

/// A pointer button went down: the magnifier looks at the pointer again;
/// with Ctrl down before it shows, a Ctrl+click, not a hold.
pub fn pointerPressed(ed: *Editor) void {
    ui.loupePointed(ed);
    if (!ui.loupeHeld(ed)) ed.loupe.hold.cancel();
}

/// A key while the magnifier is up. True when taken.
pub fn onKey(ed: *Editor, k: window.Key) !bool {
    if (k.alt or !ui.loupeWanted(ed)) return false;
    switch (k.code) {
        .c => {
            if (k.ctrl or k.shift or !ui.loupeCapturing(ed)) return false;
            try copy(ed);
        },
        .minus, .kp_minus, .equal, .kp_plus => {
            if (k.ctrl and !ui.loupeHeld(ed)) return false;
            zoomBy(ed, if (k.code == .minus or k.code == .kp_minus) -1 else 1);
        },
        else => return false,
    }
    return true;
}

/// Wheel notches while the magnifier is up (up, positive, zooms in). True
/// when taken. With Ctrl down before it shows: a Ctrl+wheel, not a hold.
pub fn onScroll(ed: *Editor, steps: i32) bool {
    if (steps == 0) return false;
    if (!ui.loupeHeld(ed)) ed.loupe.hold.cancel();
    if (!ui.loupeWanted(ed)) return false;
    zoomBy(ed, steps);
    return true;
}

/// `d` zoom levels in (out when negative), within config.loupe_zooms.
fn zoomBy(ed: *Editor, d: i32) void {
    const levels = config.loupe_zooms;
    const cur = std.mem.indexOfScalar(u8, &levels, ed.loupe.zoom) orelse 1;
    const next: usize = @intCast(std.math.clamp(@as(i32, @intCast(cur)) + d, 0, levels.len - 1));
    if (levels[next] == ed.loupe.zoom) return;
    ed.loupe.zoom = levels[next];
    std.log.info("magnifier: zoom {d}x", .{ed.loupe.zoom});
    ed.needs_render = true;
}

/// The pixel's colour to the clipboard, "Copied" in the label.
fn copy(ed: *Editor) !void {
    const c = ui.loupeColor(ed) orelse return;
    var buf: [16]u8 = undefined;
    const hex = color.hex(&buf, c);
    const owned = try ed.alloc.dupe(u8, hex);
    ed.win.setClipboardText(owned) catch |e| {
        ed.alloc.free(owned);
        std.log.warn("magnifier: copy failed: {t}", .{e});
        return;
    };
    std.log.info("magnifier: copied {s}", .{hex});
    ed.tools.history.add(c);
    ui.loupeCopied(ed);
}
