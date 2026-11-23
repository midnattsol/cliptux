//! Whether a scrolling capture can run here, asked before the person
//! picks a region (app/scroll/available.zig says why not). Its frames
//! come from the GNOME extension's scroll session, or from direct
//! capture of the outputs (wlroots, KWin): scroll_source.zig. On GNOME
//! without the extension running there is no direct capture, so what
//! the extension's install state says is what to tell the person.

const std = @import("std");
const dbus = @import("../dbus.zig");
const gnome = @import("../gnome.zig");
const direct = @import("direct.zig");
const Env = @import("../../../app/env.zig").Env;
const ScrollSupport = @import("../../api/capture.zig").ScrollSupport;

/// What the answer is decided from.
pub const Facts = struct {
    /// the compositor offers direct capture of the outputs
    direct: bool,
    /// the extension's state on GNOME; null elsewhere
    shell: ?gnome.InstallState,
};

pub fn decide(f: Facts) ScrollSupport {
    if (f.direct) return .available;
    const st = f.shell orelse return .unsupported;
    return switch (st) {
        .active => .available,
        .next_login => .shell_needs_login,
        .not_installed, .disabled => .shell_missing,
        .no_shell, .user_extensions_off, .failed, .out_of_date => .shell_off,
    };
}

/// The answer now. With the extension running, only its bus name is
/// asked; the install state (GNOME Shell, gsettings) only when it is not.
pub fn support(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) ScrollSupport {
    const on_gnome = gnome.isGnome();
    if (on_gnome and gnome.extensionActive(bus)) return .available;
    const why = decide(.{
        .direct = directNow(gpa, env, bus),
        .shell = if (on_gnome) gnome.installState(gpa, env, bus) else null,
    });
    std.log.info("scrolling capture: {t}", .{why});
    return why;
}

/// Direct capture is offered (SHOTLET_NO_DIRECT turns it off, as for
/// screen captures).
fn directNow(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) bool {
    if (std.c.getenv("SHOTLET_NO_DIRECT") != null) return false;
    return direct.probe(gpa, env.runtime_dir, env.session.display, bus) != null;
}

test "direct capture or the running extension: available" {
    try std.testing.expectEqual(ScrollSupport.available, decide(.{ .direct = true, .shell = null }));
    try std.testing.expectEqual(ScrollSupport.available, decide(.{ .direct = true, .shell = .not_installed }));
    try std.testing.expectEqual(ScrollSupport.available, decide(.{ .direct = false, .shell = .active }));
}

test "GNOME without the extension running: what it needs" {
    try std.testing.expectEqual(ScrollSupport.shell_needs_login, decide(.{ .direct = false, .shell = .next_login }));
    try std.testing.expectEqual(ScrollSupport.shell_missing, decide(.{ .direct = false, .shell = .not_installed }));
    try std.testing.expectEqual(ScrollSupport.shell_missing, decide(.{ .direct = false, .shell = .disabled }));
    for ([_]gnome.InstallState{ .no_shell, .user_extensions_off, .failed, .out_of_date }) |s|
        try std.testing.expectEqual(ScrollSupport.shell_off, decide(.{ .direct = false, .shell = s }));
}

test "neither: unsupported" {
    try std.testing.expectEqual(ScrollSupport.unsupported, decide(.{ .direct = false, .shell = null }));
}
