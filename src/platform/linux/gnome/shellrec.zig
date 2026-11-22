//! Recording through the Shotlet GNOME Shell extension (recorder.js):
//! no prompt. StartRecording gives the PipeWire node of a screencast of
//! the area that mutter makes for the shell; StopRecording ends it (so
//! does Shotlet leaving the bus). RecordingStopRequested comes from the
//! top bar's stop button and the record shortcut.

const std = @import("std");
const dbus = @import("../dbus.zig");
const region = @import("../../../record/region.zig");

const bus_name = "dev.shotlet.Shell1";
const path = "/dev/shotlet/Shell1";
const iface = "dev.shotlet.Shell1";

pub const Options = struct {
    area: region.Rect,
    cursor: bool = true,
    clicks: bool = false,
    keys: bool = false,
};

/// The extension records (version 3 and later).
pub fn available(gpa: std.mem.Allocator, bus: *dbus.Connection) bool {
    if (!(bus.nameHasOwner(bus_name) catch false)) return false;
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(iface) catch return false;
    m.putString("Version") catch return false;
    const serial = bus.callMethod(bus_name, path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items) catch return false;
    var reply = bus.waitReplyOrError(serial, 2000) catch return false;
    defer reply.deinit(gpa);
    if (reply.type == .@"error") return false;
    var r = reply.reader();
    const v = r.readVariant() catch return false;
    return switch (v) {
        .u32_ => |x| x >= 3,
        else => false,
    };
}

fn putInt(m: *dbus.Marshal, key: []const u8, v: i32) !void {
    try m.beginStruct();
    try m.putString(key);
    try m.putVariantI32(v);
}

fn putFlag(m: *dbus.Marshal, key: []const u8, v: bool) !void {
    try m.beginStruct();
    try m.putString(key);
    try m.putVariantBool(v);
}

/// Start the screencast; the PipeWire node to read.
pub fn start(gpa: std.mem.Allocator, bus: *dbus.Connection, o: Options) !u32 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try putInt(&m, "x", o.area.x);
    try putInt(&m, "y", o.area.y);
    try putInt(&m, "w", o.area.w);
    try putInt(&m, "h", o.area.h);
    try putFlag(&m, "cursor", o.cursor);
    try putFlag(&m, "clicks", o.clicks);
    try putFlag(&m, "keys", o.keys);
    m.endArray(arr);
    const serial = try bus.callMethod(bus_name, path, iface, "StartRecording", "a{sv}", m.buf.items);
    var reply = try bus.waitReplyOrError(serial, 10_000);
    defer reply.deinit(gpa);
    var r = reply.reader();
    if (reply.type == .@"error") {
        std.log.info("GNOME integration: recording refused: {s} ({s})", .{ reply.error_name orelse "?", r.readString() catch "" });
        return error.Refused;
    }
    return try r.readU32();
}

/// Ask the extension to capture the desktop and start the picker on it
/// (`shotlet --from-shell ... --then record`).
pub fn select(gpa: std.mem.Allocator, bus: *dbus.Connection) !void {
    const serial = try bus.callMethod(bus_name, path, iface, "RecordSelect", "", "");
    var reply = try bus.waitReplyOrError(serial, 10_000);
    defer reply.deinit(gpa);
    if (reply.type == .@"error") return error.Refused;
}

pub fn stop(bus: *dbus.Connection) void {
    _ = bus.callMethod(bus_name, path, iface, "StopRecording", "", "") catch {};
}

/// Hear the stop button and the shortcut.
pub fn watchStop(bus: *dbus.Connection) !void {
    try bus.addMatch("type='signal',interface='" ++ iface ++ "',member='RecordingStopRequested'");
}

pub fn isStopRequest(msg: *const dbus.Message) bool {
    return msg.isSignal(iface, "RecordingStopRequested");
}
