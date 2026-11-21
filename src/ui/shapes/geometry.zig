//! Points, rectangles and the image -> canvas transform used by shapes
//! and the editor chrome.

const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
    pub fn normalized(self: Rect) Rect {
        var r = self;
        if (r.w < 0) {
            r.x += r.w;
            r.w = -r.w;
        }
        if (r.h < 0) {
            r.y += r.h;
            r.h = -r.h;
        }
        return r;
    }
    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
    pub fn fromCorners(a: Point, b: Point) Rect {
        return (Rect{ .x = a.x, .y = a.y, .w = b.x - a.x, .h = b.y - a.y }).normalized();
    }
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    /// Bounding box of both; an empty rect is ignored.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.right(), b.right());
        const y1 = @max(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    pub fn expand(self: Rect, d: i32) Rect {
        return .{ .x = self.x - d, .y = self.y - d, .w = self.w + 2 * d, .h = self.h + 2 * d };
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

/// Maps shape (image) coordinates onto a canvas: c = p * scale + o.
pub const Xform = struct {
    scale: f64 = 1.0,
    ox: f64 = 0,
    oy: f64 = 0,

    pub fn fx(self: Xform, x: i32) f64 {
        return @as(f64, @floatFromInt(x)) * self.scale + self.ox;
    }
    pub fn fy(self: Xform, y: i32) f64 {
        return @as(f64, @floatFromInt(y)) * self.scale + self.oy;
    }
    pub fn pt(self: Xform, p: Point) Point {
        return .{ .x = @intFromFloat(@round(self.fx(p.x))), .y = @intFromFloat(@round(self.fy(p.y))) };
    }
    pub fn rect(self: Xform, r: Rect) Rect {
        const x0: i32 = @intFromFloat(@round(self.fx(r.x)));
        const y0: i32 = @intFromFloat(@round(self.fy(r.y)));
        const x1: i32 = @intFromFloat(@round(self.fx(r.x + r.w)));
        const y1: i32 = @intFromFloat(@round(self.fy(r.y + r.h)));
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

test "rect normalization" {
    const r = (Rect{ .x = 100, .y = 50, .w = -30, .h = -20 }).normalized();
    try std.testing.expectEqual(@as(i32, 70), r.x);
    try std.testing.expectEqual(@as(i32, 30), r.y);
    try std.testing.expectEqual(@as(i32, 30), r.w);
    try std.testing.expectEqual(@as(i32, 20), r.h);
    try std.testing.expect(r.contains(70, 30));
    try std.testing.expect(!r.contains(100, 50));
}

test "rect intersect and unite" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = -5, .w = 10, .h = 10 };
    const i = Rect.intersect(a, b).?;
    try std.testing.expect(i.eql(.{ .x = 5, .y = 0, .w = 5, .h = 5 }));
    try std.testing.expect(Rect.unite(a, b).eql(.{ .x = 0, .y = -5, .w = 15, .h = 15 }));
    try std.testing.expect(Rect.unite(Rect.empty, b).eql(b));
    try std.testing.expectEqual(@as(?Rect, null), Rect.intersect(a, .{ .x = 10, .y = 0, .w = 5, .h = 5 }));
}
