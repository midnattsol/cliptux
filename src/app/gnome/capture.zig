//! Prompt-free captures through the active extension (dev.shotlet.Shell1):
//! asking it to capture, and what it reports about its shortcut.

const std = @import("std");
const dbus = @import("../../platform/linux/dbus.zig");
const extension = @import("extension.zig");

const bus_name = extension.bus_name;
const shell1_path = "/dev/shotlet/Shell1";
const shell1_iface = "dev.shotlet.Shell1";

pub const CaptureRequest = enum {
    /// the extension took the screenshot and started the editor
    started,
    /// a capture is already under way, or the screen is locked: nothing
    /// else should capture now
    declined,
    /// not possible (an older extension, a failure): capture another way
    unavailable,
};

/// Ask the extension to take a screenshot and start Shotlet's editor on
/// it (dev.shotlet.Shell1.Capture: no pixels come back over the bus).
pub fn requestCapture(gpa: std.mem.Allocator, bus: *dbus.Connection) CaptureRequest {
    const serial = bus.callMethod(bus_name, shell1_path, shell1_iface, "Capture", "", "") catch return .unavailable;
    var reply = bus.waitReplyOrError(serial, 5000) catch |err| {
        std.log.info("GNOME integration capture: {t}", .{err});
        return .unavailable;
    };
    defer reply.deinit(gpa);
    var r = reply.reader();
    if (reply.type == .@"error") {
        const name = reply.error_name orelse "?";
        std.log.info("GNOME integration capture refused: {s} ({s})", .{ name, r.readString() catch "" });
        if (std.mem.eql(u8, name, shell1_iface ++ ".Error.Busy") or std.mem.eql(u8, name, shell1_iface ++ ".Error.Locked")) return .declined;
        return .unavailable;
    }
    return if ((r.readU32() catch 0) != 0) .started else .unavailable;
}

/// How captures go, for `status` and the Settings window.
pub const CaptureInfo = struct {
    /// the extension is active and captures (version 2 and later)
    capture: bool = false,
    /// its bound shortcut, or the one GNOME's screenshot tool holds
    shortcut_buf: [64]u8 = undefined,
    shortcut_len: usize = 0,
    blocked: bool = false,

    pub fn shortcut(self: *const CaptureInfo) ?[]const u8 {
        return if (self.shortcut_len > 0) self.shortcut_buf[0..self.shortcut_len] else null;
    }
};

pub fn captureInfo(gpa: std.mem.Allocator, bus: *dbus.Connection) CaptureInfo {
    var info: CaptureInfo = .{};
    if (!extensionCaptures(gpa, bus)) return info;
    info.capture = true;
    for ([_][]const u8{ "Shortcuts", "BlockedShortcuts" }) |prop| {
        if (readShortcut(gpa, bus, prop, &info)) {
            info.blocked = std.mem.eql(u8, prop, "BlockedShortcuts");
            break;
        }
    }
    return info;
}

/// The extension is active and new enough (Version 2) to capture.
fn extensionCaptures(gpa: std.mem.Allocator, bus: *dbus.Connection) bool {
    if (!extension.extensionActive(bus)) return false;
    var msg = getProperty(gpa, bus, "Version") catch return false;
    defer msg.deinit(gpa);
    var r = msg.reader();
    const v = r.readVariant() catch return false;
    return v == .u32_ and v.u32_ >= 2;
}

/// The first accelerator of the `prop` list into `info`; false when there
/// is none (or it cannot be read).
fn readShortcut(gpa: std.mem.Allocator, bus: *dbus.Connection, prop: []const u8, info: *CaptureInfo) bool {
    var m = getProperty(gpa, bus, prop) catch return false;
    defer m.deinit(gpa);
    var pr = m.reader();
    const acc = (readFirstOfStrvVariant(&pr) catch return false) orelse return false;
    const n = @min(acc.len, info.shortcut_buf.len);
    @memcpy(info.shortcut_buf[0..n], acc[0..n]);
    info.shortcut_len = n;
    return true;
}

fn getProperty(gpa: std.mem.Allocator, bus: *dbus.Connection, prop: []const u8) !dbus.Message {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(shell1_iface);
    try m.putString(prop);
    const serial = try bus.callMethod(bus_name, shell1_path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items);
    return bus.waitReplyTimeout(serial, 2000);
}

/// A variant holding `as`: its first string, if any.
fn readFirstOfStrvVariant(r: *dbus.Reader) !?[]const u8 {
    const sig = try r.readSignature();
    if (!std.mem.eql(u8, sig, "as")) return error.BadSignature;
    const len = try r.readU32();
    if (len == 0) return null;
    return try r.readString();
}

/// The capture shortcut, for the command line (stderr).
pub fn printShortcut(info: *const CaptureInfo) void {
    const out = std.debug.print;
    if (!info.capture) return;
    if (info.shortcut()) |k| {
        if (info.blocked) {
            out("Shortcut {s}: GNOME's own screenshot tool uses that key, so Shotlet leaves it alone.\n" ++
                "  Pick another: shotlet gnome-integration shortcut '<Shift><Super>s'\n" ++
                "  (or free {s} in GNOME Settings \u{203A} Keyboard \u{203A} View and Customize Shortcuts \u{203A} Screenshots)\n", .{ k, k });
        } else out("Shortcut {s} captures without prompts.\n", .{k});
    } else out("No capture shortcut (shotlet gnome-integration shortcut KEY sets one).\n", .{});
}
