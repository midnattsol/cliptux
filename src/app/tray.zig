//! System tray icon via StatusNotifierItem (org.kde.StatusNotifierItem) and
//! com.canonical.dbusmenu, exported over our native DBus connection.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const render = @import("../gfx/render.zig");

const sni_path = "/StatusNotifierItem";
const menu_path = "/MenuBar";
const sni_iface = "org.kde.StatusNotifierItem";
const menu_iface = "com.canonical.dbusmenu";
const props_iface = "org.freedesktop.DBus.Properties";

pub const MenuAction = enum { capture, settings, quit, none };

pub const Tray = struct {
    alloc: std.mem.Allocator,
    conn: *dbus.Connection,
    icons: []const IconPixmap,

    pub const IconPixmap = struct {
        width: i32,
        height: i32,
        /// ARGB32, big-endian per the SNI spec
        argb: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator, conn: *dbus.Connection, icons: []const IconPixmap) !Tray {
        var self = Tray{ .alloc = alloc, .conn = conn, .icons = icons };
        // re-register if the watcher (gnome-shell / waybar) restarts
        try conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'");
        try self.register();
        return self;
    }

    fn register(self: *Tray) !void {
        var m = dbus.Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(sni_path);
        const serial = self.conn.callMethod(
            "org.kde.StatusNotifierWatcher",
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            "s",
            m.buf.items,
        ) catch return error.NoTrayHost;
        var reply = self.conn.waitReply(serial) catch {
            std.log.warn("no system tray host found (on GNOME, enable the AppIndicator extension)", .{});
            return;
        };
        reply.deinit(self.alloc);
    }

    /// Handle one incoming message if it belongs to the tray objects.
    /// Returns an action when the user asked for one.
    pub fn handleMessage(self: *Tray, msg: *const dbus.Message) !MenuAction {
        const alloc = self.alloc;
        const conn = self.conn;

        if (msg.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) {
            var r = msg.reader();
            const name = r.readString() catch return .none;
            if (std.mem.eql(u8, name, "org.kde.StatusNotifierWatcher")) {
                _ = r.readString() catch return .none; // old owner
                const new_owner = r.readString() catch return .none;
                if (new_owner.len > 0) self.register() catch {};
            }
            return .none;
        }

        if (msg.type != .method_call) return .none;
        if (msg.isCall("org.freedesktop.DBus.Peer", "Ping")) {
            try conn.replyTo(msg, "", &.{});
            return .none;
        }
        const path = msg.path orelse return .none;

        if (std.mem.eql(u8, path, sni_path)) {
            if (msg.isCall(sni_iface, "Activate") or msg.isCall(sni_iface, "SecondaryActivate")) {
                try conn.replyTo(msg, "", &.{});
                return .capture;
            }
            if (msg.isCall(sni_iface, "ContextMenu") or msg.isCall(sni_iface, "Scroll")) {
                try conn.replyTo(msg, "", &.{});
                return .none;
            }
            if (msg.isCall(props_iface, "Get")) {
                var r = msg.reader();
                _ = try r.readString(); // interface
                const prop = try r.readString();
                var m = dbus.Marshal.init(alloc);
                defer m.deinit();
                try self.putProperty(&m, prop);
                try conn.replyTo(msg, "v", m.buf.items);
                return .none;
            }
            if (msg.isCall(props_iface, "GetAll")) {
                var m = dbus.Marshal.init(alloc);
                defer m.deinit();
                const arr = try m.beginArray(8);
                const props = [_][]const u8{ "Category", "Id", "Title", "Status", "IconName", "IconPixmap", "Menu", "ItemIsMenu" };
                for (props) |p| {
                    try m.beginStruct();
                    try m.putString(p);
                    try self.putProperty(&m, p);
                }
                m.endArray(arr);
                try conn.replyTo(msg, "a{sv}", m.buf.items);
                return .none;
            }
            if (msg.isCall("org.freedesktop.DBus.Introspectable", "Introspect")) {
                var m = dbus.Marshal.init(alloc);
                defer m.deinit();
                try m.putString(sni_introspect_xml);
                try conn.replyTo(msg, "s", m.buf.items);
                return .none;
            }
            try conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
            return .none;
        }

        if (std.mem.eql(u8, path, menu_path)) {
            return self.handleMenuMessage(msg);
        }
        return .none;
    }

    fn putProperty(self: *Tray, m: *dbus.Marshal, prop: []const u8) !void {
        const eql = std.mem.eql;
        if (eql(u8, prop, "Category")) {
            try m.putVariantString("ApplicationStatus");
        } else if (eql(u8, prop, "Id")) {
            try m.putVariantString("cliptux");
        } else if (eql(u8, prop, "Title")) {
            try m.putVariantString("cliptux");
        } else if (eql(u8, prop, "Status")) {
            try m.putVariantString("Active");
        } else if (eql(u8, prop, "IconName")) {
            try m.putVariantString(""); // force hosts to use IconPixmap
        } else if (eql(u8, prop, "IconPixmap")) {
            try m.putSignature("a(iiay)");
            const arr = try m.beginArray(8);
            for (self.icons) |icon| {
                try m.beginStruct();
                try m.putI32(icon.width);
                try m.putI32(icon.height);
                const bytes = try m.beginArray(1);
                try m.buf.appendSlice(m.alloc, icon.argb);
                m.endArray(bytes);
            }
            m.endArray(arr);
        } else if (eql(u8, prop, "Menu")) {
            try m.putSignature("o");
            try m.putObjectPath(menu_path);
        } else if (eql(u8, prop, "ItemIsMenu")) {
            try m.putVariantBool(false);
        } else {
            try m.putVariantString("");
        }
    }

    const menu_items = [_]struct { id: i32, label: []const u8, separator: bool }{
        .{ .id = 1, .label = "Take screenshot", .separator = false },
        .{ .id = 2, .label = "Settings", .separator = false },
        .{ .id = 3, .label = "", .separator = true },
        .{ .id = 4, .label = "Quit", .separator = false },
    };

    fn handleMenuMessage(self: *Tray, msg: *const dbus.Message) !MenuAction {
        const alloc = self.alloc;
        const conn = self.conn;

        if (msg.isCall(menu_iface, "GetLayout")) {
            // reply: (u(ia{sv}av))
            var m = dbus.Marshal.init(alloc);
            defer m.deinit();
            try m.putU32(1); // revision
            try m.beginStruct();
            try m.putI32(0); // root id
            const root_props = try m.beginArray(8);
            try m.beginStruct();
            try m.putString("children-display");
            try m.putVariantString("submenu");
            m.endArray(root_props);
            const children = try m.beginArray(1); // av: variants align 1
            for (menu_items) |item| {
                try m.putSignature("(ia{sv}av)");
                try m.beginStruct();
                try m.putI32(item.id);
                const props = try m.beginArray(8);
                if (item.separator) {
                    try m.beginStruct();
                    try m.putString("type");
                    try m.putVariantString("separator");
                } else {
                    try m.beginStruct();
                    try m.putString("label");
                    try m.putVariantString(item.label);
                }
                m.endArray(props);
                const sub = try m.beginArray(1);
                m.endArray(sub); // no nested children
            }
            m.endArray(children);
            try conn.replyTo(msg, "u(ia{sv}av)", m.buf.items);
            return .none;
        }
        if (msg.isCall(menu_iface, "GetGroupProperties")) {
            // reply: a(ia{sv})
            var m = dbus.Marshal.init(alloc);
            defer m.deinit();
            const arr = try m.beginArray(8);
            for (menu_items) |item| {
                try m.beginStruct();
                try m.putI32(item.id);
                const props = try m.beginArray(8);
                if (item.separator) {
                    try m.beginStruct();
                    try m.putString("type");
                    try m.putVariantString("separator");
                } else {
                    try m.beginStruct();
                    try m.putString("label");
                    try m.putVariantString(item.label);
                }
                m.endArray(props);
            }
            m.endArray(arr);
            try conn.replyTo(msg, "a(ia{sv})", m.buf.items);
            return .none;
        }
        if (msg.isCall(menu_iface, "AboutToShow")) {
            var m = dbus.Marshal.init(alloc);
            defer m.deinit();
            try m.putBool(false);
            try conn.replyTo(msg, "b", m.buf.items);
            return .none;
        }
        if (msg.isCall(menu_iface, "Event")) {
            var r = msg.reader();
            const id = @as(i32, @bitCast(try r.readU32()));
            const event_type = try r.readString();
            try conn.replyTo(msg, "", &.{});
            if (std.mem.eql(u8, event_type, "clicked")) {
                return switch (id) {
                    1 => .capture,
                    2 => .settings,
                    4 => .quit,
                    else => .none,
                };
            }
            return .none;
        }
        if (msg.isCall(props_iface, "Get") or msg.isCall(props_iface, "GetAll")) {
            // dbusmenu properties: Version (u) and Status (s)
            var m = dbus.Marshal.init(alloc);
            defer m.deinit();
            if (msg.isCall(props_iface, "GetAll")) {
                const arr = try m.beginArray(8);
                try m.beginStruct();
                try m.putString("Version");
                try m.putVariantU32(3);
                try m.beginStruct();
                try m.putString("Status");
                try m.putVariantString("normal");
                m.endArray(arr);
                try conn.replyTo(msg, "a{sv}", m.buf.items);
            } else {
                var r = msg.reader();
                _ = try r.readString();
                const prop = try r.readString();
                if (std.mem.eql(u8, prop, "Version")) try m.putVariantU32(3) else try m.putVariantString("normal");
                try conn.replyTo(msg, "v", m.buf.items);
            }
            return .none;
        }
        try conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        return .none;
    }
};

