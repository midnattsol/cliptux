//! `shotlet gnome-integration status|install|uninstall|shortcut`.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const gsettings = @import("gsettings.zig");
const Env = @import("../../../app/env.zig").Env;
const extension = @import("extension.zig");
const capture = @import("capture.zig");
const custom = @import("custom.zig");
const screenshot_keys = @import("screenshot_keys.zig");
const setup = @import("setup.zig");
const install_state = @import("install_state.zig");
const gnome_keys = @import("mode_keys.zig");

const ext_schema_id = extension.ext_schema_id;
const out = std.debug.print;

pub fn runCli(gpa: std.mem.Allocator, env: Env, sub: []const u8, rest: []const []const u8) !void {
    var bus = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer bus.deinit();
    if (std.mem.eql(u8, sub, "install")) {
        try runInstall(gpa, env, &bus, rest);
    } else if (std.mem.eql(u8, sub, "uninstall")) {
        try runUninstall(gpa, env, &bus);
    } else if (std.mem.eql(u8, sub, "shortcut")) {
        try runShortcut(gpa, env, &bus, rest);
    } else {
        runStatus(gpa, env, &bus);
    }
}

fn runInstall(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, rest: []const []const u8) !void {
    var move: setup.MoveShortcuts = .ask;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--move-shortcut")) move = .yes;
        if (std.mem.eql(u8, a, "--keep-shortcut")) move = .no;
    }
    switch (setup.install(gpa, env, bus, move)) {
        .active => out("GNOME integration is active: captures need no permission prompt.\n", .{}),
        .installed_relogin => out("Installed {s}. It loads at your next login (GNOME Shell only finds new\n" ++
            "extensions then). Shotlet finishes the setup with your answer the first time it\n" ++
            "runs through it; `shotlet gnome-integration install` after logging in does it at once.\n", .{extension.uuid}),
        .failed => {
            out("Could not install the GNOME integration (see the messages above).\n", .{});
            return error.InstallFailed;
        },
    }
}

/// Give back what install took, reset the extension's settings, disable
/// it and remove its files.
fn runUninstall(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) !void {
    @import("pending_setup.zig").clear(env.home);
    restoreTakenShortcuts(gpa, env);
    var sd_buf: [1100]u8 = undefined;
    if (extension.schemaDir(gpa, env, bus, &sd_buf)) |sd| {
        for ([_][]const u8{ "capture-shortcut", "shotlet-path" }) |k| gsettings.reset(gpa, env, sd, ext_schema_id, k) catch {};
    } else |_| {}
    _ = extension.callBool(gpa, bus, "DisableExtension", 5000) catch false;
    var buf: [1024]u8 = undefined;
    const dir = try extension.extensionDir(&buf, env.home);
    sys.removeTree(dir);
    out("Removed {s}.\n", .{dir});
}

/// GNOME's screenshot shortcuts and the moved custom shortcuts go back.
fn restoreTakenShortcuts(gpa: std.mem.Allocator, env: Env) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    if (screenshot_keys.restoreKeys(arena_state.allocator(), env)) |n| {
        if (n > 0) out("Gave {d} of GNOME's screenshot shortcut(s) back.\n", .{n});
    } else |err| out("Could not give GNOME's screenshot shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-keys\n", .{err});
    if (custom.restoreShortcuts(arena_state.allocator(), env)) |n| {
        if (n > 0) out("Put {d} custom shortcut(s) running shotlet back.\n", .{n});
    } else |err| out("Could not put the moved shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-shortcuts\n", .{err});
}

/// Show or set the capture shortcut, or a capture mode's own key.
fn runShortcut(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, rest: []const []const u8) !void {
    var sd_buf: [1100]u8 = undefined;
    const sd = try extension.schemaDir(gpa, env, bus, &sd_buf);
    // a capture mode's own key (gnome/mode_keys.zig)
    if (rest.len > 0 and @import("../../../app/modes/mode.zig").shortcutNamed(rest[0]) != null)
        return gnome_keys.cli(gpa, env, sd, rest);
    if (rest.len > 0) try setCaptureShortcut(gpa, env, sd, rest);
    const info = capture.captureInfo(gpa, bus);
    if (!info.capture) {
        const cur = gsettings.get(gpa, env, sd, ext_schema_id, "capture-shortcut") catch "";
        defer if (cur.len > 0) gpa.free(cur);
        out("capture-shortcut: {s}(the GNOME integration is not active)\n", .{cur});
    } else capture.printShortcut(&info);
    if (rest.len == 0) {
        out("Capture modes (shotlet gnome-integration shortcut MODE KEY):\n", .{});
        try gnome_keys.list(gpa, env, sd, null);
    }
}

/// Bind the extension's shortcut to `accels` (either notation; "none"
/// unbinds it), then give it a moment to pick that up.
fn setCaptureShortcut(gpa: std.mem.Allocator, env: Env, sd: []const u8, accels: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try gsettings.set(arena, env, sd, ext_schema_id, "capture-shortcut", try gnome_keys.userStrv(arena, accels));
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn runStatus(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) void {
    out("desktop: {s}\nextension {s}: {s}\n", .{
        if (extension.isGnome()) "GNOME" else "not GNOME",
        extension.uuid,
        install_state.read(gpa, env, bus).text(),
    });
    const info = capture.captureInfo(gpa, bus);
    out("capture: {s}\n", .{if (info.capture) "through the GNOME integration (no prompts)" else "through the screen-sharing portal"});
    capture.printShortcut(&info);
}
