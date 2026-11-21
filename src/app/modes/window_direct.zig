//! Window capture without the GNOME extension.
//!
//! - KWin: org.kde.KWin.ScreenShot2.CaptureInteractive (KWin's own window
//!   picker), authorized like the other screenshots by Shotlet's
//!   installed desktop entry; the window comes back at its native
//!   resolution without its shadow.
//! - elsewhere nothing tells a client where windows are; the caller falls
//!   back to selecting an area.

const std = @import("std");
const dbus = @import("../../platform/dbus.zig");
const direct = @import("../direct.zig");
const env_mod = @import("../env.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/sys.zig");
const shot = @import("../shot.zig");
const mode = @import("mode.zig");

/// True when handled (captured, or the person cancelled KWin's picker).
pub fn run(gpa: std.mem.Allocator, env: env_mod.Env, req: mode.Request) !bool {
    var bus = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer bus.deinit();
    const f = (try kwinPick(gpa, &bus)) orelse return false;
    std.log.info("window capture: KWin gave {d}x{d}", .{ f.width, f.height });
    var r = req;
    r.mode = .window;
    try shot.run(gpa, env, .{ .image = .{ .width = f.width, .height = f.height, .pixels = f.pixels }, .req = r }, null, 0);
    return true;
}

/// KWin's window picker; null when KWin is not here or refuses Shotlet.
fn kwinPick(gpa: std.mem.Allocator, bus: *dbus.Connection) !?direct.Frame {
    const p = try sys.pipe();
    defer sys.close(p[0]);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putU32(0); // a window
    const arr = try m.beginArray(8);
    for ([_]struct { []const u8, bool }{ .{ "include-decoration", true }, .{ "include-shadow", false }, .{ "include-cursor", false }, .{ "native-resolution", true } }) |o| {
        try m.beginStruct();
        try m.putString(o[0]);
        try m.putVariantBool(o[1]);
    }
    m.endArray(arr);
    try m.putU32(0); // fd index
    const serial = bus.callMethodFds("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureInteractive", "ua{sv}h", m.buf.items, &.{p[1]}) catch |err| {
        sys.close(p[1]);
        if (err == error.NoFdPassing) return null;
        return err;
    };
    sys.close(p[1]);
    // the person is picking: give them time
    return @import("../direct_kwin.zig").reply(gpa, bus, serial, p[0], true, 120_000) catch |err| switch (err) {
        error.UnknownImageFormat, error.ShortImage => return err,
        else => null,
    };
}
