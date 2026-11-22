//! Installing the integration end to end: once the extension is active,
//! point it at this binary, offer to move custom shortcuts that run
//! shotlet to it, and offer it GNOME's own screenshot key. Messages go to
//! stderr; a line about the outcome is kept for the Settings window.

const std = @import("std");
const dbus = @import("../dbus.zig");
const gsettings = @import("gsettings.zig");
const Env = @import("../../../app/env.zig").Env;
const extension = @import("extension.zig");
const capture = @import("capture.zig");
const custom = @import("custom.zig");
const screenshot_keys = @import("screenshot_keys.zig");
const displayAccel = @import("accel.zig").display;
const ask = @import("ask.zig");
const next_login = @import("next_login.zig");
const pending_setup = @import("pending_setup.zig");

const ext_schema_id = extension.ext_schema_id;
const out = std.debug.print;

/// What to do with custom shortcuts that run shotlet once the extension
/// is active.
pub const MoveShortcuts = ask.Answer;

/// Install and enable the extension (see gnome.zig); once it is active,
/// set it up for prompt-free captures.
pub fn install(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection, move: MoveShortcuts) extension.InstallResult {
    const r = extension.installExtension(gpa, env, bus_opt);
    switch (r) {
        .active => {
            pending_setup.clear(env.home);
            setUp(gpa, env, bus_opt.?, move);
        },
        .installed_relogin => next_login.prepare(gpa, env, move),
        .failed => {},
    }
    return r;
}

/// A line for the Settings window about the last install.
pub var note_buf: [256]u8 = undefined;
pub var note_len: usize = 0;
pub fn note() ?[]const u8 {
    return if (note_len > 0) note_buf[0..note_len] else null;
}
fn setNote(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&note_buf, fmt, args) catch note_buf[0..0];
    note_len = s.len;
}

/// Point the extension at `exe` (this binary; nothing when unknown).
pub fn pointAt(arena: std.mem.Allocator, env: Env, schemadir: []const u8, exe: []const u8) !void {
    if (exe.len == 0) return;
    try gsettings.set(arena, env, schemadir, ext_schema_id, "shotlet-path", try gsettings.formatString(arena, exe));
}

pub fn selfExe(buf: []u8) ![]const u8 {
    const rc = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", buf.ptr, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS or rc >= buf.len) return error.NoExe;
    return buf[0..rc];
}

/// The extension is active: point it at this binary and sort out the
/// shortcut (see gnome.zig). Messages go to stderr.
fn setUp(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, move: MoveShortcuts) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sd_buf: [1100]u8 = undefined;
    const schemadir = extension.schemaDir(gpa, env, bus, &sd_buf) catch return;
    var exe_buf: [1024]u8 = undefined;
    const exe = selfExe(&exe_buf) catch "";
    pointAt(arena, env, schemadir, exe) catch |err| {
        std.log.warn("could not configure the extension ({t}): it may be an older version", .{err});
        return;
    };
    if (!offerCustomShortcuts(arena, env, schemadir, exe, move)) return;
    takeGnomeKey(arena, env, schemadir, move);
    var info = waitForShortcut(gpa, bus);
    capture.printShortcut(&info);
}

/// Offer to move custom shortcuts that run shotlet to the extension;
/// false when moving them failed (setting up stops there).
fn offerCustomShortcuts(arena: std.mem.Allocator, env: Env, schemadir: []const u8, exe: []const u8, move: MoveShortcuts) bool {
    const found = custom.findShotletShortcuts(arena, env, exe) catch &.{};
    if (found.len == 0) return true;
    var names: std.ArrayList(u8) = .empty;
    for (found, 0..) |c, i| names.print(arena, "{s}\u{201C}{s}\u{201D} ({s})", .{ if (i > 0) ", " else "", c.name, if (c.binding.len > 0) c.binding else "no key" }) catch {};
    out("Your custom shortcut {s} runs shotlet.\n", .{names.items});
    const yes = ask.resolve(move, "Move it to the GNOME integration, so it captures straight away inside GNOME Shell?");
    if (yes) {
        custom.moveShortcuts(arena, env, schemadir, found) catch |err| {
            out("Could not move it ({t}); it keeps working as it is.\n", .{err});
            return false;
        };
        out("Moved: the same key now captures through the GNOME integration, without any prompt.\n" ++
            "`shotlet gnome-integration uninstall` puts the custom shortcut back.\n", .{});
    } else {
        // one key, one binding: leave the key to the custom shortcut
        // (shotlet run from it asks the integration anyway)
        gsettings.set(arena, env, schemadir, ext_schema_id, "capture-shortcut", "@as []") catch {};
        out("Kept it; it captures without prompts too (shotlet asks the integration).\n", .{});
    }
    return true;
}

/// Let the extension pick up its settings: wait up to half a second for
/// it to report a shortcut.
fn waitForShortcut(gpa: std.mem.Allocator, bus: *dbus.Connection) capture.CaptureInfo {
    var tries: usize = 0;
    var info = capture.captureInfo(gpa, bus);
    while (info.shortcut() == null and info.capture and tries < 10) : (tries += 1) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
        info = capture.captureInfo(gpa, bus);
    }
    return info;
}

/// The extension's key is one of GNOME's own screenshot shortcuts (stock
/// GNOME: Print opens its screenshot tool): offer to give it to Shotlet,
/// moving GNOME's screenshot tool to Shift+Super+S when that is free.
/// Only the shortcuts holding that key change; uninstall restores them.
fn takeGnomeKey(arena: std.mem.Allocator, env: Env, schemadir: []const u8, move: MoveShortcuts) void {
    const ours = gsettings.parseStrv(arena, gsettings.get(arena, env, schemadir, ext_schema_id, "capture-shortcut") catch return) catch return;
    if (ours.len == 0) return;
    const taken = screenshot_keys.keysToTake(arena, env, ours) catch return;
    if (taken.len == 0) return;
    var kb: [64]u8 = undefined;
    var mb: [64]u8 = undefined;
    const key = displayAccel(&kb, ours[0]);
    const where = whereToolGoes(arena, taken, &mb) catch return;
    out("{s} opens GNOME's own screenshot tool.\n", .{key});
    const yes = ask.resolve(move, std.fmt.allocPrint(arena, "Give {s} to Shotlet? ({s}; uninstall puts it back)", .{ key, where }) catch return);
    if (!yes) {
        out("Kept it: Shotlet's key {s} stays unbound (see `shotlet gnome-integration shortcut`).\n", .{key});
        return;
    }
    screenshot_keys.takeKeys(arena, env, taken) catch |err| {
        out("Could not change GNOME's shortcuts ({t}).\n", .{err});
        return;
    };
    out("{s} now captures with Shotlet; {s}.\n", .{ key, where });
    setNote("{s} captures with Shotlet; {s}", .{ key, where });
}

/// Where GNOME's screenshot tool ends up once its key is taken.
fn whereToolGoes(arena: std.mem.Allocator, taken: []const screenshot_keys.Taken, buf: []u8) ![]const u8 {
    const ui_new = for (taken) |t| {
        if (std.mem.eql(u8, t.key, "show-screenshot-ui")) break if (t.new.len > 0) displayAccel(buf, t.new[0]) else "";
    } else "";
    if (ui_new.len > 0) return std.fmt.allocPrint(arena, "GNOME's screenshot tool moves to {s}", .{ui_new});
    return "GNOME's screenshot tool stays in the system menu";
}
