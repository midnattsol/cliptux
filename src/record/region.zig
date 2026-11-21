//! The recorded area: a rectangle in the compositor's logical layout,
//! mapped onto a stream's pixels, and the encoded size (even for H.264,
//! scaled down to the maximum width for GIFs).

const std = @import("std");

/// Logical (compositor) coordinates, or pixels where said.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn area(self: Rect) i64 {
        return @as(i64, self.w) * self.h;
    }

    /// "x,y,w,h"
    pub fn parse(s: []const u8) !Rect {
        var it = std.mem.splitScalar(u8, s, ',');
        var v: [4]i32 = undefined;
        for (&v) |*x| x.* = try std.fmt.parseInt(i32, it.next() orelse return error.BadRegion, 10);
        if (it.next() != null or v[2] <= 0 or v[3] <= 0 or v[2] > 1 << 15 or v[3] > 1 << 15) return error.BadRegion;
        return .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
    }
};

/// The pixels of a `fw` x `fh` frame showing logical `mon` that hold
/// `region` (clipped to the monitor), or null when they do not meet.
pub fn toPixels(region: Rect, mon: Rect, fw: u32, fh: u32) ?Rect {
    const r = region.intersect(mon) orelse return null;
    const sx = @as(f64, @floatFromInt(fw)) / @as(f64, @floatFromInt(mon.w));
    const sy = @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(mon.h));
    const x0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.x - mon.x)) * sx));
    const y0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.y - mon.y)) * sy));
    const x1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.right() - mon.x)) * sx));
    const y1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.bottom() - mon.y)) * sy));
    const cx0 = std.math.clamp(x0, 0, @as(i32, @intCast(fw)));
    const cy0 = std.math.clamp(y0, 0, @as(i32, @intCast(fh)));
    const cx1 = std.math.clamp(x1, 0, @as(i32, @intCast(fw)));
    const cy1 = std.math.clamp(y1, 0, @as(i32, @intCast(fh)));
    if (cx1 <= cx0 or cy1 <= cy0) return null;
    return .{ .x = cx0, .y = cy0, .w = cx1 - cx0, .h = cy1 - cy0 };
}

/// H.264 4:2:0 wants even sizes: drop the odd last row or column.
pub fn evenSize(w: u32, h: u32) [2]u32 {
    return .{ @max(2, w & ~@as(u32, 1)), @max(2, h & ~@as(u32, 1)) };
}

/// A GIF no wider than `max_w` (0: no limit), keeping the shape.
pub fn gifSize(w: u32, h: u32, max_w: u32) [2]u32 {
    if (max_w == 0 or w <= max_w) return .{ w, h };
    const nh: u32 = @intCast(@max(1, (@as(u64, h) * max_w + w / 2) / w));
    return .{ max_w, nh };
}

/// The monitor (index into `mons`) holding most of `region`.
pub fn bestMonitor(region: Rect, mons: []const Rect) ?usize {
    var best: ?usize = null;
    var best_area: i64 = 0;
    for (mons, 0..) |m, i| {
        const a = if (region.intersect(m)) |r| r.area() else 0;
        if (a > best_area) {
            best_area = a;
            best = i;
        }
    }
    return best;
}

test "a region maps onto a scaled monitor's pixels" {
    const mon: Rect = .{ .x = 1600, .y = 0, .w = 1280, .h = 720 };
    // scale 2: twice the pixels
    const px = toPixels(.{ .x = 1700, .y = 50, .w = 200, .h = 100 }, mon, 2560, 1440).?;
    try std.testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 400, .h = 200 }, px);
    // clipped at the monitor's edge
    const c = toPixels(.{ .x = 1500, .y = 600, .w = 200, .h = 400 }, mon, 1280, 720).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 600, .w = 100, .h = 120 }, c);
    try std.testing.expect(toPixels(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, mon, 1280, 720) == null);
    // fractional 1.5
    const f = toPixels(.{ .x = 1601, .y = 1, .w = 3, .h = 3 }, mon, 1920, 1080).?;
    try std.testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 4, .h = 4 }, f);
}

test "sizes for the encoders" {
    try std.testing.expectEqual([2]u32{ 640, 358 }, evenSize(641, 359));
    try std.testing.expectEqual([2]u32{ 2, 2 }, evenSize(1, 1));
    try std.testing.expectEqual([2]u32{ 800, 450 }, gifSize(1600, 900, 800));
    try std.testing.expectEqual([2]u32{ 300, 200 }, gifSize(300, 200, 800));
}

test "regions parse and pick their monitor" {
    const r = try Rect.parse("100,-20,300,200");
    try std.testing.expectEqual(Rect{ .x = 100, .y = -20, .w = 300, .h = 200 }, r);
    try std.testing.expectError(error.BadRegion, Rect.parse("1,2,0,4"));
    try std.testing.expectError(error.BadRegion, Rect.parse("1,2,3"));
    const mons = [_]Rect{ .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .{ .x = 1600, .y = 0, .w = 1280, .h = 720 } };
    try std.testing.expectEqual(@as(?usize, 1), bestMonitor(.{ .x = 1500, .y = 10, .w = 400, .h = 100 }, &mons));
}
