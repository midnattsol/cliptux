//! KWin's org.kde.KWin.ScreenShot2 for direct capture (app/direct.zig)
//! and window capture (app/modes/window_direct.zig): the call, KWin's
//! refusal reasons, and the image KWin writes into a pipe.

const std = @import("std");
const dbus = @import("../platform/linux/dbus.zig");
const sys = @import("../platform/linux/sys.zig");
const direct = @import("direct.zig");
const Frame = direct.Frame;

pub var refused: []const u8 = "no direct capture interface";

/// One KWin output via org.kde.KWin.ScreenShot2, at its native
/// resolution, without the pointer. Null when KWin is not running here or
/// refuses this binary (refused says why).
pub fn screen(gpa: std.mem.Allocator, bus: *dbus.Connection, output_name: []const u8) !?Frame {
    if (output_name.len == 0) {
        refused = "outputs without names";
        return null;
    }
    const p = try sys.pipe();
    defer sys.close(p[0]);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(output_name);
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("native-resolution");
    try m.putVariantBool(true);
    try m.beginStruct();
    try m.putString("include-cursor");
    try m.putVariantBool(false);
    m.endArray(arr);
    try m.putU32(0); // fd index
    const serial = bus.callMethodFds("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureScreen", "sa{sv}h", m.buf.items, &.{p[1]}) catch |err| {
        sys.close(p[1]);
        if (err == error.NoFdPassing) {
            refused = "the session bus passes no file descriptors";
            return null;
        }
        return err;
    };
    sys.close(p[1]);
    return reply(gpa, bus, serial, p[0], false, 10_000);
}

/// The image KWin writes to `read_fd` after answering call `serial`; null
/// when KWin refused (refused says why). `alpha`: keep see-through
/// pixels (a window's rounded corners), else opaque.
pub fn reply(gpa: std.mem.Allocator, bus: *dbus.Connection, serial: u32, read_fd: sys.fd_t, alpha: bool, timeout_ms: i64) !?Frame {
    var msg = try bus.waitReplyOrError(serial, timeout_ms);
    defer msg.deinit(gpa);
    if (msg.type == .@"error") {
        const e = msg.error_name orelse "";
        refused = if (std.mem.indexOf(u8, e, "NoAuthorized") != null)
            "KWin refused: the installed .desktop file does not list org.kde.KWin.ScreenShot2 for this executable"
        else if (std.mem.eql(u8, e, "org.freedesktop.DBus.Error.ServiceUnknown") or std.mem.eql(u8, e, "org.freedesktop.DBus.Error.UnknownObject") or std.mem.eql(u8, e, "org.freedesktop.DBus.Error.UnknownMethod"))
            "no direct capture interface"
        else
            "KWin ScreenShot2 failed";
        std.log.info("direct capture: {s} ({s})", .{ refused, e });
        return null;
    }
    var w: u32 = 0;
    var h: u32 = 0;
    var stride: u32 = 0;
    var format: u32 = 0;
    var r = msg.reader();
    var dict = try r.readDictSV();
    while (try dict.next()) |e| {
        const v: u32 = switch (e.value) {
            .u32_ => |x| x,
            else => continue,
        };
        const eql = std.mem.eql;
        if (eql(u8, e.key, "width")) w = v else if (eql(u8, e.key, "height")) h = v else if (eql(u8, e.key, "stride")) stride = v else if (eql(u8, e.key, "format")) format = v;
    }
    if (w == 0 or h == 0 or stride < w * 4 or qimageConvert(format, 0) == null) return error.UnknownImageFormat;
    const size = @as(usize, stride) * h;
    const raw = try gpa.alloc(u8, size);
    defer gpa.free(raw);
    var got: usize = 0;
    const deadline = sys.monoMs() + 10_000;
    while (got < size) {
        if (!try sys.waitReadable(read_fd, deadline)) return error.ShortImage;
        const k = try sys.read(read_fd, raw[got..]);
        if (k == 0) return error.ShortImage;
        got += k;
    }
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        const v = std.mem.readInt(u32, raw[y * stride + x * 4 ..][0..4], .little);
        px[y * w + x] = if (alpha) qimageAlpha(format, v) orelse qimageConvert(format, v).? else qimageConvert(format, v).?;
    };
    return .{ .pixels = px, .width = w, .height = h };
}

/// A 32-bit QImage pixel (little-endian word) as 0xFFRRGGBB; null for
/// formats not handled.
fn qimageConvert(format: u32, p: u32) ?u32 {
    return switch (format) {
        // RGB32, ARGB32, ARGB32_Premultiplied: 0xAARRGGBB words
        4, 5, 6 => 0xFF000000 | (p & 0xFFFFFF),
        // RGBX8888, RGBA8888(_Premultiplied): bytes R G B A
        16, 17, 18 => direct.convert(direct.fmt_xbgr8888, p),
        // BGR30, A2BGR30_Premultiplied: 2-10-10-10, blue high
        19, 20 => direct.convert(direct.fmt_xbgr2101010, p),
        // RGB30, A2RGB30_Premultiplied
        21, 22 => direct.convert(direct.fmt_xrgb2101010, p),
        else => null,
    };
}

/// ARGB32 (5) as is, ARGB32_Premultiplied (6) unpremultiplied; null for
/// formats without alpha.
fn qimageAlpha(format: u32, p: u32) ?u32 {
    const a = p >> 24;
    return switch (format) {
        5 => p,
        6 => if (a == 0) 0 else blk: {
            var out: u32 = a << 24;
            inline for (.{ 0, 8, 16 }) |sh| out |= @as(u32, @min(255, ((p >> sh) & 0xFF) * 255 / a)) << sh;
            break :blk out;
        },
        else => null,
    };
}

test "QImage formats" {
    try std.testing.expectEqual(@as(?u32, 0x80FF0000), qimageAlpha(6, 0x80800000));
    try std.testing.expectEqual(@as(?u32, 0), qimageAlpha(6, 0x00123456));
    try std.testing.expectEqual(@as(?u32, 0xFF112233), qimageConvert(4, 0x00112233));
    try std.testing.expectEqual(@as(?u32, 0xFF112233), qimageConvert(17, 0xFF332211));
    try std.testing.expectEqual(@as(?u32, null), qimageConvert(3, 0));
}
