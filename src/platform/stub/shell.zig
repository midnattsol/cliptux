//! The shell integration seam of the contract (api/shell.zig): whether
//! the desktop has one, installing it, captures it takes, placing our
//! windows, and the capture modes' global shortcuts it holds.

const std = @import("std");
const types = @import("../api/shell.zig");
const desktop = @import("desktop.zig");
const Env = @import("../../app/env.zig").Env;
const capture = @import("../../app/capture.zig");
const mode = @import("../../app/modes/mode.zig");
const Accel = @import("../../app/accel.zig").Accel;

pub const State = types.State;
pub const Words = types.Words;
pub const CaptureInfo = types.CaptureInfo;
pub const Handoff = types.Handoff;
pub const HandedCapture = types.HandedCapture;

/// How Settings names the integration and the desktop's shortcuts here.
pub fn words() Words {
    return .{};
}
/// This desktop has an integration to offer.
pub fn applies() bool {
    return false;
}
/// The integration runs.
pub fn active(s: *desktop.Session) bool {
    _ = s;
    return false;
}
/// applies() and active(), on a session of its own.
pub fn activeNow(gpa: std.mem.Allocator, env: Env) bool {
    _ = .{ gpa, env };
    return false;
}
pub fn state(gpa: std.mem.Allocator, env: Env, s: ?*desktop.Session) State {
    _ = .{ gpa, env, s };
    return .unsupported;
}
pub fn install(gpa: std.mem.Allocator, env: Env, s: ?*desktop.Session) State {
    _ = .{ gpa, env, s };
    return .unsupported;
}
pub fn captureInfo(gpa: std.mem.Allocator, s: *desktop.Session) CaptureInfo {
    _ = .{ gpa, s };
    return .{};
}
/// A line for Settings about the last install.
pub fn note() ?[]const u8 {
    return null;
}
/// Ask it to take a capture in `req`'s mode (it starts another shotlet).
pub fn requestCapture(gpa: std.mem.Allocator, s: *desktop.Session, req: mode.Request) Handoff {
    _ = .{ gpa, s, req };
    return .unavailable;
}
/// Put our window titled `title` at x, y (logical); false when it cannot.
pub fn place(gpa: std.mem.Allocator, s: *desktop.Session, title: []const u8, x: i32, y: i32) bool {
    _ = .{ gpa, s, title, x, y };
    return false;
}
/// The capture it handed over.
pub fn loadHanded(gpa: std.mem.Allocator, env: Env, args: HandedCapture) error{Unavailable}!capture.Capture {
    _ = .{ gpa, env, args };
    return error.Unavailable;
}
pub fn finishPendingSetup(env: Env) void {
    _ = env;
}
/// The integration's command (`shotlet gnome-integration SUB ARGS`).
pub fn runCli(gpa: std.mem.Allocator, env: Env, sub: []const u8, rest: []const []const u8) error{Unavailable}!void {
    _ = .{ gpa, env, sub, rest };
    return error.Unavailable;
}
/// Where its shortcut settings are (into `buf`), when it runs.
pub fn shortcutStore(gpa: std.mem.Allocator, env: Env, s: *desktop.Session, buf: []u8) ?[]const u8 {
    _ = .{ gpa, env, s, buf };
    return null;
}
/// The first shortcut bound to shortcut `name` (mode.shortcuts) as
/// people read it: app/accel.zig's notation ("Ctrl+Print"), or the
/// desktop's own when that has a key the notation cannot name; null when
/// none.
pub fn getShortcut(arena: std.mem.Allocator, env: Env, store: []const u8, name: []const u8) ?[]const u8 {
    _ = .{ arena, env, store, name };
    return null;
}
/// Bind shortcut `name` to `accel` (null: none).
pub fn setShortcut(gpa: std.mem.Allocator, env: Env, store: []const u8, name: []const u8, accel: ?Accel) error{Unavailable}!void {
    _ = .{ gpa, env, store, name, accel };
    return error.Unavailable;
}
pub fn setTimerSeconds(gpa: std.mem.Allocator, env: Env, store: []const u8, seconds: u32) error{Unavailable}!void {
    _ = .{ gpa, env, store, seconds };
    return error.Unavailable;
}
