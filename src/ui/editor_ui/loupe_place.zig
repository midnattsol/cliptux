//! Where the magnifier goes: the lens with its label below (when it has
//! one), diagonally off the point it looks at, never over it: toward the
//! inside of the selection being adjusted (the side it does not grow
//! to), else below right; then the other ways round, the first that fits
//! on the surface and covers none of the chrome to keep clear (the
//! toolbar, the mode strip, the size pill). Pure geometry, buffer pixels.

const std = @import("std");
const shapes_mod = @import("../shapes.zig");

const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

pub const Size = struct {
    /// the lens (square)
    lens: i32,
    /// the label under it, `gap` below (0 x 0: none)
    label_w: i32 = 0,
    label_h: i32 = 0,
    gap: i32 = 0,
    /// from the pointer to the nearest corner, each axis
    off: i32,
    /// kept from the surface's edges
    margin: i32,
};

pub const Placement = struct {
    lens: Rect,
    label: Rect,
    /// the lens corner nearest the point (it grows from there)
    anchor: Point,

    /// The lens and its label.
    pub fn box(self: Placement) Rect {
        return if (self.label.isEmpty()) self.lens else Rect.unite(self.lens, self.label);
    }
};

/// Which way from the point the magnifier sits.
pub const Corner = struct {
    right: bool = true,
    below: bool = true,

    /// Toward `centre` (the selection's middle) from `p`: the selection's
    /// inside, away from where it grows. Below right without one, and
    /// along an axis where they line up.
    pub fn toward(p: Point, centre: ?Point) Corner {
        const c = centre orelse return .{};
        return .{ .right = c.x >= p.x, .below = c.y >= p.y };
    }
};

/// The placement for a point `p` on a surface `bounds`, `prefer`'s way
/// first, clear of every rect in `avoid` where it can be.
pub fn place(p: Point, prefer: Corner, s: Size, bounds: Rect, avoid: []const Rect) Placement {
    const inner = bounds.expand(-s.margin);
    const order = [4]Corner{
        prefer,
        .{ .right = !prefer.right, .below = prefer.below },
        .{ .right = prefer.right, .below = !prefer.below },
        .{ .right = !prefer.right, .below = !prefer.below },
    };
    var fits: ?Placement = null;
    for (order) |c| {
        const pl = at(p, s, c);
        const box = pl.box();
        if (!within(box, inner)) continue;
        if (fits == null) fits = pl;
        if (!hitsAny(box, avoid)) return pl;
    }
    return fits orelse clamped(at(p, s, prefer), inner);
}

fn at(p: Point, s: Size, c: Corner) Placement {
    const gw = @max(s.lens, s.label_w);
    const gh = s.lens + s.gap + s.label_h;
    const gx = if (c.right) p.x + s.off else p.x - s.off - gw;
    const gy = if (c.below) p.y + s.off else p.y - s.off - gh;
    const lens: Rect = .{ .x = gx + @divTrunc(gw - s.lens, 2), .y = gy, .w = s.lens, .h = s.lens };
    const label: Rect = .{ .x = gx + @divTrunc(gw - s.label_w, 2), .y = gy + s.lens + s.gap, .w = s.label_w, .h = s.label_h };
    return .{
        .lens = lens,
        .label = label,
        .anchor = .{ .x = if (c.right) lens.x else lens.right(), .y = if (c.below) lens.y else lens.bottom() },
    };
}

fn within(r: Rect, b: Rect) bool {
    return r.x >= b.x and r.y >= b.y and r.right() <= b.right() and r.bottom() <= b.bottom();
}

fn hitsAny(r: Rect, avoid: []const Rect) bool {
    for (avoid) |a| {
        if (!a.isEmpty() and Rect.intersect(r, a) != null) return true;
    }
    return false;
}

/// Nothing fits (a tiny surface): moved inside as far as it goes.
fn clamped(pl: Placement, b: Rect) Placement {
    const box = pl.box();
    const dx = std.math.clamp(box.x, b.x, @max(b.x, b.right() - box.w)) - box.x;
    const dy = std.math.clamp(box.y, b.y, @max(b.y, b.bottom() - box.h)) - box.y;
    var out = pl;
    out.lens.x += dx;
    out.lens.y += dy;
    out.label.x += dx;
    out.label.y += dy;
    out.anchor = .{ .x = pl.anchor.x + dx, .y = pl.anchor.y + dy };
    return out;
}

const test_size: Size = .{ .lens = 100, .label_w = 120, .label_h = 20, .gap = 6, .off = 20, .margin = 4 };
const screen: Rect = .{ .x = 0, .y = 0, .w = 1600, .h = 900 };

test "below right of the pointer, the label centred under the lens" {
    const pl = place(.{ .x = 400, .y = 300 }, .{}, test_size, screen, &.{});
    try std.testing.expectEqual(@as(i32, 430), pl.lens.x);
    try std.testing.expectEqual(@as(i32, 320), pl.lens.y);
    try std.testing.expectEqual(@as(i32, 420), pl.label.x);
    try std.testing.expectEqual(@as(i32, 426), pl.label.y);
    try std.testing.expectEqual(Point{ .x = 430, .y = 320 }, pl.anchor);
}

test "it flips at the edges and stays on the surface" {
    const pl = place(.{ .x = 1590, .y = 890 }, .{}, test_size, screen, &.{});
    try std.testing.expect(pl.lens.right() < 1590 and pl.label.bottom() < 890);
    try std.testing.expectEqual(Point{ .x = pl.lens.right(), .y = pl.lens.bottom() }, pl.anchor);
}

test "it keeps clear of the chrome" {
    const strip: Rect = .{ .x = 300, .y = 300, .w = 400, .h = 200 };
    const pl = place(.{ .x = 290, .y = 290 }, .{}, test_size, screen, &.{strip});
    try std.testing.expect(Rect.intersect(pl.box(), strip) == null);
}

test "a surface too small for it: as far inside as it goes" {
    const pl = place(.{ .x = 50, .y = 50 }, .{}, test_size, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, &.{});
    try std.testing.expectEqual(@as(i32, 4), pl.label.x);
}

test "toward the selection's inside, never over the point it looks at" {
    // the bottom-right corner dragged: the selection is up left of it
    const p: Point = .{ .x = 800, .y = 500 };
    const c = Corner.toward(p, .{ .x = 600, .y = 400 });
    try std.testing.expect(!c.right and !c.below);
    const lens_only: Size = .{ .lens = 110, .off = 16, .margin = 4 };
    const pl = place(p, c, lens_only, screen, &.{});
    try std.testing.expect(pl.lens.right() < p.x and pl.lens.bottom() < p.y);
    try std.testing.expect(pl.label.isEmpty() and pl.box().eql(pl.lens));
    // no room up left: the other way round, still off the point
    const q: Point = .{ .x = 60, .y = 60 };
    const ql = place(q, Corner.toward(q, .{ .x = 0, .y = 0 }), lens_only, screen, &.{});
    try std.testing.expect(!ql.lens.contains(q.x, q.y) and ql.lens.x > q.x);
    try std.testing.expect(Corner.toward(p, null).right and Corner.toward(p, null).below);
}
