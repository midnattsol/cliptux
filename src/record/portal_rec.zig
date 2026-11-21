//! Recording through the ScreenCast portal (KWin, wlroots, GNOME without
//! the extension): a session kept open for the whole recording, the
//! cursor drawn into the pictures, the same restore token as screenshots
//! so the consent is asked once.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const sys = @import("../platform/sys.zig");

const iface = "org.freedesktop.portal.ScreenCast";

pub const Session = struct {
    path: []u8,
    start: portal.ScStart,
    fd: sys.fd_t,

    pub fn close(self: *Session, gpa: std.mem.Allocator, conn: *dbus.Connection) void {
        portal.closeSession(gpa, conn, self.path);
        gpa.free(self.path);
        self.start.deinit(gpa);
    }
};

fn token(buf: []u8) ![]u8 {
    var rnd: [8]u8 = undefined;
    sys.getRandom(&rnd);
    return std.fmt.bufPrint(buf, "shotlet_rec{x}", .{std.mem.readInt(u64, &rnd, .little)});
}

fn notGranted(o: portal.Outcome) portal.Result(Session) {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}

/// Open a session: every monitor (as for screenshots, so one restore
/// token serves both), the cursor embedded when it can be.
pub fn open(gpa: std.mem.Allocator, conn: *dbus.Connection, prev_token: ?[]const u8) !portal.Result(Session) {
    const path = switch (try portal.scCreateSession(gpa, conn)) {
        .granted => |p| p,
        else => |o| return notGranted(o),
    };
    var ok = false;
    defer if (!ok) {
        portal.closeSession(gpa, conn, path);
        gpa.free(path);
    };
    const sel = try select(gpa, conn, path, prev_token);
    if (sel != .granted) return notGranted(sel);
    var st = switch (try startCast(gpa, conn, path)) {
        .granted => |s| s,
        else => |o| return notGranted(o),
    };
    errdefer st.deinit(gpa);
    const fd = try portal.scOpenRemote(gpa, conn, path);
    ok = true;
    return .{ .granted = .{ .path = path, .start = st, .fd = fd } };
}

fn select(gpa: std.mem.Allocator, conn: *dbus.Connection, path: []const u8, prev_token: ?[]const u8) !portal.Outcome {
    var tok_buf: [64]u8 = undefined;
    const tok = try token(&tok_buf);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putObjectPath(path);
    const arr = try m.beginArray(8);
    try entry(&m, "handle_token");
    try m.putVariantString(tok);
    try entry(&m, "types");
    try m.putVariantU32(1); // MONITOR
    try entry(&m, "multiple");
    try m.putVariantBool(true);
    try entry(&m, "cursor_mode");
    try m.putVariantU32(cursorMode(gpa, conn));
    try entry(&m, "persist_mode");
    try m.putVariantU32(2); // until revoked
    if (prev_token) |t| {
        try entry(&m, "restore_token");
        try m.putVariantString(t);
    }
    m.endArray(arr);
    var req = try portal.call(gpa, conn, iface, "SelectSources", "oa{sv}", m.buf.items, tok, portal.timeout_dialog_ms);
    defer req.deinit(gpa);
    return req.outcome.?;
}

fn entry(m: *dbus.Marshal, key: []const u8) !void {
    try m.beginStruct();
    try m.putString(key);
}

/// EMBEDDED (2) when the portal offers it, else HIDDEN (1).
fn cursorMode(gpa: std.mem.Allocator, conn: *dbus.Connection) u32 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(iface) catch return 1;
    m.putString("AvailableCursorModes") catch return 1;
    const serial = conn.callMethod(portal.bus_name, portal.object_path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items) catch return 1;
    var reply = conn.waitReplyOrError(serial, 2000) catch return 1;
    defer reply.deinit(gpa);
    if (reply.type == .@"error") return 1;
    var r = reply.reader();
    const v = r.readVariant() catch return 1;
    return switch (v) {
        .u32_ => |x| if (x & 2 != 0) 2 else 1,
        else => 1,
    };
}

fn startCast(gpa: std.mem.Allocator, conn: *dbus.Connection, path: []const u8) !portal.Result(portal.ScStart) {
    var tok_buf: [64]u8 = undefined;
    const tok = try token(&tok_buf);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putObjectPath(path);
    try m.putString("");
    const arr = try m.beginArray(8);
    try entry(&m, "handle_token");
    try m.putVariantString(tok);
    m.endArray(arr);
    var req = try portal.call(gpa, conn, iface, "Start", "osa{sv}", m.buf.items, tok, portal.timeout_dialog_ms);
    defer req.deinit(gpa);
    return switch (req.outcome.?) {
        .granted => {
            var r = try req.results();
            return .{ .granted = try portal.parseStartResults(gpa, &r) };
        },
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}
