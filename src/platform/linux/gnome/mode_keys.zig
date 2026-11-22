//! The GNOME extension's shortcut per capture mode (its settings keys,
//! mode.shortcuts):
//!
//!     shotlet gnome-integration shortcut MODE [KEY... | none]
//!     shotlet gnome-integration shortcut          (lists them too)

const std = @import("std");
const env_mod = @import("../../../app/env.zig");
const gnome = @import("../gnome.zig");
const gsettings = @import("gsettings.zig");
const mode = @import("../../../app/modes/mode.zig");
const Env = env_mod.Env;

const gnome_shot_keys = [_][]const u8{ "show-screenshot-ui", "screenshot", "screenshot-window", "show-screen-recording-ui" };

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// `MODE KEY...`: set that mode's key; `MODE`: show it.
pub fn cli(gpa: std.mem.Allocator, env: Env, schemadir: []const u8, rest: []const []const u8) !void {
    const sc = mode.shortcutNamed(rest[0]).?;
    const keys = rest[1..];
    if (keys.len > 0) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for (keys) |a| if (a.len == 0 or a.len > 60 or std.mem.indexOfAny(u8, a, "'\"\\\n") != null) return error.BadShortcut;
        const none = keys.len == 1 and std.mem.eql(u8, keys[0], "none");
        try gsettings.set(arena, env, schemadir, gnome.ext_schema_id, sc.key, try gsettings.formatStrv(arena, if (none) &.{} else keys));
    }
    try list(gpa, env, schemadir, sc.name);
}

/// The key one of GNOME's screenshot shortcuts (or the area capture)
/// holds that equals `accel`, if any.
fn takenBy(arena: std.mem.Allocator, env: Env, schemadir: []const u8, sc: mode.Shortcut, accel: []const u8) ?[]const u8 {
    for (gnome_shot_keys) |k| {
        const v = gsettings.get(arena, env, null, "org.gnome.shell.keybindings", k) catch continue;
        const items = gsettings.parseStrv(arena, v) catch continue;
        for (items) |it| if (gnome.sameAccel(it, accel)) return "GNOME's screenshot shortcut";
    }
    if (!std.mem.eql(u8, sc.name, "area")) {
        const v = gsettings.get(arena, env, schemadir, gnome.ext_schema_id, "capture-shortcut") catch return null;
        const items = gsettings.parseStrv(arena, v) catch return null;
        for (items) |it| if (gnome.sameAccel(it, accel)) return "the area capture's key";
    }
    return null;
}

/// Every mode's key (or only `only`), and whether it is left unbound.
pub fn list(gpa: std.mem.Allocator, env: Env, schemadir: []const u8, only: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (mode.shortcuts) |sc| {
        if (only) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        const v = gsettings.get(arena, env, schemadir, gnome.ext_schema_id, sc.key) catch {
            out("  {s}: (unknown: an older extension)\n", .{sc.name});
            continue;
        };
        const items = gsettings.parseStrv(arena, v) catch &.{};
        if (items.len == 0) {
            out("  {s}: none\n", .{sc.name});
            continue;
        }
        const why = takenBy(arena, env, schemadir, sc, items[0]);
        if (why) |w| out("  {s}: {s} (unbound: it is {s})\n", .{ sc.name, items[0], w }) else out("  {s}: {s}\n", .{ sc.name, items[0] });
    }
}
