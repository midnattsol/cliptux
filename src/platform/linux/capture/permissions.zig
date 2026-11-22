//! `shotlet permissions [reset [--dry-run]]`: what Shotlet may capture
//! with and what it remembered, and forgetting it. Status shows the path
//! a capture takes now and the last one took, whether a ScreenCast
//! restore token is stored (never the token), Shotlet's entries in the
//! portal permission store and, on GNOME, an extension that only loads at
//! the next login. Reset is perms/reset.zig.

const std = @import("std");
const dbus = @import("../dbus.zig");
const Env = @import("../../../app/env.zig").Env;
const config = @import("../../../app/config.zig");
const gnome = @import("../gnome.zig");
const capture_path = @import("path.zig");
const now_mod = @import("perms/now.zig");
const store = @import("perms/store.zig");
const reset = @import("perms/reset.zig");
const app_id = @import("../../../app_id.zig").app_id;

const out = std.debug.print;

pub fn run(gpa: std.mem.Allocator, env: Env, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bus_state: ?dbus.Connection = dbus.Connection.connectSession(gpa, env.session.bus) catch null;
    defer if (bus_state) |*b| b.deinit();
    const bus: ?*dbus.Connection = if (bus_state) |*b| b else null;
    if (args.len > 0 and std.mem.eql(u8, args[0], "reset")) {
        const dry = args.len > 1 and std.mem.eql(u8, args[1], "--dry-run");
        return printReset(reset.run(arena, env, bus, dry), dry);
    }
    status(gpa, arena, env, bus);
}

fn status(gpa: std.mem.Allocator, arena: std.mem.Allocator, env: Env, bus: ?*dbus.Connection) void {
    var buf: [128]u8 = undefined;
    if (bus) |b| out("capture now:   {s}\n", .{now_mod.current(gpa, env, b).text(&buf)});
    out("last capture:  {s}\n", .{if (capture_path.last(env.home)) |p| p.text() else "none yet"});
    const token = config.load(arena, env.home).scToken() != null;
    out("restore token: {s}\n", .{if (token) "stored (the next portal capture reuses the screens chosen)" else "none"});
    if (bus) |b| storeStatus(arena, b) else out("permission store: no session bus\n", .{});
    if (bus) |b| gnomeHint(gpa, env, b);
}

fn storeStatus(arena: std.mem.Allocator, bus: *dbus.Connection) void {
    const entries = store.find(arena, bus) catch |err| {
        out("permission store: not reachable ({t})\n", .{err});
        return;
    };
    printCount("screen cast:  ", store.count(entries, .screencast), "permission");
    printCount("screenshot:   ", store.count(entries, .screenshot), "permission");
}

fn printCount(label: []const u8, c: store.Count, noun: []const u8) void {
    if (c.current == 0 and c.older == 0) return out("{s} none\n", .{label});
    out("{s} {d} {s}{s} for {s}", .{ label, c.current, noun, if (c.current == 1) "" else "s", app_id });
    if (c.older > 0) out(", {d} from older versions (shotlet, cliptux)", .{c.older});
    out("\n", .{});
}

/// The extension that would make the portal unnecessary is installed
/// but not running yet.
fn gnomeHint(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) void {
    if (!gnome.isGnome()) return;
    switch (gnome.installState(gpa, env, bus)) {
        .next_login => out("hint: the GNOME integration is installed but not loaded yet: log out and back in\n", .{}),
        .user_extensions_off => |s| out("hint: the GNOME integration is {s}\n", .{s.text()}),
        else => {},
    }
}

fn printReset(o: reset.Outcome, dry: bool) void {
    const verb = if (dry) "Would remove" else "Removed";
    if (o.token) out("{s} the stored restore token.\n", .{verb});
    for (o.entries) |e| {
        if (e.pick.whole) {
            const app = e.pick.apps[0];
            out("{s} a {s} permission of {s}{s}.\n", .{ verb, tableName(e.table), app, if (e.older()) " (an older version)" else "" });
        } else for (e.pick.apps) |a| out("{s} {s} from the {s} permission.\n", .{ verb, a, tableName(e.table) });
    }
    if (o.store_error) |err| out("Could not read the portal permission store ({t}).\n", .{err});
    if (o.failed > 0) out("Could not remove {d} of them (see the messages above).\n", .{o.failed});
    if (o.nothing() and o.store_error == null) out("Nothing to remove.\n", .{});
    if (dry) {
        out("(dry run: nothing changed)\n", .{});
    } else if (!o.nothing()) out("The next capture through the portal asks again.\n", .{});
}

fn tableName(t: store.Table) []const u8 {
    return switch (t) {
        .screencast => "screen-cast",
        .screenshot => "screenshot",
    };
}

test {
    _ = @import("perms/select.zig");
    _ = store;
    _ = reset;
}
