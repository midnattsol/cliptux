//! System tray icon via StatusNotifierItem (org.kde.StatusNotifierItem) and
//! com.canonical.dbusmenu, exported over our native DBus connection. The
//! menu object lives in tray/menu.zig.

const std = @import("std");
const dbus = @import("../platform/linux/dbus.zig");
const render = @import("../gfx/render.zig");

const sni_path = "/StatusNotifierItem";
const sni_iface = "org.kde.StatusNotifierItem";
const menu = @import("tray/menu.zig");
const menu_path = menu.path;
const menu_iface = menu.iface;
const props_iface = "org.freedesktop.DBus.Properties";

pub const MenuAction = enum {
    capture,
    record,
    history,
    settings,
    quit,
    none,
    // the other capture modes (app/modes/)
    capture_screen,
    capture_window,
    capture_scroll,
    capture_timer,
    capture_text,

    /// The shotlet command of a capture mode's item.
    pub fn modeCommand(self: MenuAction) ?[*:0]const u8 {
        return switch (self) {
            .capture_screen => "fullscreen",
            .capture_window => "window",
            .capture_scroll => "scroll",
            .capture_timer => "timer",
            .capture_text => "text",
            else => null,
        };
    }
};

pub const Tray = struct {
    alloc: std.mem.Allocator,
    conn: *dbus.Connection,
    icons: []const IconPixmap,
    /// a StatusNotifierWatcher accepted the item
    registered: bool = false,

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
        self.registered = false;
        // no watcher (GNOME without the AppIndicator extension): wait for
        // one to appear instead of failing a call
        if (!(self.conn.nameHasOwner("org.kde.StatusNotifierWatcher") catch true)) {
            std.log.warn("no system tray host found (on GNOME, enable the AppIndicator extension); waiting for one", .{});
            return;
        }
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
        self.registered = true;
        std.log.info("tray icon registered", .{});
    }

    /// Handle one incoming message if it belongs to the tray objects.
    /// Returns an action when the user asked for one.
    pub fn handleMessage(self: *Tray, msg: *const dbus.Message) !MenuAction {
        if (msg.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) {
            self.onNameOwnerChanged(msg);
            return .none;
        }
        if (msg.type != .method_call) return .none;
        if (msg.isCall("org.freedesktop.DBus.Peer", "Ping")) {
            try self.conn.replyTo(msg, "", &.{});
            return .none;
        }
        const path = msg.path orelse return .none;
        if (std.mem.eql(u8, path, sni_path)) return self.handleItemMessage(msg);
        if (std.mem.eql(u8, path, menu_path)) return menu.handle(self.alloc, self.conn, msg);
        // callers block until they get an answer: never leave one hanging
        try self.conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
        return .none;
    }

    /// A new StatusNotifierWatcher (the host restarted): register again.
    fn onNameOwnerChanged(self: *Tray, msg: *const dbus.Message) void {
        var r = msg.reader();
        const name = r.readString() catch return;
        if (!std.mem.eql(u8, name, "org.kde.StatusNotifierWatcher")) return;
        _ = r.readString() catch return; // old owner
        const new_owner = r.readString() catch return;
        if (new_owner.len > 0) self.register() catch {};
    }

    /// A call on the StatusNotifierItem object.
    fn handleItemMessage(self: *Tray, msg: *const dbus.Message) !MenuAction {
        const conn = self.conn;
        if (msg.isCall(sni_iface, "Activate") or msg.isCall(sni_iface, "SecondaryActivate")) {
            try conn.replyTo(msg, "", &.{});
            return .capture;
        }
        if (msg.isCall(sni_iface, "ContextMenu") or msg.isCall(sni_iface, "Scroll")) {
            try conn.replyTo(msg, "", &.{});
        } else if (msg.isCall(props_iface, "Get")) {
            try self.getProperty(msg);
        } else if (msg.isCall(props_iface, "GetAll")) {
            try self.getAllProperties(msg);
        } else if (msg.isCall("org.freedesktop.DBus.Introspectable", "Introspect")) {
            var m = dbus.Marshal.init(self.alloc);
            defer m.deinit();
            try m.putString(sni_introspect_xml);
            try conn.replyTo(msg, "s", m.buf.items);
        } else {
            try conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        }
        return .none;
    }

    fn getProperty(self: *Tray, msg: *const dbus.Message) !void {
        var r = msg.reader();
        _ = try r.readString(); // interface
        const prop = try r.readString();
        var m = dbus.Marshal.init(self.alloc);
        defer m.deinit();
        self.putProperty(&m, prop) catch |err| switch (err) {
            error.UnknownProperty => {
                try self.conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownProperty", "no such property");
                return;
            },
            else => return err,
        };
        try self.conn.replyTo(msg, "v", m.buf.items);
    }

    fn getAllProperties(self: *Tray, msg: *const dbus.Message) !void {
        var m = dbus.Marshal.init(self.alloc);
        defer m.deinit();
        const arr = try m.beginArray(8);
        for (sni_props) |p| {
            try m.beginStruct();
            try m.putString(p);
            try self.putProperty(&m, p);
        }
        m.endArray(arr);
        try self.conn.replyTo(msg, "a{sv}", m.buf.items);
    }

    const sni_props = [_][]const u8{
        "Category",          "Id",                "Title",               "Status",
        "WindowId",          "IconName",          "IconPixmap",          "OverlayIconName",
        "OverlayIconPixmap", "AttentionIconName", "AttentionIconPixmap", "AttentionMovieName",
        "ToolTip",           "IconThemePath",     "Menu",                "ItemIsMenu",
    };

    fn putProperty(self: *Tray, m: *dbus.Marshal, prop: []const u8) !void {
        const eql = std.mem.eql;
        if (eql(u8, prop, "Category")) {
            try m.putVariantString("ApplicationStatus");
        } else if (eql(u8, prop, "Id")) {
            try m.putVariantString(@import("../app_id.zig").app_id);
        } else if (eql(u8, prop, "Title")) {
            try m.putVariantString("Shotlet");
        } else if (eql(u8, prop, "Status")) {
            try m.putVariantString("Active");
        } else if (eql(u8, prop, "WindowId")) {
            try m.putVariantI32(0);
        } else if (eql(u8, prop, "IconName")) {
            try m.putVariantString(""); // force hosts to use IconPixmap
        } else if (eql(u8, prop, "OverlayIconName") or eql(u8, prop, "AttentionIconName") or
            eql(u8, prop, "AttentionMovieName") or eql(u8, prop, "IconThemePath"))
        {
            try m.putVariantString("");
        } else if (eql(u8, prop, "OverlayIconPixmap") or eql(u8, prop, "AttentionIconPixmap")) {
            try m.putSignature("a(iiay)");
            const arr = try m.beginArray(8);
            m.endArray(arr);
        } else if (eql(u8, prop, "ToolTip")) {
            // (icon name, icon pixmaps, title, description)
            try m.putSignature("(sa(iiay)ss)");
            try m.beginStruct();
            try m.putString("");
            const arr = try m.beginArray(8);
            m.endArray(arr);
            try m.putString("Shotlet");
            try m.putString("Take a screenshot");
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
            return error.UnknownProperty;
        }
    }

    const menu_items = menu.items;
};

