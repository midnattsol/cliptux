//! Where the windows were when the screen was captured, for clicking a
//! window during area selection (ui/editor/winpick.zig): their frames,
//! topmost first, in the capture's image pixels. Taken for the frozen
//! frame, never live:
//!
//! - GNOME with the Shotlet extension: it notes them in the very frame it
//!   captures; CaptureWindows(ID) hands them to the shotlet started on
//!   that capture (once, Shotlet's executable only).
//! - KWin: a one-off KWin script (winrects/kwin.zig), right after the
//!   capture, through KWin's scripting interface (no permission needed).
//! - anywhere else nothing tells a client where windows are: none, and the
//!   editor simply offers no window clicks.

const std = @import("std");
const capture = @import("capture.zig");
const dbus = @import("../platform/dbus.zig");
const sys = @import("../platform/sys.zig");
const gnome = @import("gnome.zig");
const geom = @import("modes/geom.zig");
const env_mod = @import("env.zig");
const kwin = @import("winrects/kwin.zig");

/// In image pixels, as the editor takes them.
pub const Rect = @import("../ui/shapes.zig").Rect;

/// The most windows kept (the topmost ones).
pub const max_windows = 64;

/// The windows of capture `cap` (owned, maybe empty). `shell_id`: the
/// GNOME extension's capture id when it took the capture.
pub fn fetch(gpa: std.mem.Allocator, env: env_mod.Env, conn: *dbus.Connection, cap: *const capture.Capture, shell_id: ?[]const u8) []Rect {
    var logical: [max_windows * 4]i32 = undefined;
    const t0 = sys.monoMs();
    const flat = if (shell_id) |id| fromGnome(gpa, conn, id, &logical) else if (isKwin(conn)) kwin.fetch(gpa, env, conn, &logical) else return &.{};
    const out = toImage(gpa, cap.monitors, flat) catch return &.{};
    std.log.info("windows: {d} where the capture was taken ({d}ms)", .{ out.len, sys.monoMs() - t0 });
    return out;
}

/// Whether a window capture (`shotlet window`) can pick a window here:
/// with the GNOME extension or on KWin (else it falls back to an area).
pub fn windowCapture(conn: *dbus.Connection) bool {
    return (gnome.isGnome() and gnome.extensionActive(conn)) or isKwin(conn);
}

fn isKwin(conn: *dbus.Connection) bool {
    return conn.nameHasOwner("org.kde.KWin") catch false;
}

/// CaptureWindows(id) of the extension: [x, y, w, h, ...] logical, into
/// `out`; empty when the extension is older or refuses.
fn fromGnome(gpa: std.mem.Allocator, conn: *dbus.Connection, id: []const u8, out: []i32) []const i32 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(id) catch return &.{};
    const serial = conn.callMethod(gnome.bus_name, "/dev/shotlet/Shell1", "dev.shotlet.Shell1", "CaptureWindows", "s", m.buf.items) catch return &.{};
    var reply = conn.waitReplyOrError(serial, 1000) catch return &.{};
    defer reply.deinit(gpa);
    if (reply.type == .@"error") {
        std.log.info("windows: the GNOME integration has none to give ({s})", .{reply.error_name orelse "?"});
        return &.{};
    }
    var r = reply.reader();
    return readInts(&r, out) catch &.{};
}

/// An `ai` array into `out` (whole rectangles only, the topmost ones).
fn readInts(r: *dbus.Reader, out: []i32) ![]const i32 {
    const bytes = try r.readU32();
    const n = @min(bytes / 4, out.len) / 4 * 4;
    for (out[0..n]) |*v| v.* = @bitCast(try r.readU32());
    return out[0..n];
}

/// Logical frames to image rectangles: each over every monitor it shows
/// on (a window across two is one rectangle), off-screen ones dropped.
pub fn toImage(gpa: std.mem.Allocator, mons: []const capture.Monitor, flat: []const i32) ![]Rect {
    var list: std.ArrayList(Rect) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (i + 4 <= flat.len) : (i += 4) {
        const l: geom.Rect = .{ .x = flat[i], .y = flat[i + 1], .w = flat[i + 2], .h = flat[i + 3] };
        if (l.w <= 0 or l.h <= 0) continue;
        const r = spanImage(mons, l) orelse continue;
        if (r.w < 8 or r.h < 8) continue;
        try list.append(gpa, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }
    return list.toOwnedSlice(gpa);
}

/// The union of `l`'s part on each monitor, in image pixels.
fn spanImage(mons: []const capture.Monitor, l: geom.Rect) ?geom.Rect {
    var acc: ?geom.Rect = null;
    for (mons) |m| {
        const ml = m.logical orelse continue;
        const lm: geom.Rect = .{ .x = ml.x, .y = ml.y, .w = @intCast(ml.w), .h = @intCast(ml.h) };
        const part = geom.Rect.intersect(l, lm) orelse continue;
        const px = geom.logicalToImage(&.{m}, part) orelse continue;
        acc = if (acc) |a| unite(a, px) else px;
    }
    return acc;
}

fn unite(a: geom.Rect, b: geom.Rect) geom.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
}

comptime {
    _ = kwin;
}

const testing = std.testing;

test "window frames land in image pixels, across monitors and scales" {
    const mons = [_]capture.Monitor{
        .{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 } },
        .{ .x = 2560, .y = 0, .w = 1280, .h = 720, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 } },
    };
    const flat = [_]i32{
        100, 50, 400, 300, // on the 2x monitor
        1180, 0, 200, 100, // across both
        5000, 5000, 100, 100, // nowhere
        10, 10, 2, 2, // too small to click
    };
    const out = try toImage(testing.allocator, &mons, &flat);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 800, .h = 600 }, out[0]);
    try testing.expectEqual(Rect{ .x = 2360, .y = 0, .w = 300, .h = 200 }, out[1]);
}

test "a layout without logical positions gives no windows" {
    const mons = [_]capture.Monitor{.{ .x = 0, .y = 0, .w = 800, .h = 600 }};
    const out = try toImage(testing.allocator, &mons, &.{ 0, 0, 100, 100 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}
