//! shotlet-wldrive: virtual keyboard, pointer and screenshots for the
//! container e2e suite (tools/container/run.sh), on wlroots compositors
//! (sway, labwc) and on KWin. The counterpart of tools/e2e/drive.zig,
//! which does the same through Mutter's RemoteDesktop API on GNOME.
//!
//! - wlroots: zwlr_virtual_pointer_v1 + zwp_virtual_keyboard_v1 for input,
//!   zwlr_screencopy_v1 for pictures of an output.
//! - KWin: org_kde_kwin_fake_input for input (restricted: kwin_wayland must
//!   run with KWIN_WAYLAND_NO_PERMISSION_CHECKS=1), org.kde.KWin.ScreenShot2
//!   over D-Bus for pictures (KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1).
//!
//! Refuses to run unless SHOTLET_CONTAINER is set (the runner sets it), so
//! it can never type into a real desktop by accident. One command per line
//! on stdin, answered with one line on stdout: `ok [value]` or `err why`.
//! Monitors (MON) are numbered left to right, or named by connector.
//!
//!   key COMBO [down|up]   tap (or press/release) evdev keys: ctrl+c, a, #30
//!   type TEXT             tap the keys for lowercase letters, digits, space
//!   move MON X Y          absolute motion, logical pixels of monitor MON
//!   down|up|click [BTN]   left (default), right, middle
//!   wheel STEPS           vertical scroll (+ is down)
//!   monitors              "NAME:X,Y,WxH@SCALE ..." in the logical layout
//!   shot MON PATH         write the monitor's picture as a PNG; answers WxH
//!   find MON RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
//!                         "cx cy w h" of the first blob of that colour, in
//!                         the monitor's buffer pixels
//!   findpng PATH RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]   the same in a PNG file
//!   png PATH | pixel PATH X Y
//!   mkpng PATH W H RRGGBB a test picture: that colour framed in grey
//!   textpng PATH SIZE TEXT  black TEXT on white (Shotlet's text renderer)
//!   sleep MS | quit

const std = @import("std");
const kit = @import("shotlet");
const wl = kit.wayland;
const dbus = kit.dbus;
const sys = kit.sys;
const proto = @import("wldrive/proto.zig");
const commands = @import("wldrive/commands.zig");
const Driver = @import("wldrive/Driver.zig");

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const gpa = gpa_state.allocator();
    const vars = init.environ_map;
    if (vars.get("SHOTLET_CONTAINER") == null) {
        std.debug.print("shotlet-wldrive: run me inside tools/container/run.sh\n", .{});
        std.process.exit(2);
    }
    const runtime = vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    const display = vars.get("WAYLAND_DISPLAY") orelse "wayland-0";

    var d: Driver = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime, display) };
    defer d.conn.deinit();
    d.registry = try d.conn.getRegistry();
    try d.roundtrip();
    try bindOutputs(&d);
    try setupInput(&d, vars);
    try d.roundtrip();
    reply("ok ready", .{});
    try serve(&d);
}

/// Outputs: logical position, size and connector name, left to right.
fn bindOutputs(d: *Driver) !void {
    for (d.outputs.items) |*o| {
        o.id = try d.conn.bind(d.registry, o.global, "wl_output", 4);
        if (d.g.xdg_output_mgr != 0) {
            o.xdg = d.conn.newId();
            try d.conn.request(d.g.xdg_output_mgr, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
        }
    }
    try d.roundtrip();
    try d.roundtrip();
    d.sortOutputs();
}

/// KWin's fake input (and the session bus for its screenshots), else
/// wlroots' virtual pointer and keyboard.
fn setupInput(d: *Driver, vars: *const std.process.Environ.Map) !void {
    if (d.g.fake != 0) {
        d.kwin = true;
        try d.conn.request(d.g.fake, proto.fake.authenticate, &.{ .{ .string = "shotlet-wldrive" }, .{ .string = "e2e tests" } });
        if (d.g.fake_version < 4) return fail("org_kde_kwin_fake_input v{d}: no keyboard", .{d.g.fake_version});
        d.bus = try dbus.Connection.connectSession(d.gpa, vars.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoBus);
    } else if (d.g.vp_mgr != 0 and d.g.vk_mgr != 0 and d.g.seat != 0) {
        d.pointer = d.conn.newId();
        try d.conn.request(d.g.vp_mgr, proto.vp_mgr.create_virtual_pointer, &.{ .{ .object = d.g.seat }, .{ .new_id = d.pointer } });
        d.keyboard = d.conn.newId();
        try d.conn.request(d.g.vk_mgr, proto.vk_mgr.create_virtual_keyboard, &.{ .{ .object = d.g.seat }, .{ .new_id = d.keyboard } });
        const path = vars.get("WLDRIVE_KEYMAP") orelse return fail("WLDRIVE_KEYMAP: an xkb keymap file is needed", .{});
        try d.uploadKeymap(path);
    } else {
        return fail("no virtual input: neither wlroots' virtual pointer/keyboard nor KWin's fake input", .{});
    }
}

/// Answer one command per line on stdin until `quit` or its end.
fn serve(d: *Driver) !void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const quit = answer(d, std.mem.trim(u8, buf[0..nl], " \t\r"));
            std.mem.copyForwards(u8, buf[0..], buf[nl + 1 .. len]);
            len -= nl + 1;
            if (quit) return;
            continue;
        }
        if (len == buf.len) return error.LineTooLong;
        const n = try sys.read(0, buf[len..]);
        if (n == 0) return;
        len += n;
    }
}

/// Run one line (blank and # lines are ignored) and reply to it; whether
/// it was `quit`.
fn answer(d: *Driver, line: []const u8) bool {
    if (line.len > 0 and line[0] != '#') {
        if (commands.run(d, line)) |val| {
            if (val.len > 0) reply("ok {s}", .{val}) else reply("ok", .{});
        } else |err| reply("err {t}", .{err});
    }
    return std.mem.eql(u8, line, "quit");
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    reply("err " ++ fmt, args);
    return error.Setup;
}

fn reply(comptime fmt: []const u8, args: anytype) void {
    var out: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&out, fmt ++ "\n", args) catch "err reply too long\n";
    sys.writeAll(1, s) catch {};
}
