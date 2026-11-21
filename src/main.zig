const std = @import("std");
const shot = @import("app/shot.zig");
const daemon = @import("app/daemon.zig");
const devtools = @import("app/devtools.zig");
const env_mod = @import("app/env.zig");
const Env = env_mod.Env;

const usage =
    \\Shotlet - Wayland-native screenshot tool with annotation editor
    \\
    \\usage:
    \\  shotlet             capture + editor (copy/save)
    \\  shotlet --daemon    run the system tray daemon (detaches; -f stays)
    \\  shotlet --help      show this help
    \\
;

const is_debug = @import("builtin").mode == .debug;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // DebugAllocator catches leaks in Debug; smp_allocator is the fast
    // thread-safe choice for release builds
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (is_debug) gpa_state.allocator() else std.heap.smp_allocator;

    const vars = init.environ_map;
    const runtime_dir = env_mod.absolute(vars.get("XDG_RUNTIME_DIR")) orelse return error.NoRuntimeDir;
    const env: Env = .{
        // without an explicit address, use the per-user bus systemd and
        // dbus-broker put in the runtime dir
        .bus_addr = nonEmpty(vars.get("DBUS_SESSION_BUS_ADDRESS")) orelse
            try defaultBusAddress(arena, runtime_dir),
        .runtime_dir = runtime_dir,
        .wayland_display = nonEmpty(vars.get("WAYLAND_DISPLAY")) orelse "wayland-0",
        .home = env_mod.absolute(vars.get("HOME")) orelse return error.NoHome,
        .envp = init.minimal.environ.block.slice.ptr,
        .tz = vars.get("TZ"),
    };
    env_mod.xdg = .{
        .config_home = env_mod.absolute(vars.get("XDG_CONFIG_HOME")),
        .state_home = env_mod.absolute(vars.get("XDG_STATE_HOME")),
        .pictures_dir = env_mod.absolute(vars.get("XDG_PICTURES_DIR")),
    };

    const cmd = if (args.len > 1) args[1] else "shot";

    if (std.mem.eql(u8, cmd, "shot")) {
        // dev/testing flags: --from FILE (skip portal), --sel X,Y,W,H
        // (preset selection), --smoke MS (auto-cancel, for leak runs)
        var from: ?[]const u8 = null;
        var sel: ?[4]i32 = null;
        var smoke_ms: i64 = 0;
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 2) {
            if (std.mem.eql(u8, args[i], "--from")) {
                from = args[i + 1];
            } else if (std.mem.eql(u8, args[i], "--smoke")) {
                smoke_ms = std.fmt.parseInt(i64, args[i + 1], 10) catch 0;
            } else if (std.mem.eql(u8, args[i], "--sel")) {
                var it = std.mem.splitScalar(u8, args[i + 1], ',');
                var vals: [4]i32 = undefined;
                for (&vals) |*v| {
                    v.* = std.fmt.parseInt(i32, it.next() orelse return error.BadSelArg, 10) catch return error.BadSelArg;
                }
                sel = vals;
            }
        }
        try shot.run(gpa, env, from, sel, smoke_ms);
    } else if (std.mem.eql(u8, cmd, "--daemon") or std.mem.eql(u8, cmd, "daemon")) {
        const foreground = args.len > 2 and
            (std.mem.eql(u8, args[2], "--foreground") or std.mem.eql(u8, args[2], "-f"));
        try daemon.run(gpa, env, foreground);
    } else if (std.mem.eql(u8, cmd, "settings")) {
        const smoke: i64 = if (args.len > 3 and std.mem.eql(u8, args[2], "--smoke"))
            std.fmt.parseInt(i64, args[3], 10) catch 0
        else
            0;
        try @import("ui/settings.zig").run(gpa, env.runtime_dir, env.wayland_display, env.home, smoke);
    } else if (try devtools.run(gpa, env, cmd, args)) {
        // handled
    } else {
        std.debug.print("{s}", .{usage});
    }
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

/// "unix:path=<runtime_dir>/bus", percent-escaping bytes outside the set the
/// DBus spec allows unescaped in address values.
fn defaultBusAddress(arena: std.mem.Allocator, runtime_dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "unix:path=");
    for (runtime_dir) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_/.\\*", c) != null;
        if (plain) {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    try out.appendSlice(arena, "/bus");
    return out.items;
}

test "default bus address escapes the runtime dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try defaultBusAddress(arena.allocator(), "/run/user/1000");
    try std.testing.expectEqualStrings("unix:path=/run/user/1000/bus", a);
    const b = try defaultBusAddress(arena.allocator(), "/tmp/a b;c");
    try std.testing.expectEqualStrings("unix:path=/tmp/a%20b%3Bc/bus", b);
    var buf: [128]u8 = undefined;
    var out: [2]@import("platform/dbus.zig").Address = undefined;
    const parsed = try @import("platform/dbus.zig").parseAddresses(b, &buf, &out);
    try std.testing.expectEqualStrings("/tmp/a b;c/bus", parsed[0].path);
}

test {
    _ = @import("platform/dbus.zig");
    _ = @import("platform/portal.zig");
    _ = @import("platform/pw.zig");
    _ = @import("platform/portal_test.zig");
    _ = @import("app/config.zig");
    _ = @import("gfx/text.zig");
    _ = @import("ui/editor.zig");
    _ = @import("ui/shapes.zig");
    _ = @import("ui/editor_ui.zig");
    _ = @import("gfx/png.zig");
    _ = @import("gfx/effects.zig");
    _ = @import("app/capture.zig");
    _ = @import("app/env.zig");
    _ = @import("app/clock.zig");
    _ = @import("app/shot.zig");
    _ = @import("app/tray.zig");
    _ = @import("app/daemon.zig");
    _ = @import("gfx/font.zig");
    _ = @import("gfx/render.zig");
    _ = @import("platform/wayland.zig");
    _ = @import("ui/keyboard.zig");
    _ = @import("ui/window.zig");
    _ = @import("ui/settings.zig");
}
