//! The capture modes in the Settings window (ui/settings.zig):
//!
//! - General › Capture modes: what a screen, all-screens or window capture
//!   does once taken (after_fullscreen), and the self-timer's seconds;
//! - Shortcuts › Capture shortcuts: with the GNOME extension, each mode's
//!   key (its settings, as `shotlet gnome-integration shortcut MODE KEY`
//!   sets them): click, then press the keys; Backspace clears, Esc keeps
//!   it. Elsewhere, the commands to bind in the desktop's settings.

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("../app/env.zig");
const shell = @import("../platform/api.zig").shell;
const mode = @import("../app/modes/mode.zig");
const msettings = @import("../app/modes/settings.zig");
const S = @import("settings.zig");
const window = @import("../platform/api.zig").window;
const Accel = @import("../app/accel.zig").Accel;

pub const Hit = union(enum) {
    after,
    timer,
    /// mode.shortcuts[i]
    key: u8,
};

const n = mode.shortcuts.len;

pub const State = struct {
    s: msettings.Settings = .{},
    /// the shell integration holds the keys: they can be changed
    gnome: bool = false,
    /// where it keeps them (shell.shortcutStore)
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

pub fn load(alloc: std.mem.Allocator, env: env_mod.Env, bus: ?*desktop.Session) State {
    var st: State = .{ .s = msettings.load(alloc, env.home) };
    const b = bus orelse return st;
    const sd = shell.shortcutStore(alloc, env, b, &st.sd_buf) orelse return st;
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
        const accel = shell.getShortcut(arena, env, st.schemadir(), sc.name) orelse continue;
        if (accel.len > st.keys[i].len) continue;
        @memcpy(st.keys[i][0..accel.len], accel);
        st.key_lens[i] = accel.len;
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
        const label = if (rec) "Press keys\u{2026}" else if (st.key_lens[i] == 0) "Off" else st.key(i);
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
            if (st.gnome) shell.setTimerSeconds(alloc, env, st.schemadir(), st.s.timer_s) catch |err|
                std.log.warn("could not change the GNOME integration's timer-seconds: {t}", .{err});
        },
        .key => |i| st.recording = if (st.recording == i) null else i,
    }
}

/// A key press while a mode's shortcut is being recorded. True when it
/// was taken.
pub fn onKey(st: *State, k: window.Key, alloc: std.mem.Allocator, env: env_mod.Env) bool {
    const i = st.recording orelse return false;
    if (k.code == .escape) {
        st.recording = null;
        return true;
    }
    const accel: ?Accel = if (k.code == .backspace) null else accelFor(k) orelse return true;
    st.recording = null;
    const name = mode.shortcuts[i].name;
    shell.setShortcut(alloc, env, st.schemadir(), name, accel) catch |err|
        std.log.warn("could not change the GNOME integration's {s} shortcut: {t}", .{ name, err });
    readKeys(st, alloc, env);
    return true;
}

/// The global shortcut of a key press ("Ctrl+Shift+Print"): letters
/// and digits as the layout types them, F1 to F12, Print, Home, End,
/// Page Up, Page Down, Insert and Space; null for any other key.
pub fn accelFor(k: window.Key) ?Accel {
    const key = shortcutKey(k) orelse return null;
    return .{ .mods = .{ .ctrl = k.ctrl, .shift = k.shift, .alt = k.alt }, .key = key };
}

fn shortcutKey(k: window.Key) ?window.KeyCode {
    if (k.char < 0x80) {
        const ch: u8 = @intCast(k.char);
        if (window.KeyCode.letter(ch) orelse window.KeyCode.digit(ch)) |c| return c;
    }
    if (k.code.functionNumber()) |f| return if (f <= 12) k.code else null;
    return switch (k.code) {
        .print, .home, .end, .page_up, .page_down, .insert, .space => k.code,
        else => null,
    };
}

test "key presses become global shortcuts" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const print: window.Key = .{ .code = .print, .pressed = true, .ctrl = true, .shift = true };
    try t.expectEqualStrings("Ctrl+Shift+Print", accelFor(print).?.format(&buf).?);
    const w: window.Key = .{ .code = .w, .pressed = true, .ctrl = false, .shift = false, .alt = true, .char = 'w' };
    try t.expectEqualStrings("Alt+W", accelFor(w).?.format(&buf).?);
    // the layout's letter, not the key's place (AZERTY: A where US has Q)
    const azerty_a: window.Key = .{ .code = .q, .pressed = true, .ctrl = true, .shift = false, .char = 'a' };
    try t.expectEqual(window.KeyCode.a, accelFor(azerty_a).?.key);
    const shift_only: window.Key = .{ .code = .shift_left, .pressed = true, .ctrl = false, .shift = true };
    try t.expectEqual(@as(?Accel, null), accelFor(shift_only));
    const f13: window.Key = .{ .code = .f13, .pressed = true, .ctrl = false, .shift = false };
    try t.expectEqual(@as(?Accel, null), accelFor(f13));
    const e_acute: window.Key = .{ .code = .digit_2, .pressed = true, .ctrl = false, .shift = false, .char = 0xe9 };
    try t.expectEqual(@as(?Accel, null), accelFor(e_acute));
}
