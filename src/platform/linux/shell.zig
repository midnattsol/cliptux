//! The shell integration seam on Linux: the Shotlet GNOME Shell
//! extension (gnome.zig). It captures without prompts, holds the global
//! shortcuts of the capture modes (its GSettings keys), keeps floating
//! windows above the others on mutter and places them.

const std = @import("std");
const dbus = @import("dbus.zig");
const gnome = @import("gnome.zig");
const gsettings = @import("gnome/gsettings.zig");
const shell_bus = @import("gnome/shell_bus.zig");
const shellcap = @import("gnome/shellcap.zig");
const types = @import("../api/shell.zig");
const Env = @import("../../app/env.zig").Env;
const capture = @import("../../app/capture.zig");
const mode = @import("../../app/modes/mode.zig");

pub const State = types.State;
pub const CaptureInfo = types.CaptureInfo;
pub const Handoff = types.Handoff;
pub const HandedCapture = types.HandedCapture;

/// This desktop has an integration to offer (GNOME).
pub const applies = gnome.isGnome;

/// The integration runs.
pub fn active(s: *dbus.Connection) bool {
    return gnome.extensionActive(s);
}

/// applies() and active(), on a connection of its own.
pub fn activeNow(gpa: std.mem.Allocator, env: Env) bool {
    if (!gnome.isGnome()) return false;
    var bus = dbus.Connection.connectSession(gpa, env.bus_addr) catch return false;
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

/// The first accelerator bound to `key` ("<Ctrl>Print"); null when none.
pub fn getShortcut(arena: std.mem.Allocator, env: Env, store: []const u8, key: []const u8) ?[]const u8 {
    const v = gsettings.get(arena, env, store, gnome.ext_schema_id, key) catch return null;
    const items = gsettings.parseStrv(arena, v) catch return null;
    return if (items.len == 0) null else items[0];
}

/// Bind `key` to `accel` (null: none).
pub fn setShortcut(gpa: std.mem.Allocator, env: Env, store: []const u8, key: []const u8, accel: ?[]const u8) !void {
    const value = if (accel) |a| try std.fmt.allocPrint(gpa, "['{s}']", .{a}) else try gpa.dupe(u8, "@as []");
    defer gpa.free(value);
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, key, value);
}

/// Its self-timer's seconds, kept with Shotlet's own.
pub fn setTimerSeconds(gpa: std.mem.Allocator, env: Env, store: []const u8, seconds: u32) !void {
    var buf: [16]u8 = undefined;
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, "timer-seconds", try std.fmt.bufPrint(&buf, "{d}", .{seconds}));
}