const sni_introspect_xml =
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="OverlayIconName" type="s" access="read"/>
    \\  <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionIconName" type="s" access="read"/>
    \\  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="AttentionMovieName" type="s" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="IconThemePath" type="s" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\ </interface>
    \\</node>
;

/// Draw the shotlet tray icon: scissors snipping a dashed capture corner.
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

    return networkArgb(alloc, px);
}

/// 0xAARRGGBB pixels as network-order ARGB bytes.
fn networkArgb(alloc: std.mem.Allocator, px: []const u32) ![]u8 {
    const out = try alloc.alloc(u8, px.len * 4);
    for (px, 0..) |p, i| {
        out[i * 4] = @truncate(p >> 24);
        out[i * 4 + 1] = @truncate(p >> 16);
        out[i * 4 + 2] = @truncate(p >> 8);
        out[i * 4 + 3] = @truncate(p);
    }
    return out;
}

fn testCall(path: []const u8, iface: []const u8, member: []const u8, body: []const u8) dbus.Message {
    return .{ .type = .method_call, .serial = 77, .path = path, .interface = iface, .member = member, .sender = ":1.9", .body = body };
}

test "tray answers with the declared types, and errors for unknown objects" {
    const alloc = std.testing.allocator;
    const fds = try @import("../platform/linux/sys.zig").socketPair();
    var host = dbus.Connection{ .fd = fds[0], .alloc = alloc };
    defer host.deinit();
    var ours = dbus.Connection{ .fd = fds[1], .alloc = alloc };
    defer ours.deinit();
    var tray = Tray{ .alloc = alloc, .conn = &ours, .icons = &.{} };

    const Want = struct { prop: []const u8, sig: []const u8 };
    for ([_]Want{
        .{ .prop = "ToolTip", .sig = "(sa(iiay)ss)" },
        .{ .prop = "WindowId", .sig = "i" },
        .{ .prop = "IconPixmap", .sig = "a(iiay)" },
        .{ .prop = "Menu", .sig = "o" },
    }) |w| {
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putString(sni_iface);
        try m.putString(w.prop);
        var call = testCall(sni_path, props_iface, "Get", m.buf.items);
        _ = try tray.handleMessage(&call);
        var reply = try host.readMessage();
        defer reply.deinit(alloc);
        try std.testing.expectEqual(dbus.MessageType.method_return, reply.type);
        var r = reply.reader();
        try std.testing.expectEqualStrings(w.sig, try r.readSignature());
        try r.skipValue(w.sig);
        try std.testing.expectEqual(reply.body.len, r.pos);
    }

    // GetAll is a valid a{sv} the reader can walk to the end
    {
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putString(sni_iface);
        var call = testCall(sni_path, props_iface, "GetAll", m.buf.items);
        _ = try tray.handleMessage(&call);
        var reply = try host.readMessage();
        defer reply.deinit(alloc);
        var r = reply.reader();
        var it = try r.readDictSV();
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try std.testing.expectEqual(Tray.sni_props.len, n);
    }

    // unknown property and unknown object path both get an error reply
    {
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putString(sni_iface);
        try m.putString("Nope");
        var call = testCall(sni_path, props_iface, "Get", m.buf.items);
        _ = try tray.handleMessage(&call);
        var reply = try host.readMessage();
        defer reply.deinit(alloc);
        try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownProperty", reply.error_name.?);
    }
    {
        var call = testCall("/not/here", "org.example", "Do", &.{});
        _ = try tray.handleMessage(&call);
        var reply = try host.readMessage();
        defer reply.deinit(alloc);
        try std.testing.expectEqual(dbus.MessageType.@"error", reply.type);
        try std.testing.expectEqual(@as(?u32, 77), reply.reply_serial);
        try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownObject", reply.error_name.?);
    }
}

