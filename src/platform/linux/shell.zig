//! The shell integration seam on Linux: the Shotlet GNOME Shell
//! extension (gnome.zig). It captures without prompts, holds the global
//! shortcuts of the capture modes (its GSettings keys), keeps floating
//! windows above the others on mutter and places them.

const std = @import("std");
const dbus = @import("dbus.zig");
const gnome = @import("gnome.zig");
const gsettings = @import("gnome/gsettings.zig");
const gtk_accel = @import("gnome/gtk_accel.zig");
const mode_keys = @import("gnome/mode_keys.zig");
const shell_bus = @import("gnome/shell_bus.zig");
const shellcap = @import("gnome/shellcap.zig");
const types = @import("../api/shell.zig");
const Env = @import("../../app/env.zig").Env;
const capture = @import("../../app/capture.zig");
const mode = @import("../../app/modes/mode.zig");
const Accel = @import("../../app/accel.zig").Accel;

pub const State = types.State;
pub const Words = types.Words;
pub const CaptureInfo = types.CaptureInfo;
pub const Handoff = types.Handoff;
pub const HandedCapture = types.HandedCapture;

/// How Settings names the integration (GNOME's) and the desktop's
/// shortcuts here.
pub fn words() Words {
    if (!gnome.isGnome()) return .{};
    return .{
        .title = "GNOME integration",
        .part = "Shell extension",
        .command = "shotlet gnome-integration",
        .system_key = "GNOME\u{2019}s screenshot key",
        .custom_shortcuts = "GNOME Settings \u{203A} Keyboard \u{203A} Custom Shortcuts",
    };
}

/// This desktop has an integration to offer (GNOME).
pub const applies = gnome.isGnome;

/// The integration runs.
pub fn active(s: *dbus.Connection) bool {
    return gnome.extensionActive(s);
}

/// applies() and active(), on a connection of its own.
pub fn activeNow(gpa: std.mem.Allocator, env: Env) bool {
    if (!gnome.isGnome()) return false;
    var bus = dbus.Connection.connectSession(gpa, env.session.bus) catch return false;
    defer bus.deinit();
    return gnome.extensionActive(&bus);
}

/// Where the integration stands, for Settings.
pub fn state(gpa: std.mem.Allocator, env: Env, s: ?*dbus.Connection) State {
    if (!gnome.isGnome()) return .unsupported;
    const b = s orelse return .missing;
    return switch (gnome.installState(gpa, env, b)) {
        .active => .active,
        // nothing to click: it loads at the next login
        .next_login => .installed,
        else => .missing,
    };
}

/// Install and enable it (moving shortcuts that run shotlet to it).
pub fn install(gpa: std.mem.Allocator, env: Env, s: ?*dbus.Connection) State {
    return switch (gnome.install(gpa, env, s, .yes)) {
        .active => .active,
        .installed_relogin => .installed,
        .failed => .failed,
    };
}

pub const captureInfo = gnome.captureInfo;

/// A line for Settings about the last install.
pub const note = gnome.note;

/// Ask it to take a capture in `req`'s mode (it starts another shotlet).
pub fn requestCapture(gpa: std.mem.Allocator, s: *dbus.Connection, req: mode.Request) Handoff {
    return shell_bus.requestMode(gpa, s, req);
}

/// Put our window titled `title` at x, y (logical); false when it cannot.
pub const place = shell_bus.place;

/// The capture it handed over.
pub fn loadHanded(gpa: std.mem.Allocator, env: Env, args: HandedCapture) !capture.Capture {
    return shellcap.load(gpa, env.runtime_dir, args);
}

/// It runs and Shotlet was started by it: an install that waited for the
/// next login can finish.
pub const finishPendingSetup = gnome.finishPendingSetup;

/// `shotlet gnome-integration SUB ARGS`.
pub const runCli = gnome.runCli;

// --- the capture modes' global shortcuts (its settings) ---

/// Where its settings are (into `buf`), when it runs; null otherwise.
pub fn shortcutStore(gpa: std.mem.Allocator, env: Env, s: *dbus.Connection, buf: []u8) ?[]const u8 {
    if (!gnome.isGnome() or !gnome.extensionActive(s)) return null;
    return gnome.schemaDir(gpa, env, s, buf) catch null;
}

/// The first shortcut bound to `name` ("Ctrl+Print": GTK's notation in
/// the extension's settings, shown in the neutral one); null when none.
pub fn getShortcut(arena: std.mem.Allocator, env: Env, store: []const u8, name: []const u8) ?[]const u8 {
    var kbuf: [32]u8 = undefined;
    const v = gsettings.get(arena, env, store, gnome.ext_schema_id, mode_keys.settingsKey(&kbuf, name)) catch return null;
    const items = gsettings.parseStrv(arena, v) catch return null;
    if (items.len == 0) return null;
    const buf = arena.alloc(u8, 64) catch return items[0];
    return gtk_accel.display(buf, items[0]);
}

/// Bind `name` to `accel` (null: none), in GTK's notation.
pub fn setShortcut(gpa: std.mem.Allocator, env: Env, store: []const u8, name: []const u8, accel: ?Accel) !void {
    var gbuf: [64]u8 = undefined;
    const gtk: ?[]const u8 = if (accel) |a| gtk_accel.fromNeutral(a, &gbuf) orelse return error.BadShortcut else null;
    const value = if (gtk) |g| try gsettings.formatStrv(gpa, &.{g}) else try gpa.dupe(u8, "@as []");
    defer gpa.free(value);
    var kbuf: [32]u8 = undefined;
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, mode_keys.settingsKey(&kbuf, name), value);
}

/// Its self-timer's seconds, kept with Shotlet's own.
pub fn setTimerSeconds(gpa: std.mem.Allocator, env: Env, store: []const u8, seconds: u32) !void {
    var buf: [16]u8 = undefined;
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, "timer-seconds", try std.fmt.bufPrint(&buf, "{d}", .{seconds}));
}
