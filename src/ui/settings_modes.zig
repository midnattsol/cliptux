//! The capture modes in the Settings window (ui/settings.zig):
//!
//! - General › Capture modes: what a screen, all-screens or window capture
//!   does once taken (after_fullscreen), and the self-timer's seconds;
//! - Shortcuts › Capture shortcuts: with the GNOME extension, each mode's
//!   key (its settings, as `shotlet gnome-integration shortcut MODE KEY`
//!   sets them): click, then press the keys; Backspace clears, Esc keeps
//!   it. Elsewhere, the commands to bind in the desktop's settings.

const std = @import("std");
const dbus = @import("../platform/linux/dbus.zig");
const env_mod = @import("../app/env.zig");
const gnome = @import("../app/gnome.zig");
const gsettings = @import("../app/gsettings.zig");
const mode = @import("../app/modes/mode.zig");
const msettings = @import("../app/modes/settings.zig");
const S = @import("settings.zig");
const window = @import("../platform/linux/window.zig");

pub const Hit = union(enum) {
    after,
    timer,
    /// mode.shortcuts[i]
    key: u8,
};

const n = mode.shortcuts.len;

pub const State = struct {
    s: msettings.Settings = .{},
    /// the extension is active: its keys can be changed
    gnome: bool = false,
    sd_buf: [1100]u8 = undefined,
    sd_len: usize = 0,
    keys: [n][64]u8 = undefined,
    key_lens: [n]usize = @splat(0),
    recording: ?u8 = null,

    fn schemadir(self: *const State) []const u8 {
        return self.sd_buf[0..self.sd_len];
    }

    fn key(self: *const State, i: usize) []const u8 {
        return self.keys[i][0..self.key_lens[i]];
    }
};

pub fn load(alloc: std.mem.Allocator, env: env_mod.Env, bus: ?*dbus.Connection) State {
    var st: State = .{ .s = msettings.load(alloc, env.home) };
    const b = bus orelse return st;
    if (!gnome.isGnome() or !gnome.extensionActive(b)) return st;
    const sd = gnome.schemaDir(alloc, env, b, &st.sd_buf) catch return st;
    st.sd_len = sd.len;
    st.gnome = true;
    readKeys(&st, alloc, env);
    return st;
}

fn readKeys(st: *State, alloc: std.mem.Allocator, env: env_mod.Env) void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (mode.shortcuts, 0..) |sc, i| {
        st.key_lens[i] = 0;
        const v = gsettings.get(arena, env, st.schemadir(), gnome.ext_schema_id, sc.key) catch continue;
        const items = gsettings.parseStrv(arena, v) catch continue;
        if (items.len == 0 or items[0].len > st.keys[i].len) continue;
        @memcpy(st.keys[i][0..items[0].len], items[0]);
        st.key_lens[i] = items[0].len;
    }
}

pub fn drawGeneral(ui: *S.Ui, x: i32, y0: i32, w: i32, st: *const State) !i32 {
    const rh = ui.sc(64);
    const y = try S.groupTitle(ui, x, y0, w, "Capture modes", null);
    var card = S.beginCard(ui, x, y, w, 2 * rh);
    {
        const r = S.rowBegin(ui, &card, rh);
        S.rowTitle(ui, r, "After a screen or window capture", "Capture screen, all screens, a window");
        try S.chipButton(ui, r, .{ .mode = .after }, null, st.s.after.label(), false);
    }
    {
        const r = S.rowBegin(ui, &card, rh);
        S.rowTitle(ui, r, "Self-timer", "Timer\u{2026} counts down this long, then captures");
        var buf: [8]u8 = undefined;
        try S.chipButton(ui, r, .{ .mode = .timer }, null, std.fmt.bufPrint(&buf, "{d} s", .{st.s.timer_s}) catch "?", false);
    }
    return S.endCard(&card) + ui.sc(26);
}

pub fn drawShortcuts(ui: *S.Ui, x: i32, y0: i32, w: i32, st: *const State) !i32 {
    const rh = ui.sc(48);
    const y = try S.groupTitle(ui, x, y0, w, "Capture shortcuts", null);
    var card = S.beginCard(ui, x, y, w, @as(i32, n) * rh);
    for (mode.shortcuts, 0..) |sc, i| {
        const r = S.rowBegin(ui, &card, rh);
        var cmd_buf: [48]u8 = undefined;
        if (!st.gnome) {
            S.rowTitle(ui, r, sc.label, null);
            const cmd = std.fmt.bufPrint(&cmd_buf, "shotlet {s}", .{if (std.mem.eql(u8, sc.name, "area")) "" else sc.name}) catch "";
            _ = S.keyCaps(ui, r, &.{cmd}, null);
            continue;
        }
        S.rowTitle(ui, r, sc.label, null);
        const rec = st.recording != null and st.recording.? == i;
        const label = if (rec) "Press keys\u{2026}" else if (st.key_lens[i] == 0) "Off" else displayAccel(&cmd_buf, st.key(i));
        try S.chipButton(ui, r, .{ .mode = .{ .key = @intCast(i) } }, null, label, rec);
    }
    var yy = S.endCard(&card) + ui.sc(14);
    ui.label(x + ui.sc(4), yy, ui.sc(20), 13, ui.th.text_muted, .regular, if (st.gnome)
        "Backspace turns a shortcut off; Super combinations: shotlet gnome-integration shortcut MODE KEY."
    else
        "Bind these commands in your desktop's keyboard settings.");
    yy += ui.sc(20) + ui.sc(26);
    return yy;
}

