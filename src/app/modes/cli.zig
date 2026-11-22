//! `shotlet MODE` (see mode.zig): the self-timer and the window mode
//! where the GNOME extension does not handle them, then the usual
//! capture flow (app/shot.zig) with the mode.

const std = @import("std");
const env_mod = @import("../env.zig");
const gnome = @import("../../platform/linux/gnome.zig");
const shot = @import("../shot.zig");
const mode = @import("mode.zig");
const settings = @import("settings.zig");
const window_direct = @import("../../platform/linux/capture/window_direct.zig");
const dbus = @import("../../platform/linux/dbus.zig");

/// The GNOME extension is here to pick windows.
fn gnomeExtension(gpa: std.mem.Allocator, env: env_mod.Env) bool {
    if (!gnome.isGnome()) return false;
    var bus = dbus.Connection.connectSession(gpa, env.bus_addr) catch return false;
    defer bus.deinit();
    return gnome.extensionActive(&bus);
}

/// False when `cmd` is no capture mode.
pub fn run(gpa: std.mem.Allocator, env: env_mod.Env, cmd: []const u8, rest: []const []const u8) !bool {
    const s = settings.load(gpa, env.home);
    var req = mode.parseCommand(cmd, rest, s.timer_s) orelse return false;
    if (req.mode == .window and !gnomeExtension(gpa, env)) {
        if (!gnome.isGnome() and try window_direct.run(gpa, env, req)) return true;
        std.log.info("window capture: not offered here; selecting an area instead", .{});
        req.mode = .area;
    }
    try shot.run(gpa, env, .{ .req = req }, null, 0);
    return true;
}
