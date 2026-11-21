//! Where a recording's pictures come from: the GNOME Shell extension
//! (no prompt; a screencast of exactly the area) or the ScreenCast portal
//! (a monitor, cropped to the area; consent once, then the restore token).

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const pwstream = @import("../platform/pwstream.zig");
const config = @import("../app/config.zig");
const gnome = @import("../app/gnome.zig");
const portal = @import("../platform/portal.zig");
const region = @import("region.zig");
const shellrec = @import("shellrec.zig");
const portal_rec = @import("portal_rec.zig");

pub const Want = struct {
    area: region.Rect,
    clicks: bool = false,
    keys: bool = false,
};

pub const Source = struct {
    kind: enum { shell, portal },
    cap: *pwstream.Capture,
    node: u32,
    /// the stream's logical rectangle, and the part of it to keep
    stream_rect: region.Rect,
    crop: ?region.Rect,
    session: ?portal_rec.Session = null,

    pub fn label(self: *const Source) []const u8 {
        return switch (self.kind) {
            .shell => "GNOME integration",
            .portal => "ScreenCast portal",
        };
    }

    /// After the engine stopped.
    pub fn close(self: *Source, gpa: std.mem.Allocator, bus: *dbus.Connection) void {
        self.cap.close(gpa);
        switch (self.kind) {
            .shell => shellrec.stop(bus),
            .portal => if (self.session) |*s| s.close(gpa, bus),
        }
    }
};

pub const Opened = union(enum) { ok: Source, cancelled, failed: anyerror };

pub fn open(gpa: std.mem.Allocator, bus: *dbus.Connection, home: []const u8, cfg: *config.Config, want: Want) Opened {
    if (std.c.getenv("SHOTLET_NO_SHELL_RECORD") == null and gnome.isGnome() and shellrec.available(gpa, bus)) {
        if (openShell(gpa, bus, want)) |s| return .{ .ok = s } else |err| std.log.info("recording: GNOME integration: {t}; the portal", .{err});
    }
    return openPortal(gpa, bus, home, cfg, want) catch |err| .{ .failed = err };
}

fn openShell(gpa: std.mem.Allocator, bus: *dbus.Connection, want: Want) !Source {
    const node = try shellrec.start(gpa, bus, .{ .area = want.area, .clicks = want.clicks, .keys = want.keys });
    errdefer shellrec.stop(bus);
    const cap = try pwstream.Capture.open(gpa, null);
    std.log.info("recording: source GNOME integration (node {d})", .{node});
    return .{ .kind = .shell, .cap = cap, .node = node, .stream_rect = want.area, .crop = null };
}

fn openPortal(gpa: std.mem.Allocator, bus: *dbus.Connection, home: []const u8, cfg: *config.Config, want: Want) !Opened {
    portal.registerApp(gpa, bus);
    var session = switch (try portal_rec.open(gpa, bus, cfg.scToken())) {
        .granted => |s| s,
        .cancelled, .timeout => return .cancelled,
        .denied => return error.Denied,
        .unavailable => return error.NoScreenCast,
    };
    errdefer session.close(gpa, bus);
    if (session.start.restore_token) |t| {
        cfg.setScToken(t);
        config.saveScreencastToken(gpa, home, t) catch {};
    }
    const pick = pickStream(session.start.streams, want.area) orelse return error.NoStream;
    const cap = try pwstream.Capture.open(gpa, session.fd);
    std.log.info("recording: source ScreenCast portal (node {d}, monitor {d},{d} {d}x{d})", .{ pick.node, pick.rect.x, pick.rect.y, pick.rect.w, pick.rect.h });
    return .{ .ok = .{ .kind = .portal, .cap = cap, .node = pick.node, .stream_rect = pick.rect, .crop = want.area, .session = session } };
}

/// The stream showing most of the area. A portal that gives no position
/// (or size) has one monitor at the origin, as the screenshots saw it
/// (the first stream is taken when none overlaps).
fn pickStream(streams: []const portal.Stream, area: region.Rect) ?struct { node: u32, rect: region.Rect } {
    if (streams.len == 0) return null;
    var rects: [16]region.Rect = undefined;
    const n = @min(streams.len, rects.len);
    for (streams[0..n], 0..) |s, i| {
        const pos = s.position orelse .{ 0, 0 };
        // no size: frames.zig takes the frame's pixels as logical
        const size = s.size orelse .{ 0, 0 };
        rects[i] = .{ .x = pos[0], .y = pos[1], .w = size[0], .h = size[1] };
    }
    const best = region.bestMonitor(area, rects[0..n]) orelse 0;
    return .{ .node = streams[best].node_id, .rect = rects[best] };
}

test "the stream holding the area is picked" {
    const streams = [_]portal.Stream{
        .{ .node_id = 7, .position = .{ 0, 0 }, .size = .{ 1600, 900 } },
        .{ .node_id = 9, .position = .{ 1600, 0 }, .size = .{ 1280, 720 } },
    };
    const p = pickStream(&streams, .{ .x = 1700, .y = 100, .w = 300, .h = 200 }).?;
    try std.testing.expectEqual(@as(u32, 9), p.node);
    const lone = [_]portal.Stream{.{ .node_id = 3 }};
    const q = pickStream(&lone, .{ .x = 10, .y = 10, .w = 30, .h = 20 }).?;
    try std.testing.expectEqual(region.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, q.rect);
}