const sni_introspect_xml =
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\ </interface>
    \\</node>
;

/// Draw the cliptux tray icon: scissors snipping a dashed capture corner.
/// Returns ARGB bytes in big-endian order (SNI spec) at the given size.
pub fn drawIcon(alloc: std.mem.Allocator, size: i32) ![]u8 {
    const n: usize = @intCast(size);
    const px = try alloc.alloc(u32, n * n);
    defer alloc.free(px);
    @memset(px, 0);
    var c = render.Canvas.init(px, @intCast(size), @intCast(size));

    const s: f64 = @floatFromInt(size);
    const fg: u32 = 0xFFE9ECEF; // panel-friendly light gray
    const accent: u32 = 0xFF4DABF7;
    const lw = @max(1.6, s * 0.085); // blade width
    const P = struct { x: i32, y: i32 };

    // scissors: two blades crossing at a pivot, ring handles at the bottom
    const pivot_x = s * 0.50;
    const pivot_y = s * 0.58;
    const tip_l_x = s * 0.26;
    const tip_y = s * 0.06;
    const tip_r_x = s * 0.74;
    const handle_l_x = s * 0.26;
    const handle_y = s * 0.80;
    const handle_r_x = s * 0.74;
    const handle_r = s * 0.13;

    // blades (tip to pivot, extended a bit past the pivot toward handles)
    const blade_l = [_]P{
        .{ .x = @intFromFloat(tip_l_x), .y = @intFromFloat(tip_y) },
        .{ .x = @intFromFloat(pivot_x + (handle_r_x - pivot_x) * 0.45), .y = @intFromFloat(pivot_y + (handle_y - pivot_y) * 0.45) },
    };
    const blade_r = [_]P{
        .{ .x = @intFromFloat(tip_r_x), .y = @intFromFloat(tip_y) },
        .{ .x = @intFromFloat(pivot_x + (handle_l_x - pivot_x) * 0.45), .y = @intFromFloat(pivot_y + (handle_y - pivot_y) * 0.45) },
    };
    c.strokePolylineAA(blade_l[0..], lw, fg);
    c.strokePolylineAA(blade_r[0..], lw, fg);
    // handles in accent blue
    c.ringAA(handle_l_x, handle_y + handle_r * 0.4, handle_r, lw, accent);
    c.ringAA(handle_r_x, handle_y + handle_r * 0.4, handle_r, lw, accent);
    // pivot
    c.fillCircleAA(pivot_x, pivot_y, lw * 0.7, fg);

    // convert 0xAARRGGBB to network-order ARGB bytes
    const out = try alloc.alloc(u8, n * n * 4);
    for (px, 0..) |p, i| {
        out[i * 4] = @truncate(p >> 24);
        out[i * 4 + 1] = @truncate(p >> 16);
        out[i * 4 + 2] = @truncate(p >> 8);
        out[i * 4 + 3] = @truncate(p);
    }
    return out;
}
