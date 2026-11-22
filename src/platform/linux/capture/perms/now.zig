//! The capture path a capture would take now, found the way app/shot.zig
//! picks it but without capturing: the GNOME integration when its
//! extension runs, the compositor's own interface (capture/direct.zig), else
//! the screen-sharing portal.

const std = @import("std");
const dbus = @import("../../dbus.zig");
const Env = @import("../../../../app/env.zig").Env;
const gnome = @import("../../gnome.zig");
const direct = @import("../direct.zig");

pub const Now = union(enum) {
    gnome,
    direct: direct.Method,
    portal,

    pub fn text(n: Now, buf: []u8) []const u8 {
        return switch (n) {
            .gnome => "through the GNOME integration (no permission needed)",
            .direct => |m| if (m == .kwin_screenshot)
                "directly with KWin ScreenShot2 (no permission needed while KWin accepts this binary)"
            else
                std.fmt.bufPrint(buf, "directly with {s} (no permission needed)", .{m.label()}) catch "directly",
            .portal => "through the screen-sharing portal (asks once; the choice is remembered)",
        };
    }
};

pub fn current(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) Now {
    if (gnome.isGnome() and gnome.extensionActive(bus)) return .gnome;
    if (std.c.getenv("SHOTLET_NO_DIRECT") == null) {
        if (direct.probe(gpa, env.runtime_dir, env.wayland_display, bus)) |m| return .{ .direct = m };
    }
    return .portal;
}
