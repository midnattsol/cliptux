//! Edge snapping for the ruler, like the pixel tools of macOS: a point
//! near a colour change moves onto it, so measuring a button or a gap
//! between two boxes lands exactly on their borders.
//!
//! Edges sit between pixels: x = 10 is the boundary between columns 9 and
//! 10. A boundary is an edge when the colours on its two sides differ by
//! more than `threshold` (sum of the channel differences).

const std = @import("std");
const Point = @import("../shapes.zig").Point;

pub const default_threshold: u32 = 60;

pub const Image = struct {
    px: []const u32,
    w: u32,
    h: u32,

    fn at(self: Image, x: i32, y: i32) u32 {
        return self.px[@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))];
    }
};

pub fn colorDistance(a: u32, b: u32) u32 {
    var d: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: i32 = @intCast((a >> sh) & 0xFF);
        const cb: i32 = @intCast((b >> sh) & 0xFF);
        d += @abs(ca - cb);
    }
    return d;
}

pub const Axis = enum { x, y };

/// The edge nearest to boundary `at` along `axis` (on row/column
/// `across`), within `radius`; null when there is none.
pub fn nearestEdge(img: Image, axis: Axis, at: i32, across: i32, radius: i32, threshold: u32) ?i32 {
    const len: i32 = @intCast(if (axis == .x) img.w else img.h);
    const other: i32 = @intCast(if (axis == .x) img.h else img.w);
    if (across < 0 or across >= other) return null;
    var d: i32 = 0;
    while (d <= radius) : (d += 1) {
        // the nearer side first; ties go to the lower boundary
        for ([2]i32{ at - d, at + d }) |b| {
            if (b <= 0 or b >= len) continue;
            const p0 = if (axis == .x) img.at(b - 1, across) else img.at(across, b - 1);
            const p1 = if (axis == .x) img.at(b, across) else img.at(across, b);
            if (colorDistance(p0, p1) > threshold) return b;
            if (d == 0) break;
        }
    }
    return null;
}

/// `p` moved onto the nearest edges within `radius`: x and y snap on
/// their own, so a corner pulls a point into it. `lock` keeps one
/// coordinate (a ruler held on an axis).
pub fn snap(img: Image, p: Point, radius: i32, lock: ?Axis) Point {
    var q = p;
    if (lock != .x) {
        if (nearestEdge(img, .x, p.x, p.y, radius, default_threshold)) |x| q.x = x;
    }
    if (lock != .y) {
        if (nearestEdge(img, .y, p.y, p.x, radius, default_threshold)) |y| q.y = y;
    }
    return q;
}

const testing = std.testing;

/// 40x30 white with a black box from (10, 8) to (25, 20) (exclusive).
fn boxImage(buf: *[40 * 30]u32) Image {
    for (buf, 0..) |*p, i| {
        const x = i % 40;
        const y = i / 40;
        p.* = if (x >= 10 and x < 25 and y >= 8 and y < 20) 0xFF000000 else 0xFFFFFFFF;
    }
    return .{ .px = buf, .w = 40, .h = 30 };
}

test "nearest edge in both directions" {
    var buf: [40 * 30]u32 = undefined;
    const img = boxImage(&buf);
    try testing.expectEqual(@as(?i32, 10), nearestEdge(img, .x, 12, 10, 5, default_threshold));
    try testing.expectEqual(@as(?i32, 25), nearestEdge(img, .x, 23, 10, 5, default_threshold));
    try testing.expectEqual(@as(?i32, 8), nearestEdge(img, .y, 6, 15, 5, default_threshold));
    // out of reach, or on a row without the box
    try testing.expectEqual(@as(?i32, null), nearestEdge(img, .x, 17, 10, 5, default_threshold));
    try testing.expectEqual(@as(?i32, null), nearestEdge(img, .x, 12, 25, 5, default_threshold));
    // at the image border: no edge, no out-of-bounds read
    try testing.expectEqual(@as(?i32, null), nearestEdge(img, .x, 0, 0, 3, default_threshold));
    try testing.expectEqual(@as(?i32, null), nearestEdge(img, .y, 30, 39, 3, default_threshold));
}

test "a point near a corner snaps into it, a locked axis stays" {
    var buf: [40 * 30]u32 = undefined;
    const img = boxImage(&buf);
    try testing.expectEqual(Point{ .x = 25, .y = 20 }, snap(img, .{ .x = 23, .y = 18 }, 4, null));
    try testing.expectEqual(Point{ .x = 23, .y = 20 }, snap(img, .{ .x = 23, .y = 18 }, 4, .x));
    try testing.expectEqual(Point{ .x = 25, .y = 18 }, snap(img, .{ .x = 23, .y = 18 }, 4, .y));
    // nothing near: unchanged
    try testing.expectEqual(Point{ .x = 35, .y = 3 }, snap(img, .{ .x = 35, .y = 3 }, 3, null));
}

test "faint changes are not edges" {
    var buf: [8 * 1]u32 = .{ 0xFF808080, 0xFF808080, 0xFF828282, 0xFF828282, 0xFF808080, 0xFF808080, 0xFF000000, 0xFF000000 };
    const img: Image = .{ .px = &buf, .w = 8, .h = 1 };
    try testing.expectEqual(@as(?i32, 6), nearestEdge(img, .x, 3, 0, 4, default_threshold));
}
