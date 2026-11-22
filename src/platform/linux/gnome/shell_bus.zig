//! Shotlet's side of the GNOME extension's capture-mode methods
//! (dev.shotlet.Shell1, version 3; see gnome-extension/.../modes.js and
//! scroll.js): CaptureMode, and the scrolling capture's session.

const std = @import("std");
const dbus = @import("../dbus.zig");
const gnome = @import("../gnome.zig");
const geom = @import("../../../app/modes/geom.zig");
const mode = @import("../../../app/modes/mode.zig");

const path = "/dev/shotlet/Shell1";
const iface = "dev.shotlet.Shell1";

/// The reply, or the error's name and message logged and returned.
fn call(gpa: std.mem.Allocator, bus: *dbus.Connection, member: []const u8, sig: []const u8, body: []const u8, timeout_ms: i64) !dbus.Message {
    const serial = try bus.callMethod(gnome.bus_name, path, iface, member, sig, body);
    var reply = try bus.waitReplyOrError(serial, timeout_ms);
    if (reply.type != .@"error") return reply;
    defer reply.deinit(gpa);
    var r = reply.reader();
    const name = reply.error_name orelse "?";
    std.log.info("GNOME integration {s}: {s} ({s})", .{ member, name, r.readString() catch "" });
    if (std.mem.endsWith(u8, name, ".Busy") or std.mem.endsWith(u8, name, ".Locked")) return error.Busy;
    if (std.mem.endsWith(u8, name, ".UnknownMethod")) return error.TooOld;
    if (std.mem.endsWith(u8, name, ".AccessDenied")) return error.AccessDenied;
    return error.Refused;
}

pub const Handoff = @import("../../api/shell.zig").Handoff;

/// Ask the extension to capture in this mode (after its countdown).
/// An area capture with no delay uses Capture(), which every version has.
pub fn requestMode(gpa: std.mem.Allocator, bus: *dbus.Connection, req: mode.Request) Handoff {
    if (req.mode == .area and req.delay_s == 0) return switch (gnome.requestCapture(gpa, bus)) {
        .started => .started,
        .declined => .declined,
        .unavailable => .unavailable,
    };
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(@tagName(req.mode)) catch return .unavailable;
    m.putU32(req.delay_s) catch return .unavailable;
    var reply = call(gpa, bus, "CaptureMode", "su", m.buf.items, 5000) catch |err| return switch (err) {
        error.Busy => .declined,
        else => .unavailable,
    };
    defer reply.deinit(gpa);
    var r = reply.reader();
    return if ((r.readU32() catch 0) != 0) .started else .unavailable;
}

/// A scrolling capture session in the extension.
pub const Scroll = struct {
    gpa: std.mem.Allocator,
    bus: *dbus.Connection,
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,

    fn id(self: *const Scroll) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    /// `region` in logical coordinates; `auto`: the extension turns the
    /// wheel for each step.
    pub fn begin(gpa: std.mem.Allocator, bus: *dbus.Connection, region: geom.Rect, auto: bool) !Scroll {
        var m = dbus.Marshal.init(gpa);
        defer m.deinit();
        for (region.array()) |v| try m.putI32(v);
        try m.putBool(auto);
        var reply = try call(gpa, bus, "ScrollBegin", "iiiib", m.buf.items, 5000);
        defer reply.deinit(gpa);
        var r = reply.reader();
        const s = try r.readString();
        var self: Scroll = .{ .gpa = gpa, .bus = bus };
        if (s.len > self.id_buf.len) return error.BadReply;
        @memcpy(self.id_buf[0..s.len], s);
        self.id_len = s.len;
        return self;
    }

    /// Scroll `clicks` wheel notches (0: none), then grab the region. The
    /// capture id of its PNG goes into `out`.
    pub fn step(self: *Scroll, clicks: i32, out: []u8) ![]u8 {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(self.id());
        try m.putI32(clicks);
        var reply = try call(self.gpa, self.bus, "ScrollStep", "si", m.buf.items, 5000);
        defer reply.deinit(self.gpa);
        var r = reply.reader();
        const s = try r.readString();
        if (s.len > out.len) return error.BadReply;
        @memcpy(out[0..s.len], s);
        return out[0..s.len];
    }

    pub fn end(self: *Scroll) void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        m.putString(self.id()) catch return;
        var reply = call(self.gpa, self.bus, "ScrollEnd", "s", m.buf.items, 2000) catch return;
        reply.deinit(self.gpa);
    }
};

/// Move one of Shotlet's tagged windows (Place): false when the extension
/// does not know it (yet).
pub fn place(gpa: std.mem.Allocator, bus: *dbus.Connection, title: []const u8, x: i32, y: i32) bool {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(title) catch return false;
    m.putI32(x) catch return false;
    m.putI32(y) catch return false;
    var reply = call(gpa, bus, "Place", "sii", m.buf.items, 2000) catch return false;
    defer reply.deinit(gpa);
    var r = reply.reader();
    return (r.readU32() catch 0) != 0;
}
