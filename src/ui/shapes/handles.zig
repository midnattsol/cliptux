//! Selection handles: their positions, hit resolution, resizing and
//! nudging, and the point of one the magnifier looks at.

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

/// The edges handle `h` moves, per axis: -1 the left (top), 1 the right
/// (bottom), 0 neither.
fn sides(h: u3) [2]i2 {
    return switch (h) {
        0 => .{ -1, -1 },
        1 => .{ 0, -1 },
        2 => .{ 1, -1 },
        3 => .{ 1, 0 },
        4 => .{ 1, 1 },
        5 => .{ 0, 1 },
        6 => .{ -1, 1 },
        7 => .{ -1, 0 },
    };
}

/// Where handle `h` of `s` (as a drag leaves it) is on `s.normalized()`:
/// dragged past the opposite edge, it is that side's handle now.
pub fn normalizedHandle(s: Rect, h: u3) u3 {
    var sd = sides(h);
    if (s.w < 0) sd[0] = -sd[0];
    if (s.h < 0) sd[1] = -sd[1];
    for (0..8) |i| {
        if (std.meta.eql(sides(@intCast(i)), sd)) return @intCast(i);
    }
    unreachable;
}

/// `s` (normalized) with handle `h`'s edges moved by (`dx`, `dy`): an
/// edge's handle moves along its own axis only. It stays at least 1x1
/// and inside `bounds`.
pub fn nudgeHandle(s: Rect, h: u3, dx: i32, dy: i32, bounds: Rect) Rect {
    const sd = sides(h);
    const x = nudgeSpan(s.x, s.right(), sd[0], dx, bounds.x, bounds.right());
    const y = nudgeSpan(s.y, s.bottom(), sd[1], dy, bounds.y, bounds.bottom());
    return .{ .x = x[0], .y = y[0], .w = x[1] - x[0], .h = y[1] - y[0] };
}

/// [`a`, `b`) with its `side` end moved by `d`, within [`lo`, `hi`) and
/// at least 1 long.
fn nudgeSpan(a: i32, b: i32, side: i2, d: i32, lo: i32, hi: i32) [2]i32 {
    return switch (side) {
        -1 => .{ std.math.clamp(a + d, lo, @max(lo, b - 1)), b },
        1 => .{ a, std.math.clamp(b + d, @min(hi, a + 1), hi) },
        else => .{ a, b },
    };
}

/// Where handle `h` of `s` (normalized or not, as a drag leaves it) is
/// nearest `p`: its corner, or the point of its edge across from `p`.
pub fn handleFocus(s: Rect, h: u3, p: Point) Point {
    const at = handlePoints(s)[h];
    const sd = sides(h);
    return .{
        .x = if (sd[0] != 0) at.x else alongSpan(p.x, s.x, s.right()),
        .y = if (sd[1] != 0) at.y else alongSpan(p.y, s.y, s.bottom()),
    };
}

/// `v` within the pixels of the span between `a` and `b` (either way).
fn alongSpan(v: i32, a: i32, b: i32) i32 {
    const lo = @min(a, b);
    return std.math.clamp(v, lo, @max(lo, @max(a, b) - 1));
}

/// The corner handle of `s` nearest `p`.
pub fn nearestCorner(s: Rect, p: Point) u3 {
    const pts = handlePoints(s);
    var best: u3 = 0;
    var best_d: i64 = std.math.maxInt(i64);
    for ([_]u3{ 0, 2, 4, 6 }) |h| {
        const dx: i64 = pts[h].x - p.x;
        const dy: i64 = pts[h].y - p.y;
        if (dx * dx + dy * dy < best_d) {
            best_d = dx * dx + dy * dy;
            best = h;
        }
    }
    return best;
}

test "nudging a handle moves its edges, kept 1x1 and inside" {
    const s = Rect{ .x = 10, .y = 10, .w = 100, .h = 50 };
    const b = Rect{ .x = 0, .y = 0, .w = 200, .h = 100 };
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 101, .h = 50 }, nudgeHandle(s, 3, 1, 1, b));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 110, .h = 60 }, nudgeHandle(s, 0, -10, -10, b));
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 100, .h = 40 }, nudgeHandle(s, 5, 7, -10, b));
    // never past the opposite edge, never off the picture
    try std.testing.expectEqual(Rect{ .x = 109, .y = 10, .w = 1, .h = 50 }, nudgeHandle(s, 7, 500, 0, b));
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 190, .h = 90 }, nudgeHandle(s, 4, 500, 500, b));
}

test "a handle's focus: its corner, or its edge across from the pointer" {
    const s = Rect{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try std.testing.expectEqual(Point{ .x = 110, .y = 60 }, handleFocus(s, 4, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(Point{ .x = 110, .y = 30 }, handleFocus(s, 3, .{ .x = 140, .y = 30 }));
    try std.testing.expectEqual(Point{ .x = 110, .y = 59 }, handleFocus(s, 3, .{ .x = 140, .y = 90 }));
    // dragged past the opposite edge (not normalized yet)
    const flipped = Rect{ .x = 10, .y = 10, .w = -30, .h = 50 };
    try std.testing.expectEqual(Point{ .x = -20, .y = 10 }, handleFocus(flipped, 3, .{ .x = -20, .y = 0 }));
    try std.testing.expectEqual(@as(u3, 7), normalizedHandle(flipped, 3));
    try std.testing.expectEqual(@as(u3, 2), normalizedHandle(.{ .x = 0, .y = 0, .w = -5, .h = 5 }, 0));
    try std.testing.expectEqual(@as(u3, 2), normalizedHandle(.{ .x = 0, .y = 0, .w = -5, .h = -5 }, 6));
    try std.testing.expectEqual(@as(u3, 5), normalizedHandle(s, 5));
    try std.testing.expectEqual(@as(u3, 2), nearestCorner(s, .{ .x = 100, .y = 0 }));
    try std.testing.expectEqual(@as(u3, 6), nearestCorner(s, .{ .x = 0, .y = 70 }));
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
