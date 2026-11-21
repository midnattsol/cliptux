const std = @import("std");
const shot = @import("app/shot.zig");
const daemon = @import("app/daemon.zig");
const devtools = @import("app/devtools.zig");
const shellcap = @import("app/shellcap.zig");
const env_mod = @import("app/env.zig");
const Env = env_mod.Env;
const launch = @import("ui/tools/launch.zig");

const usage =
    \\Shotlet - Wayland-native screenshot tool with annotation editor
    \\
    \\usage:
    \\  shotlet             capture + editor (copy/save)
    \\  shotlet fullscreen|screens|previous|window|scroll [--delay S]
    \\                      capture modes: the screen under the pointer,
    \\                      all screens, the last area, a window, a
    \\                      scrolling capture; --delay: the self-timer
    \\  shotlet timer [3|5|10]   area capture after a countdown
    \\  shotlet --daemon    run the system tray daemon (detaches; -f stays)
    \\  shotlet text        capture text: select a region, its text (OCR)
    \\                      goes to the clipboard
    \\  shotlet edit FILE   open a PNG, JPEG or WebP in the editor
    \\  shotlet history     recent captures (history clear: forget them)
    \\  shotlet record      record an area or the screen (MP4 or GIF);
    \\                      again (or --stop, --pause, --resume) stops it
    \\  shotlet pin [FILE]  pin an image (default: the clipboard's) to the screen
    \\  shotlet gnome-integration [status|install|uninstall]
    \\                      the GNOME Shell extension: prompt-free captures,
    \\                      floating windows
    \\  shotlet gnome-integration shortcut [KEY...|none]
    \\                      its capture shortcut (default Print)
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

    const env = try readEnv(arena, init);
    launch.env = env;
    setXdgDirs(init.environ_map);
    try dispatch(gpa, env, args);
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

/// Runs the command `args` name; unknown ones print the usage.
fn dispatch(gpa: std.mem.Allocator, env: Env, args: []const [:0]const u8) !void {
    // `shotlet --from-shell ID ...` is how the GNOME Shell extension
    // starts a capture: `shotlet shot --from-shell ID ...`
    const shell_launch = args.len > 1 and std.mem.eql(u8, args[1], "--from-shell");
    const cmd = if (shell_launch) "shot" else if (args.len > 1) args[1] else "shot";
    if (shell_launch) {
        launch.takeHandOff(env.runtime_dir);
        // the extension runs: an install that waited for it can finish
        @import("app/gnome.zig").finishPendingSetup(env);
    }
    // `shotlet text` is a capture whose region's text is copied
    if (std.mem.eql(u8, cmd, "text")) launch.text_capture = true;
    const eql = std.mem.eql;

    if (eql(u8, cmd, "shot") or eql(u8, cmd, "text")) {
        try runShot(gpa, env, args[@min(args.len, @as(usize, if (shell_launch) 1 else 2))..]);
    } else if (eql(u8, cmd, "--daemon") or eql(u8, cmd, "daemon")) {
        const foreground = args.len > 2 and
            (eql(u8, args[2], "--foreground") or eql(u8, args[2], "-f"));
        try daemon.run(gpa, env, foreground);
    } else if (eql(u8, cmd, "settings")) {
        try @import("ui/settings.zig").run(gpa, env, smokeArg(args));
    } else if (eql(u8, cmd, "quick") and args.len > 3) {
        try @import("app/quick.zig").run(gpa, env, args[2], args[3]);
    } else if (eql(u8, cmd, "history")) {
        try runHistory(gpa, env, args);
    } else if (eql(u8, cmd, "quick-video") and args.len > 3) {
        try @import("record/quickvid.zig").run(gpa, env, args[2], args[3]);
    } else if (eql(u8, cmd, "trim") and args.len > 3) {
        try @import("ui/recui/trimui.zig").run(gpa, env, args[2], args[3], args[4..]);
    } else if (eql(u8, cmd, "record")) {
        try @import("record/cli.zig").main(gpa, env, args[2..]);
    } else if (eql(u8, cmd, "pin")) {
        if (args.len > 2) try @import("app/pin.zig").run(gpa, env, args[2]) else try @import("app/clipimg.zig").pinClipboard(gpa, env);
    } else if (eql(u8, cmd, "gnome-integration")) {
        try @import("app/gnome.zig").runCli(gpa, env, if (args.len > 2) args[2] else "status", if (args.len > 3) args[3..] else &.{});
    } else if (eql(u8, cmd, "edit") and args.len > 3) {
        try shot.runEdit(gpa, env, args[2], args[3]);
    } else if (eql(u8, cmd, "toast") and args.len > 2) {
        try @import("app/toastwin.zig").run(gpa, env, args[2], if (args.len > 3) args[3] else "");
    } else if (eql(u8, cmd, "edit") and args.len == 3) {
        try @import("app/editfile.zig").run(gpa, env, args[2]);
    } else if (try @import("app/modes/cli.zig").run(gpa, env, cmd, args[2..])) {
        // a capture mode
    } else if (try devtools.run(gpa, env, cmd, args)) {
        // handled
    } else {
        std.debug.print("{s}", .{usage});
    }
}

/// `CMD --smoke MS`: auto-close after MS (leak runs); 0 when absent.
fn smokeArg(args: []const [:0]const u8) i64 {
    return if (args.len > 3 and std.mem.eql(u8, args[2], "--smoke"))
        std.fmt.parseInt(i64, args[3], 10) catch 0
    else
        0;
}

/// `shotlet history [clear | --smoke MS]`.
fn runHistory(gpa: std.mem.Allocator, env: Env, args: []const [:0]const u8) !void {
    if (args.len > 2 and std.mem.eql(u8, args[2], "clear")) {
        var buf: [1024]u8 = undefined;
        @import("app/history.zig").clear(try @import("app/history.zig").historyRoot(&buf, env.home));
        std.debug.print("history cleared\n", .{});
        return;
    }
    try @import("app/history_ui.zig").run(gpa, env, smokeArg(args));
}

/// Options of `shotlet shot`, from its flag/value pairs.
const ShotArgs = struct {
    from: ?[]const u8 = null,
    from_monitors: ?[]const u8 = null,
    from_shell: ?shellcap.Args = null,
    shell_monitors: []const u8 = "",
    shell_pieces: []const u8 = "",
    t0: ?i64 = null,
    sel: ?[4]i32 = null,
    smoke_ms: i64 = 0,
    then_record: bool = false,
    req: @import("app/modes/mode.zig").Request = .{},
};

/// `shotlet shot|text [FLAG VALUE]...`. Dev/testing flags: --from FILE
/// (skip portal), --sel X,Y,W,H (preset selection), --smoke MS
/// (auto-cancel, for leak runs), --from-monitors A.png,B.png (one image
/// per monitor, side by side).
fn runShot(gpa: std.mem.Allocator, env: Env, flags: []const [:0]const u8) !void {
    var o: ShotArgs = .{};
    var i: usize = 0;
    while (i + 1 < flags.len) : (i += 2) try parseShotFlag(&o, flags[i], flags[i + 1]);
    if (o.from_shell) |*fs| {
        fs.monitors = o.shell_monitors;
        fs.pieces = o.shell_pieces;
        fs.t0_ms = o.t0;
    }
    if (o.then_record and o.from_shell != null) return @import("record/cli.zig").fromShell(gpa, env, o.from_shell.?);
    try shot.run(gpa, env, .{ .file = o.from, .monitors = o.from_monitors, .shell = o.from_shell, .req = o.req }, o.sel, o.smoke_ms);
}

fn parseShotFlag(o: *ShotArgs, flag: []const u8, value: [:0]const u8) !void {
    const eql = std.mem.eql;
    if (eql(u8, flag, "--from")) {
        o.from = value;
    } else if (eql(u8, flag, "--from-monitors")) {
        o.from_monitors = value;
    } else if (eql(u8, flag, "--from-shell")) {
        // the GNOME Shell extension's capture (src/app/shellcap.zig)
        o.from_shell = .{ .id = value };
    } else if (eql(u8, flag, "--monitors")) {
        o.shell_monitors = value;
    } else if (eql(u8, flag, "--pieces")) {
        o.shell_pieces = value;
    } else if (eql(u8, flag, "--then")) {
        // the extension's record shortcut: the picker on this capture
        if (eql(u8, value, "record")) o.then_record = true;
    } else if (eql(u8, flag, "--mode")) {
        o.req.withModeArg(value);
    } else if (eql(u8, flag, "--pointer")) {
        o.req.withPointerArg(value);
    } else if (eql(u8, flag, "--t0")) {
        o.t0 = std.fmt.parseInt(i64, value, 10) catch null;
    } else if (eql(u8, flag, "--smoke")) {
        o.smoke_ms = std.fmt.parseInt(i64, value, 10) catch 0;
    } else if (eql(u8, flag, "--sel")) {
        o.sel = try parseSel(value);
    }
}

/// "X,Y,W,H" for --sel.
fn parseSel(value: []const u8) ![4]i32 {
    var it = std.mem.splitScalar(u8, value, ',');
    var vals: [4]i32 = undefined;
    for (&vals) |*v| {
        v.* = std.fmt.parseInt(i32, it.next() orelse return error.BadSelArg, 10) catch return error.BadSelArg;
    }
    return vals;
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
    _ = @import("app/gsettings.zig");
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
    _ = @import("ui/settings_modes.zig");
    _ = @import("ui/settings_steps.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/motion.zig");
    _ = @import("ui/icons.zig");
    _ = @import("gfx/path.zig");
    _ = @import("record/tests.zig");
}
