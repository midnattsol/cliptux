//! Where the session's services are, from the environment: the D-Bus
//! session bus (DBUS_SESSION_BUS_ADDRESS, else the per-user bus systemd
//! and dbus-broker put in the runtime dir) and the Wayland display.

const std = @import("std");

pub const Addresses = struct { bus: []const u8, display: []const u8 };

/// `vars`: the environment (`get(name) ?[]const u8`); empty values count
/// as unset.
pub fn addresses(arena: std.mem.Allocator, vars: anytype, runtime_dir: []const u8) !Addresses {
    return .{
        .bus = nonEmpty(vars.get("DBUS_SESSION_BUS_ADDRESS")) orelse try defaultBusAddress(arena, runtime_dir),
        .display = nonEmpty(vars.get("WAYLAND_DISPLAY")) orelse "wayland-0",
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
    var out: [2]@import("../dbus.zig").Address = undefined;
    const parsed = try @import("../dbus.zig").parseAddresses(b, &buf, &out);
    try std.testing.expectEqualStrings("/tmp/a b;c/bus", parsed[0].path);
}
