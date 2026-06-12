const std = @import("std");
const shot = @import("app/shot.zig");
const daemon = @import("app/daemon.zig");
const devtools = @import("app/devtools.zig");
const Env = @import("app/env.zig").Env;

const usage =
    \\cliptux - Wayland-native screenshot tool with annotation editor
    \\
    \\usage:
    \\  cliptux             capture + editor (copy/save)
    \\  cliptux --daemon    run the system tray daemon (detaches; -f stays)
    \\  cliptux --help      show this help
    \\
;

const is_debug = @import("builtin").mode == .Debug;

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

    const env: Env = .{
        .bus_addr = init.environ_map.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus,
        .runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir,
        .wayland_display = init.environ_map.get("WAYLAND_DISPLAY") orelse "wayland-0",
        .home = init.environ_map.get("HOME") orelse "/tmp",
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

test {
    _ = @import("platform/dbus.zig");
    _ = @import("platform/portal.zig");
    _ = @import("app/config.zig");
    _ = @import("gfx/text.zig");
    _ = @import("ui/editor.zig");
    _ = @import("ui/shapes.zig");
    _ = @import("ui/editor_ui.zig");
    _ = @import("gfx/png.zig");
    _ = @import("gfx/font.zig");
    _ = @import("gfx/render.zig");
    _ = @import("platform/wayland.zig");
}
