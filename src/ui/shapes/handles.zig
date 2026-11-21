//! Selection handles: their positions, hit resolution and resizing.

const std = @import("std");
const geometry = @import("geometry.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;

pub fn handlePoints(s: Rect) [8]Point {
    const mx = s.x + @divTrunc(s.w, 2);
    const my = s.y + @divTrunc(s.h, 2);
    return .{
        .{ .x = s.x, .y = s.y }, // 0 nw
        .{ .x = mx, .y = s.y }, // 1 n
        .{ .x = s.x + s.w, .y = s.y }, // 2 ne
        .{ .x = s.x + s.w, .y = my }, // 3 e
        .{ .x = s.x + s.w, .y = s.y + s.h }, // 4 se
        .{ .x = mx, .y = s.y + s.h }, // 5 s
        .{ .x = s.x, .y = s.y + s.h }, // 6 sw
        .{ .x = s.x, .y = my }, // 7 w
    };
}

/// Handle of `s` under `m` within `radius`. On a selection too small to
/// hold the handles and still be grabbed, its inside always moves it and
/// the handles answer only from the outside.
pub fn handleAt(s: Rect, m: Point, radius: i32) ?u3 {
    const small = s.w < 4 * radius or s.h < 4 * radius;
    if (small and s.contains(m.x, m.y)) return null;
    var best: ?u3 = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (handlePoints(s), 0..) |p, i| {
        // on small rects the edge handles crowd the corners; skip them
        if (small and i % 2 == 1) continue;
        const d = @max(@abs(m.x - p.x), @abs(m.y - p.y));
        if (d <= radius and d < best_d) {
            best = @intCast(i);
            best_d = d;
        }
    }
    return best;
}

pub fn resizeWithHandle(orig: Rect, handle: u3, m: Point) Rect {
    var x0 = orig.x;
    var y0 = orig.y;
    var x1 = orig.x + orig.w;
    var y1 = orig.y + orig.h;
    switch (handle) {
        0 => {
            x0 = m.x;
            y0 = m.y;
        },
        1 => y0 = m.y,
        2 => {
            x1 = m.x;
            y0 = m.y;
        },
        3 => x1 = m.x,
        4 => {
            x1 = m.x;
            y1 = m.y;
        },
        5 => y1 = m.y,
        6 => {
            x0 = m.x;
            y1 = m.y;
        },
        7 => x0 = m.x,
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "selection handle resolution" {
    const s = Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(?u3, 0), handleAt(s, .{ .x = 10, .y = 10 }, 11)); // nw
    try std.testing.expectEqual(@as(?u3, 4), handleAt(s, .{ .x = 110, .y = 110 }, 11)); // se
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 60, .y = 60 }, 11)); // center
    const grown = resizeWithHandle(s, 4, .{ .x = 150, .y = 130 });
    try std.testing.expectEqual(@as(i32, 140), grown.w);
    try std.testing.expectEqual(@as(i32, 120), grown.h);
}

test "handles scale with radius and never block moving a small selection" {
    const s = Rect{ .x = 100, .y = 100, .w = 20, .h = 16 };
    // inside a small selection: always a move, even right at a corner
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 101, .y = 101 }, 11));
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 110, .y = 108 }, 11));
    // just outside a corner: that corner
    try std.testing.expectEqual(@as(?u3, 4), handleAt(s, .{ .x = 124, .y = 119 }, 11));
    try std.testing.expectEqual(@as(?u3, 0), handleAt(s, .{ .x = 96, .y = 97 }, 11));
    // a bigger radius (HiDPI) reaches further
    const big = Rect{ .x = 0, .y = 0, .w = 400, .h = 400 };
    try std.testing.expectEqual(@as(?u3, null), handleAt(big, .{ .x = 18, .y = 18 }, 11));
    try std.testing.expectEqual(@as(?u3, 0), handleAt(big, .{ .x = 18, .y = 18 }, 22));
}
