const std = @import("std");
const front = @import("cli/front.zig");
const env_mod = @import("app/env.zig");
const Env = env_mod.Env;
const launch = @import("ui/tools/launch.zig");

const is_debug = @import("builtin").mode == .debug;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // help, the version and mistyped command lines need no session
    const parsed = switch (try front.handle(arena, args, nonEmpty(init.environ_map.get("NO_COLOR")) != null)) {
        .run => |p| p,
        .exit => |code| std.process.exit(code),
    };

    // DebugAllocator catches leaks in Debug; smp_allocator is the fast
    // thread-safe choice for release builds
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (is_debug) gpa_state.allocator() else std.heap.smp_allocator;

    const env = try readEnv(arena, init);
    launch.env = env;
    setXdgDirs(init.environ_map);
    try @import("app/dispatch.zig").run(gpa, env, parsed);
}

/// The process environment Shotlet needs, from the variables.
fn readEnv(arena: std.mem.Allocator, init: std.process.Init) !Env {
    const vars = init.environ_map;
    const runtime_dir = env_mod.absolute(vars.get("XDG_RUNTIME_DIR")) orelse return error.NoRuntimeDir;
    return .{
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
}

fn setXdgDirs(vars: anytype) void {
    env_mod.xdg = .{
        .config_home = env_mod.absolute(vars.get("XDG_CONFIG_HOME")),
        .state_home = env_mod.absolute(vars.get("XDG_STATE_HOME")),
        .pictures_dir = env_mod.absolute(vars.get("XDG_PICTURES_DIR")),
        .cache_home = env_mod.absolute(vars.get("XDG_CACHE_HOME")),
    };
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
    _ = @import("cli/tests.zig");
    _ = @import("app/dispatch.zig");
    _ = @import("platform/dbus.zig");
    _ = @import("platform/permstore.zig");
    _ = @import("platform/portal.zig");
    _ = @import("platform/pw.zig");
    _ = @import("platform/portal_test.zig");
    _ = @import("app/config.zig");
    _ = @import("app/history.zig");
    _ = @import("app/annot.zig");
    _ = @import("app/keep.zig");
    _ = @import("app/quick.zig");
    _ = @import("app/gnome.zig");
    _ = @import("app/accel.zig");
    _ = @import("app/shellcap.zig");
    _ = @import("app/scroll/stitch.zig");
    _ = @import("app/modes/mode.zig");
    _ = @import("app/modes/settings.zig");
    _ = @import("app/modes/geom.zig");
    _ = @import("app/modes/last_area.zig");
    _ = @import("app/modes/window_frame.zig");
    _ = @import("app/modes/cli.zig");
    _ = @import("app/scroll/capture.zig");
    _ = @import("app/scroll/session.zig");
    _ = @import("app/scroll/stop.zig");
    _ = @import("app/gsettings.zig");
    _ = @import("app/permissions.zig");
    _ = @import("app/pin.zig");
    _ = @import("app/clipimg.zig");
    _ = @import("app/binds.zig");
    _ = @import("app/quick_ipc.zig");
    _ = @import("app/editor_prefs.zig");
    _ = @import("ui/beautify.zig");
    _ = @import("ui/drag.zig");
    _ = @import("ui/help.zig");
    _ = @import("ui/rect_list.zig");
    _ = @import("ui/caret.zig");
    _ = @import("ui/scroll_steps.zig");
    _ = @import("ui/scroll_hud.zig");
    _ = @import("ui/transfer.zig");
    _ = @import("app/editfile.zig");
    _ = @import("app/toastwin.zig");
    _ = @import("app/history_ui.zig");
    _ = @import("platform/ocr.zig");
    _ = @import("ocr/page.zig");
    _ = @import("ocr/reflow.zig");
    _ = @import("redact/detect.zig");
    _ = @import("redact/locate.zig");
    _ = @import("ui/floatui.zig");
    _ = @import("gfx/text.zig");
    _ = @import("ui/editor.zig");
    _ = @import("ui/textbox.zig");
    _ = @import("ui/shapes.zig");
    _ = @import("ui/tools/mod.zig");
    _ = @import("ui/editor_ui.zig");
    _ = @import("ui/doc.zig");
    _ = @import("ui/view.zig");
    _ = @import("ui/tall_view.zig");
    _ = @import("ui/script_input.zig");
    _ = @import("ui/hsv.zig");
    _ = @import("ui/textedit.zig");
    _ = @import("gfx/png.zig");
    _ = @import("gfx/jpeg.zig");
    _ = @import("gfx/imgload.zig");
    _ = @import("gfx/codec_libs.zig");
    _ = @import("gfx/effects.zig");
    _ = @import("gfx/resample.zig");
    _ = @import("app/capture.zig");
    _ = @import("app/direct.zig");
    _ = @import("app/direct_kwin.zig");
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
    _ = @import("ui/frame.zig");
    _ = @import("ui/barkit.zig");
    _ = @import("ui/settings_modes.zig");
    _ = @import("ui/settings_steps.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/motion.zig");
    _ = @import("ui/icons.zig");
    _ = @import("gfx/path.zig");
    _ = @import("gfx/hint.zig");
    _ = @import("record/tests.zig");
}
