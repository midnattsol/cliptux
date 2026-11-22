//! The Settings window's model: its views, the controls a click or key
//! can hit, their on-screen regions and the window's mutable UI state.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const config = @import("../../app/config.zig");
const theme_mod = @import("../theme.zig");
const env_mod = @import("../../app/env.zig");
const shell = @import("../../platform/api.zig").shell;
const settings_modes = @import("../settings_modes.zig");
const focus = @import("focus.zig");

const Theme = theme_mod.Theme;

pub const View = enum { general, editor, shortcuts, recording };

pub const Hit = union(enum) {
    view: View,
    rec: u8, // recui/settings_rec.zig
    toggle_notify,
    toggle_copy_on_save,
    /// forget the ScreenCast restore token so the next capture asks again
    forget_monitors,
    /// forget the token and Shotlet's portal permissions (permissions.zig)
    reset_permissions,
    /// pick the folder Ctrl+S saves to (FileChooser portal)
    choose_folder,
    th_minus,
    th_plus,
    color: u3,
    bind: config.Action,
    reset_binds,
    win_close,
    /// when the thumbnail shows: after Save, Copy and Save, never
    cycle_thumbnail,
    /// when the magnifier shows: always, while selecting, never
    cycle_loupe,
    quick_minus,
    quick_plus,
    toggle_history,
    hist_minus,
    hist_plus,
    hist_mb_minus,
    hist_mb_plus,
    open_history,
    clear_history,
    integration_enable,
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

/// What the content is drawn into: its height (buffer px, without the
/// frame) and the display scale.
pub const Viewport = struct { h: i32, f: f64 };

pub fn headerHeight(f: f64) i32 {
    return @intFromFloat(@round(52.0 * f));
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
    /// the portal (api.capture)
    direct: bool = false,
    /// how the last capture went (api.capture.lastPath)
    last_path: ?@import("../../platform/api.zig").capture.Path = null,
    /// what Reset permissions did
    perm_note: @import("permissions.zig").Note = .{},
    pending_focus: ?usize = null,
    /// scroll the focused control into view after the next draw
    reveal_focus: bool = false,
    env: env_mod.Env = undefined,
    /// the shell integration, and how the backend names it
    integration: shell.State = .unsupported,
    words: shell.Words = .{},
    capture: shell.CaptureInfo = .{},
    /// Clear history takes two clicks: the first asks
    history_clear: enum { idle, asking, cleared } = .idle,
    modes: settings_modes.State = .{},

    pub fn scrollBy(self: *State, step: i32, vp: Viewport) void {
        const max_scroll = @max(0, self.content_h - vp.h);
        const new = std.math.clamp(self.scroll_y + step, 0, max_scroll);
        if (new != self.scroll_y) self.dirty = true;
        self.scroll_y = new;
    }

    pub fn moveFocus(self: *State, regions: []const Region, vp: Viewport, forward: bool) void {
        self.focus = focus.nextFocus(regions, self.focus, forward);
        self.ensureVisible(regions, vp);
        self.dirty = true;
    }

    /// Scroll so the focused control is not hidden under the header or
    /// below the bottom edge.
    pub fn ensureVisible(self: *State, regions: []const Region, vp: Viewport) void {
        const hit = self.focus orelse return;
        const r = focus.findRegion(regions, hit) orelse return;
        if (focus.isHeader(hit)) return;
        const pad: i32 = @intFromFloat(@round(12.0 * vp.f));
        const top = headerHeight(vp.f) + pad;
        const bottom = vp.h - pad;
        if (r.y < top) {
            self.scrollBy(r.y - top, vp);
        } else if (r.y + r.h > bottom) {
            self.scrollBy(r.y + r.h - bottom, vp);
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
    pub fn revealFocus(self: *State, regions: []const Region, vp: Viewport) void {
        if (!self.reveal_focus) return;
        // positions are only known after a draw at the current size
        self.reveal_focus = false;
        const before = self.scroll_y;
        self.scrollBy(0, vp); // clamp to the new size
        self.ensureVisible(regions, vp);
        self.dirty = self.scroll_y != before or self.focus != null;
    }
};
