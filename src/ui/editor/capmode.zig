//! The capture modes offered before a selection exists (the mode strip,
//! editor_ui/strip.zig), as macOS's and GNOME's screenshot bars do:
//!
//!     G  Area     drag a region (or click a window); stays here
//!     W  Window   pick a window (`shotlet window` starts anew)
//!     D  Screen   the monitor under the pointer
//!     J  Scroll   a scrolling capture (`shotlet scroll`)
//!     O  Text     drag over text: it is read and copied; stays here
//!     Q  Record   the recording picker, on this same frozen frame
//!     H  Timer    the self-timer (`shotlet timer`)
//!
//! The letters are ones no tool takes by default (a tool bound to one of
//! them wins); they work only while the strip shows.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const shapes_mod = @import("../shapes.zig");
const motion = @import("../motion.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const caches = @import("caches.zig");
const commands = @import("commands.zig");
const winpick = @import("winpick.zig");

const Editor = editor.Editor;
const Rect = shapes_mod.Rect;

pub const Mode = enum {
    area,
    window,
    screen,
    scroll,
    text,
    record,
    timer,

    /// evdev key code of its letter
    pub fn key(self: Mode) u32 {
        return switch (self) {
            .area => 34, // G
            .window => 17, // W
            .screen => 32, // D
            .scroll => 36, // J
            .text => 24, // O
            .record => 16, // Q
            .timer => 35, // H
        };
    }

    pub fn keyName(self: Mode) []const u8 {
        return switch (self) {
            .area => "G",
            .window => "W",
            .screen => "D",
            .scroll => "J",
            .text => "O",
            .record => "Q",
            .timer => "H",
        };
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .area => "Capture area",
            .window => "Capture window",
            .screen => "Capture screen",
            .scroll => "Scrolling capture",
            .text => "Capture text",
            .record => "Record screen",
            .timer => "Self-timer",
        };
    }

    pub fn icon(self: Mode) icons.Icon {
        return switch (self) {
            .area => .capture_area,
            .window => .capture_window,
            .screen => .capture_screen,
            .scroll => .capture_scroll,
            .text => .scan_text,
            .record => .record,
            .timer => .timer,
        };
    }

    /// The script's `button` name.
    pub fn scriptName(self: Mode) []const u8 {
        return switch (self) {
            inline else => |m| "mode_" ++ @tagName(m),
        };
    }

    /// Its group on the strip (a separator between groups).
    pub fn group(self: Mode) u8 {
        return switch (self) {
            .area, .window, .screen, .scroll => 0,
            .text, .record => 1,
            .timer => 2,
        };
    }
};

/// The strip's order.
pub const order = [_]Mode{ .area, .window, .screen, .scroll, .text, .record, .timer };

pub const State = struct {
    /// offered at all: an area capture (a selection to make)
    on: bool = false,
    /// where the windows were at capture, topmost first (image pixels;
    /// the caller's)
    windows: []const Rect = &.{},
    /// the window under the pointer, lit
    hover: ?u16 = null,
    /// the window under a press, selected if the press stays a click
    press: ?u16 = null,
    /// the strip's opacity, its place (buffer pixels of the toolbar's
    /// pane; empty when gone)
    alpha: motion.Tween = .{ .dur_ms = theme.motion_fast },
    rect: Rect = Rect.empty,
    shown_once: bool = false,
    /// the chosen mode's accent fill, sliding between buttons (x from the
    /// strip's left edge)
    act_x: motion.Tween = .{},
    /// a screen capture opens the editor: Screen selects the monitor here
    screen_in_place: bool = false,
    /// windows can be captured here (the GNOME extension, KWin)
    window_ok: bool = true,
    /// what Screen hands over to be delivered (image pixels)
    screen_rect: Rect = Rect.empty,
};

/// The mode the editor is in: Area, or Text for `shotlet text`.
pub fn current(ed: *const Editor) Mode {
    return if (ed.tools.text_capture) .text else .area;
}

/// The strip shows: before a selection (or during a press that may still
/// be a click), not over the help or a tool's mode.
pub fn wanted(ed: *const Editor) bool {
    if (!ed.capmode.on or ed.help_open or ed.tools.mode != .none) return false;
    return ed.doc.sel == null or winpick.mayBeClick(ed);
}

/// Why mode `m` cannot be picked here, or null when it can.
pub fn disabledWhy(ed: *const Editor, m: Mode) ?[]const u8 {
    if (m == .window and !ed.capmode.window_ok) return "This desktop does not tell apps where windows are";
    return null;
}

/// A mode's letter while the strip shows. True when taken.
pub fn onKey(ed: *Editor, k: window.Key) !bool {
    if (!wanted(ed) or k.ctrl or k.alt or k.shift or ed.drag != .none) return false;
    for (order) |m| if (m.key() == k.code) {
        try pick(ed, m);
        return true;
    };
    return false;
}

/// Switch to mode `m`: in place for Area, Text and (when the editor is
/// what a screen capture opens) Screen; else the editor closes for it.
pub fn pick(ed: *Editor, m: Mode) !void {
    ed.needs_render = true;
    if (disabledWhy(ed, m) != null) return;
    switch (m) {
        .area, .text => setText(ed, m == .text),
        .screen => screen(ed),
        .window => restart(ed, "window"),
        .scroll => restart(ed, "scroll"),
        .timer => restart(ed, "timer"),
        .record => commands.finish(ed, .record),
    }
}

fn setText(ed: *Editor, on: bool) void {
    if (ed.tools.text_capture == on) return;
    ed.tools.text_capture = on;
    std.log.info("capture mode: {s}", .{if (on) "text (the selection's text goes to the clipboard)" else "area"});
}

fn restart(ed: *Editor, cmd: [:0]const u8) void {
    std.log.info("capture mode: {s}, started anew", .{cmd});
    ed.next_capture = cmd;
    commands.finish(ed, .new_capture);
}

/// The monitor under the pointer: selected here, or handed over.
fn screen(ed: *Editor) void {
    const r = monitorAtPointer(ed);
    setText(ed, false);
    if (ed.capmode.screen_in_place) {
        caches.selDirty(ed);
        ed.doc.sel = r;
        caches.selDirty(ed);
        std.log.info("capture mode: screen, {d}x{d} selected", .{ r.w, r.h });
        return;
    }
    ed.capmode.screen_rect = r;
    commands.finish(ed, .screen);
}

/// The image rect of the monitor under the pointer (the whole image when
/// the layout is unknown).
pub fn monitorAtPointer(ed: *const Editor) Rect {
    const ip = ed.imgAt(ed.mouse);
    for (ed.monitors) |m| {
        const r: Rect = .{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) };
        if (r.contains(ip.x, ip.y)) return r;
    }
    return ed.doc.imageRect();
}

test "every mode has its own letter, none a tool's by default" {
    const binds = @import("../../app/binds.zig");
    for (order, 0..) |m, i| {
        for (order[i + 1 ..]) |o| try std.testing.expect(m.key() != o.key());
        for (binds.default_binds) |b| try std.testing.expect(b.ctrl or b.shift or b.code != m.key());
        try std.testing.expectEqualStrings(m.keyName(), binds.keyCodeName(m.key()));
    }
    try std.testing.expectEqualStrings("mode_window", Mode.window.scriptName());
}