fn displayAccel(buf: []u8, accel: []const u8) []const u8 {
    return @import("../app/accel.zig").display(buf, accel);
}

pub fn activate(h: Hit, st: *State, alloc: std.mem.Allocator, env: env_mod.Env) void {
    switch (h) {
        .after => {
            st.s.after = st.s.after.next();
            msettings.setAfter(alloc, env.home, st.s.after) catch |err| std.log.warn("could not save: {t}", .{err});
        },
        .timer => {
            const i = std.mem.indexOfScalar(u8, &mode.timer_choices, st.s.timer_s) orelse 0;
            st.s.timer_s = mode.timer_choices[(i + 1) % mode.timer_choices.len];
            msettings.setTimer(alloc, env.home, st.s.timer_s) catch |err| std.log.warn("could not save: {t}", .{err});
            if (st.gnome) setGnome(st, alloc, env, "timer-seconds", std.fmt.allocPrint(alloc, "{d}", .{st.s.timer_s}) catch return);
        },
        .key => |i| st.recording = if (st.recording == i) null else i,
    }
}

/// Write one of the extension's settings; `value` is owned.
fn setGnome(st: *State, alloc: std.mem.Allocator, env: env_mod.Env, key: []const u8, value: []u8) void {
    defer alloc.free(value);
    gsettings.set(alloc, env, st.schemadir(), gnome.ext_schema_id, key, value) catch |err|
        std.log.warn("could not change the GNOME integration's {s}: {t}", .{ key, err });
}

/// A key press while a mode's shortcut is being recorded. True when it
/// was taken.
pub fn onKey(st: *State, k: window.Key, alloc: std.mem.Allocator, env: env_mod.Env) bool {
    const i = st.recording orelse return false;
    if (k.code == window.KEY_ESC) {
        st.recording = null;
        return true;
    }
    var buf: [64]u8 = undefined;
    const accel = if (k.code == window.KEY_BACKSPACE) "" else accelFor(&buf, k) orelse return true;
    st.recording = null;
    const value = if (accel.len == 0)
        alloc.dupe(u8, "@as []") catch return true
    else
        std.fmt.allocPrint(alloc, "['{s}']", .{accel}) catch return true;
    setGnome(st, alloc, env, mode.shortcuts[i].key, value);
    readKeys(st, alloc, env);
    return true;
}

/// The GNOME accelerator of a key press ("<Ctrl><Shift>Print"); null for
/// a bare modifier or a key without a name.
pub fn accelFor(buf: []u8, k: window.Key) ?[]const u8 {
    const name = keyName(k) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{
        if (k.ctrl) "<Ctrl>" else "",
        if (k.shift) "<Shift>" else "",
        if (k.alt) "<Alt>" else "",
        name,
    }) catch null;
}

fn keyName(k: window.Key) ?[]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyz";
    const sym = k.keysym;
    if (sym >= 'a' and sym <= 'z') return letters[sym - 'a' ..][0..1];
    if (sym >= 'A' and sym <= 'Z') return letters[sym - 'A' ..][0..1];
    if (sym >= '0' and sym <= '9') return "0123456789"[sym - '0' ..][0..1];
    if (sym >= 0xffbe and sym <= 0xffc9) return ([_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" })[sym - 0xffbe];
    return switch (k.code) {
        99 => "Print",
        102 => "Home",
        107 => "End",
        104 => "Page_Up",
        109 => "Page_Down",
        110 => "Insert",
        57 => "space",
        else => null,
    };
}

test "key presses become GNOME accelerators" {
    var buf: [64]u8 = undefined;
    const print: window.Key = .{ .code = 99, .pressed = true, .ctrl = true, .shift = true };
    try std.testing.expectEqualStrings("<Ctrl><Shift>Print", accelFor(&buf, print).?);
    const w: window.Key = .{ .code = 17, .pressed = true, .ctrl = false, .shift = false, .alt = true, .keysym = 'w' };
    try std.testing.expectEqualStrings("<Alt>w", accelFor(&buf, w).?);
    const shift_only: window.Key = .{ .code = 42, .pressed = true, .ctrl = false, .shift = true };
    try std.testing.expectEqual(@as(?[]const u8, null), accelFor(&buf, shift_only));
}
