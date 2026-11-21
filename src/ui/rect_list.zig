//! Dirty rectangles: what changed since a back buffer was last drawn.

const std = @import("std");
const Rect = @import("shapes.zig").Rect;

/// A small set of dirty rectangles; overflows merge into one bounding box.
pub const RectList = struct {
    items: [64]Rect = undefined,
    len: usize = 0,

    pub fn add(self: *RectList, r: Rect) void {
        if (r.isEmpty()) return;
        if (self.len == self.items.len) {
            var u = self.items[0];
            for (self.items[1..self.len]) |x| u = Rect.unite(u, x);
            self.items[0] = u;
            self.len = 1;
        }
        self.items[self.len] = r;
        self.len += 1;
    }
    pub fn addAll(self: *RectList, other: *const RectList) void {
        for (other.items[0..other.len]) |r| self.add(r);
    }
    pub fn slice(self: *const RectList) []const Rect {
        return self.items[0..self.len];
    }
    pub fn area(self: *const RectList) i64 {
        var a: i64 = 0;
        for (self.slice()) |r| a += @as(i64, r.w) * r.h;
        return a;
    }
};

test "dirty rect list merges on overflow" {
    var l: RectList = .{};
    for (0..70) |i| l.add(.{ .x = @intCast(i), .y = 0, .w = 1, .h = 1 });
    try std.testing.expect(l.len <= 64);
    var u = Rect.empty;
    for (l.slice()) |r| u = Rect.unite(u, r);
    try std.testing.expect(u.eql(.{ .x = 0, .y = 0, .w = 70, .h = 1 }));
    l.add(Rect.empty);
    try std.testing.expect(l.len <= 64);
}