test "menu items map to their actions, Recent captures included" {
    const alloc = std.testing.allocator;
    const fds = try @import("../platform/linux/sys.zig").socketPair();
    var host = dbus.Connection{ .fd = fds[0], .alloc = alloc };
    defer host.deinit();
    var ours = dbus.Connection{ .fd = fds[1], .alloc = alloc };
    defer ours.deinit();
    var tray = Tray{ .alloc = alloc, .conn = &ours, .icons = &.{} };
    for ([_]struct { id: i32, want: MenuAction }{
        .{ .id = 1, .want = .capture },
        .{ .id = 10, .want = .capture_text },
        .{ .id = 5, .want = .history },
        .{ .id = 2, .want = .settings },
        .{ .id = 4, .want = .quit },
        .{ .id = 7, .want = .capture_window },
        .{ .id = 9, .want = .capture_timer },
        .{ .id = 99, .want = .none },
    }) |c| {
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putI32(c.id);
        try m.putString("clicked");
        try m.putSignature("i");
        try m.putI32(0);
        try m.putU32(0);
        var call = testCall(menu_path, menu_iface, "Event", m.buf.items);
        try std.testing.expectEqual(c.want, try tray.handleMessage(&call));
        var reply = try host.readMessage();
        reply.deinit(alloc);
    }
    var found = false;
    for (Tray.menu_items) |item| found = found or std.mem.eql(u8, item.label, "Recent captures…");
    try std.testing.expect(found);
}
