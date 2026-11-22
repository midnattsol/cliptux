//! The appearance the desktop asks for, from the Settings portal
//! (org.freedesktop.portal.Settings): color-scheme, accent-color and
//! GNOME's enable-animations, read once and followed through
//! SettingChanged. Never fails: missing values keep the defaults.
//!
//! Colour-scheme values: 1 prefer dark, 2 prefer light, 0 no preference.
//! No preference is light, as GNOME and every other app on the desktop
//! read it.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const Prefs = @import("../../api/desktop.zig").Appearance;

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_iface = "org.freedesktop.portal.Settings";

const Key = enum { color_scheme, accent, animations };
const keys = [_]struct { ns: []const u8, key: []const u8 }{
    .{ .ns = "org.freedesktop.appearance", .key = "color-scheme" },
    .{ .ns = "org.freedesktop.appearance", .key = "accent-color" },
    .{ .ns = "org.gnome.desktop.interface", .key = "enable-animations" },
};

/// Read the appearance settings from the Settings portal, waiting at most
/// `timeout_ms` for all of them. Values the portal does not know (or no
/// portal at all) keep their defaults.
pub fn read(conn: *dbus.Connection, timeout_ms: i64) Prefs {
    var prefs: Prefs = .{};
    var serials: [keys.len]?u32 = @splat(null);
    for (keys, 0..) |k, i| {
        var m = dbus.Marshal.init(conn.alloc);
        defer m.deinit();
        m.putString(k.ns) catch return prefs;
        m.putString(k.key) catch return prefs;
        serials[i] = conn.callMethod(portal_dest, portal_path, settings_iface, "ReadOne", "ss", m.buf.items) catch return prefs;
    }
    const deadline = sys.monoMs() + timeout_ms;
    var left: usize = keys.len;
    while (left > 0) {
        var msg = (conn.readMessageDeadline(deadline) catch return prefs) orelse return prefs;
        const which = for (serials, 0..) |s, i| {
            if (s != null and msg.reply_serial != null and msg.reply_serial.? == s.?) break i;
        } else null;
        const i = which orelse {
            // not ours: leave it for whoever waits for it
            conn.pending.append(conn.alloc, msg) catch msg.deinit(conn.alloc);
            continue;
        };
        defer msg.deinit(conn.alloc);
        serials[i] = null;
        left -= 1;
        if (msg.type != .method_return) continue;
        var r = msg.reader();
        applyValue(&prefs, @fromBackingInt(@intCast(i)), &r) catch {};
    }
    return prefs;
}

/// Subscribe to the portal's SettingChanged signal.
pub fn watch(conn: *dbus.Connection) !void {
    try conn.addMatchOnce("type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'");
}

/// Fold a SettingChanged signal into `prefs`. True when it changed a value
/// the theme uses.
pub fn applySignal(prefs: *Prefs, msg: *const dbus.Message) bool {
    if (!msg.isSignal(settings_iface, "SettingChanged")) return false;
    var r = msg.reader();
    const ns = r.readString() catch return false;
    const key = r.readString() catch return false;
    for (keys, 0..) |k, i| {
        if (!std.mem.eql(u8, k.ns, ns) or !std.mem.eql(u8, k.key, key)) continue;
        const before = prefs.*;
        applyValue(prefs, @fromBackingInt(@intCast(i)), &r) catch return false;
        return !std.meta.eql(before, prefs.*);
    }
    return false;
}

/// Read one setting's variant (unwrapping the nesting older portals add).
fn applyValue(prefs: *Prefs, which: Key, r: *dbus.Reader) !void {
    var sig = try r.readSignature();
    var depth: usize = 0;
    while (std.mem.eql(u8, sig, "v") and depth < 4) : (depth += 1) sig = try r.readSignature();
    switch (which) {
        .color_scheme => {
            if (!std.mem.eql(u8, sig, "u")) return error.BadType;
            prefs.dark = (try r.readU32()) == 1;
        },
        .accent => {
            if (!std.mem.eql(u8, sig, "(ddd)")) return error.BadType;
            r.pad(8);
            var c: [3]f64 = undefined;
            for (&c) |*v| v.* = @bitCast(try r.readU64());
            // out of range means "no accent set"
            for (c) |v| if (!(v >= 0 and v <= 1)) {
                prefs.accent = null;
                return;
            };
            var rgb: u32 = 0xFF000000;
            for (c, 0..) |v, i| rgb |= @as(u32, @intFromFloat(@round(v * 255))) << @intCast(16 - 8 * i);
            prefs.accent = rgb;
        },
        .animations => {
            if (!std.mem.eql(u8, sig, "b")) return error.BadType;
            prefs.animations = (try r.readU32()) != 0;
        },
    }
}

test "portal values fold into prefs" {
    const alloc = std.testing.allocator;
    // color-scheme as ReadOne returns it: v(u)
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putSignature("u");
    try m.putU32(2);
    var r: dbus.Reader = .{ .data = m.buf.items, .pos = 0 };
    var p: Prefs = .{};
    try applyValue(&p, .color_scheme, &r);
    try std.testing.expect(!p.dark);

    // accent-color, double-wrapped like Read: v(v((ddd)))
    var m2 = dbus.Marshal.init(alloc);
    defer m2.deinit();
    try m2.putSignature("v");
    try m2.putSignature("(ddd)");
    try m2.pad(8);
    for ([_]f64{ 1.0, 0.5, 0.0 }) |v| try m2.putU64(@bitCast(v));
    r = .{ .data = m2.buf.items, .pos = 0 };
    try applyValue(&p, .accent, &r);
    try std.testing.expectEqual(@as(u32, 0xFFFF8000), p.accent.?);
}
