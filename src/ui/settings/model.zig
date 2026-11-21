//! The Settings window's model: its views, the controls a click or key
//! can hit, their on-screen regions and the window's mutable UI state.

const std = @import("std");
const window = @import("../window.zig");
const config = @import("../../app/config.zig");
const theme_mod = @import("../theme.zig");
const dbus = @import("../../platform/dbus.zig");
const env_mod = @import("../../app/env.zig");
const gnome = @import("../../app/gnome.zig");
const settings_modes = @import("../settings_modes.zig");
const focus = @import("focus.zig");

const Window = window.Window;
const Theme = theme_mod.Theme;

pub const View = enum { general, editor, shortcuts, recording };

pub const Hit = union(enum) {
    view: View,
    rec: u8, // recui/settings_rec.zig
    toggle_notify,
    toggle_copy_on_save,
    /// forget the ScreenCast restore token so the next capture asks again
    forget_monitors,
    /// pick the folder Ctrl+S saves to (FileChooser portal)
    choose_folder,
    th_minus,
    th_plus,
    color: u3,
    bind: config.Action,
    reset_binds,
    win_close,
    toggle_quick,
    quick_minus,
    quick_plus,
    toggle_history,
    hist_minus,
    hist_plus,
    hist_mb_minus,
    hist_mb_plus,
    open_history,
    clear_history,
    gnome_enable,
    /// the capture modes' rows (settings_modes.zig)
    mode: settings_modes.Hit,
};

pub const Region = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hit: Hit,
    /// corner radius of the control, for its focus ring
    radius: f64 = 8,

    pub fn contains(self: Region, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

/// The GNOME Shell integration as the Settings window shows it.
pub const GnomeState = enum { not_gnome, active, installed, missing, failed };

pub fn gnomeState(alloc: std.mem.Allocator, bus: ?*dbus.Connection) GnomeState {
    if (!gnome.isGnome()) return .not_gnome;
    const b = bus orelse return .missing;
    if (gnome.extensionActive(b)) return .active;
    const st = gnome.shellState(alloc, b) orelse return .missing;
    return if (st == 99) .missing else .installed;
}

pub fn headerHeight(win: *const Window) i32 {
    return @intFromFloat(@round(52.0 * @as(f64, @floatFromInt(win.scale120)) / 120.0));
}

/// Mutable UI state of the settings window.
pub const State = struct {
    view: View = .general,
    prefs: theme_mod.Prefs = .{},
    theme: Theme = Theme.get(true, null),
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    dirty: bool = true,
    scroll_y: i32 = 0,
    content_h: i32 = 0,
    recording: ?config.Action = null,
    hover_idx: i32 = -1,
    /// keyboard focus (Tab / Shift+Tab); null until the first Tab
    focus: ?Hit = null,
    /// the last capture went through the desktop's own interface, not
    /// the portal (app/direct.zig)
    direct: bool = false,
    pending_focus: ?usize = null,
    /// scroll the focused control into view after the next draw
    reveal_focus: bool = false,
    env: env_mod.Env = undefined,
    gnome: GnomeState = .not_gnome,
    capture: gnome.CaptureInfo = .{},
    history_cleared: bool = false,
    modes: settings_modes.State = .{},

    pub fn scrollBy(self: *State, step: i32, win: *const Window) void {
        const max_scroll = @max(0, self.content_h - @as(i32, @intCast(win.height)));
        const new = std.math.clamp(self.scroll_y + step, 0, max_scroll);
        if (new != self.scroll_y) self.dirty = true;
        self.scroll_y = new;
    }

    pub fn moveFocus(self: *State, regions: []const Region, win: *const Window, forward: bool) void {
        self.focus = focus.nextFocus(regions, self.focus, forward);
        self.ensureVisible(regions, win);
        self.dirty = true;
    }

    /// Scroll so the focused control is not hidden under the header or
    /// below the bottom edge.
    pub fn ensureVisible(self: *State, regions: []const Region, win: *const Window) void {
        const hit = self.focus orelse return;
        const r = focus.findRegion(regions, hit) orelse return;
        if (focus.isHeader(hit)) return;
        const f = @as(f64, @floatFromInt(win.scale120)) / 120.0;
        const pad: i32 = @intFromFloat(@round(12.0 * f));
        const top = headerHeight(win) + pad;
        const bottom = @as(i32, @intCast(win.height)) - pad;
        if (r.y < top) {
            self.scrollBy(r.y - top, win);
        } else if (r.y + r.h > bottom) {
            self.scrollBy(r.y + r.h - bottom, win);
        }
    }

    /// Focus the n-th focusable control (SHOTLET_SETTINGS_FOCUS), once
    /// the regions of a draw are known.
    pub fn applyPendingFocus(self: *State, regions: []const Region) void {
        const n = self.pending_focus orelse return;
        self.pending_focus = null;
        var i: usize = 0;
        for (regions) |r| if (focus.isFocusable(r.hit)) {
            if (i == n) {
                self.focus = r.hit;
                self.reveal_focus = true;
                break;
            }
            i += 1;
        };
    }

    /// Scroll the focused control into view after a draw at a new size.
    pub fn revealFocus(self: *State, regions: []const Region, win: *const Window) void {
        if (!self.reveal_focus) return;
        // positions are only known after a draw at the current size
        self.reveal_focus = false;
        const before = self.scroll_y;
        self.scrollBy(0, win); // clamp to the new size
        self.ensureVisible(regions, win);
        self.dirty = self.scroll_y != before or self.focus != null;
    }
};
