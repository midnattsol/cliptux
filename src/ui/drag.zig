//! Drag constraints: Shift makes squares, circles and 45-degree lines,
//! Alt draws from the centre.

const std = @import("std");
const shapes = @import("shapes.zig");
const Point = shapes.Point;
const Rect = shapes.Rect;

// --- drag constraints (Shift: square / 45 degrees, Alt: from the centre) ---

/// Corners of a box dragged from `anchor` to `p`: Shift makes it a
/// square (circle), Alt grows it around the anchor.
pub fn dragCorners(anchor: Point, p: Point, square: bool, center: bool) [2]Point {
    var q = p;
    if (square) {
        const dx = p.x - anchor.x;
        const dy = p.y - anchor.y;
        const m: i32 = @intCast(@max(@abs(dx), @abs(dy)));
        q = .{ .x = anchor.x + (if (dx < 0) -m else m), .y = anchor.y + (if (dy < 0) -m else m) };
    }
    if (center) return .{ .{ .x = 2 * anchor.x - q.x, .y = 2 * anchor.y - q.y }, q };
    return .{ anchor, q };
}

/// `p` moved onto the nearest 45-degree ray from `anchor`, keeping its
/// distance along that ray.
pub fn snapAngle(anchor: Point, p: Point) Point {
    const dx: f64 = @floatFromInt(p.x - anchor.x);
    const dy: f64 = @floatFromInt(p.y - anchor.y);
    if (dx == 0 and dy == 0) return p;
    const step = std.math.pi / 4.0;
    const ang = @round(std.math.atan2(dy, dx) / step) * step;
    const len = dx * @cos(ang) + dy * @sin(ang);
    return .{
        .x = anchor.x + @as(i32, @intFromFloat(@round(len * @cos(ang)))),
        .y = anchor.y + @as(i32, @intFromFloat(@round(len * @sin(ang)))),
    };
}

test "shift and alt drag constraints" {
    const a = Point{ .x = 100, .y = 100 };
    const sq = dragCorners(a, .{ .x = 130, .y = 90 }, true, false);
    try std.testing.expectEqual(Point{ .x = 130, .y = 70 }, sq[1]);
    const c = dragCorners(a, .{ .x = 120, .y = 110 }, false, true);
    try std.testing.expectEqual(Point{ .x = 80, .y = 90 }, c[0]);
    try std.testing.expectEqual(Point{ .x = 120, .y = 110 }, c[1]);
    const both = dragCorners(a, .{ .x = 90, .y = 130 }, true, true);
    try std.testing.expect(Rect.fromCorners(both[0], both[1]).eql(.{ .x = 70, .y = 70, .w = 60, .h = 60 }));
    try std.testing.expectEqual(Point{ .x = 150, .y = 100 }, snapAngle(a, .{ .x = 150, .y = 108 }));
    try std.testing.expectEqual(Point{ .x = 100, .y = 40 }, snapAngle(a, .{ .x = 95, .y = 40 }));
    const d = snapAngle(a, .{ .x = 140, .y = 136 });
    try std.testing.expectEqual(d.x - a.x, d.y - a.y);
}
