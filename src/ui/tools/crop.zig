//! Crop: cut the picture itself down to a rectangle, after the capture.
//! The annotations move with the pixels under them; beautify frames what
//! is left. Undoable: the crop is a marked change in the document's undo
//! history (doc.Document.checkpointMarked) and this store keeps the
//! picture before and after each crop so undo and redo can swap it.

const std = @import("std");
const png = @import("../../gfx/png.zig");
const shapes = @import("../shapes.zig");

const Rect = shapes.Rect;
const Point = shapes.Point;
const Shape = shapes.Shape;

pub const Aspect = @import("mod.zig").Aspect;

/// Width over height, null for free.
pub fn ratio(a: Aspect) ?f64 {
    return switch (a) {
        .free => null,
        .square => 1,
        .wide => 16.0 / 9.0,
        .classic => 4.0 / 3.0,
    };
}

/// The pixels of `img` inside `r` (which lies inside it).
pub fn cropImage(alloc: std.mem.Allocator, img: *const png.Image, r: Rect) !png.Image {
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    const px = try alloc.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| {
        const src = (@as(usize, @intCast(r.y)) + y) * img.width + @as(usize, @intCast(r.x));
        @memcpy(px[y * w ..][0..w], img.pixels[src..][0..w]);
    }
    return .{ .width = w, .height = h, .pixels = px };
}

/// Shapes keep their place on the picture when its corner moves to `r`'s.
pub fn moveShapes(list: []Shape, r: Rect) void {
    for (list) |*s| s.translate(-r.x, -r.y);
}

/// A box dragged from `anchor` to `p` with the aspect `k` (w / h): the
/// larger of the two sides wins, the other follows.
pub fn fromCorner(anchor: Point, p: Point, k: f64) Rect {
    const dx: f64 = @floatFromInt(p.x - anchor.x);
    const dy: f64 = @floatFromInt(p.y - anchor.y);
    var w = @abs(dx);
    var h = @abs(dy);
    if (w > h * k) h = w / k else w = h * k;
    const q = Point{
        .x = anchor.x + @as(i32, @intFromFloat(@round(if (dx < 0) -w else w))),
        .y = anchor.y + @as(i32, @intFromFloat(@round(if (dy < 0) -h else h))),
    };
    return Rect.fromCorners(anchor, q);
}

/// `r`, resized with handle `handle` from `orig`, kept at aspect `k`: a
/// corner pivots on the opposite one, an edge keeps the other axis
/// centred.
pub fn constrainResize(orig: Rect, handle: u3, r: Rect, k: f64) Rect {
    const n = r.normalized();
    switch (handle) {
        1, 5 => {
            const w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(n.h)) * k));
            return .{ .x = orig.x + @divTrunc(orig.w - w, 2), .y = n.y, .w = w, .h = n.h };
        },
        3, 7 => {
            const h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(n.w)) / k));
            return .{ .x = n.x, .y = orig.y + @divTrunc(orig.h - h, 2), .w = n.w, .h = h };
        },
        else => {
            // the corner opposite the handle stays
            const right = handle == 0 or handle == 6;
            const below = handle == 0 or handle == 2;
            const anchor = Point{ .x = if (right) orig.right() else orig.x, .y = if (below) orig.bottom() else orig.y };
            const p = Point{ .x = if (right) n.x else n.right(), .y = if (below) n.y else n.bottom() };
            return fromCorner(anchor, p, k);
        },
    }
}

/// The largest rectangle of aspect `k` centred in `r`.
pub fn fitInside(r: Rect, k: f64) Rect {
    const fw: f64 = @floatFromInt(r.w);
    const fh: f64 = @floatFromInt(r.h);
    const w: i32 = @intFromFloat(@round(if (fw > fh * k) fh * k else fw));
    const h: i32 = @intFromFloat(@round(if (fw > fh * k) fh else fw / k));
    return .{ .x = r.x + @divTrunc(r.w - w, 2), .y = r.y + @divTrunc(r.h - h, 2), .w = w, .h = h };
}

/// The pictures of every crop this session, by the mark of its undo step.
pub const Store = struct {
    pub const Entry = struct {
        mark: u32,
        /// the crop rectangle, in `before`'s pixels
        rect: Rect,
        before: *const png.Image,
        after: *const png.Image,
    };

    entries: std.ArrayList(Entry) = .empty,
    /// pictures this store owns (crops; also opened files, see open.zig)
    owned: std.ArrayList(*png.Image) = .empty,
    next_mark: u32 = 1,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        for (self.owned.items) |im| {
            im.deinit(alloc);
            alloc.destroy(im);
        }
        self.owned.deinit(alloc);
        self.entries.deinit(alloc);
    }

    /// Keep `img` (taking it) alive until the editor ends.
    pub fn adopt(self: *Store, alloc: std.mem.Allocator, img: png.Image) !*png.Image {
        var im = img;
        errdefer im.deinit(alloc);
        const p = try alloc.create(png.Image);
        errdefer alloc.destroy(p);
        try self.owned.append(alloc, p);
        p.* = im;
        return p;
    }

    pub fn find(self: *const Store, mark: u32) ?Entry {
        for (self.entries.items) |e| if (e.mark == mark) return e;
        return null;
    }
};

const testing = std.testing;

test "cropping keeps the annotations on their pixels" {
    const alloc = testing.allocator;
    var px: [8 * 6]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i);
    const img: png.Image = .{ .width = 8, .height = 6, .pixels = &px };
    const r = Rect{ .x = 2, .y = 1, .w = 5, .h = 4 };
    var out = try cropImage(alloc, &img, r);
    defer out.deinit(alloc);
    try testing.expectEqual(@as(u32, 5), out.width);
    try testing.expectEqual(@as(u32, 4), out.height);
    try testing.expectEqual(px[1 * 8 + 2], out.pixels[0]);
    try testing.expectEqual(px[4 * 8 + 6], out.pixels[3 * 5 + 4]);
    // an arrow pointing at pixel (6, 4) still points at it
    var list = [_]Shape{
        .{ .tool = .arrow, .color = 1, .thickness = 2, .p0 = .{ .x = 3, .y = 2 }, .p1 = .{ .x = 6, .y = 4 } },
        .{ .tool = .counter, .color = 1, .thickness = 2, .p0 = .{ .x = 0, .y = 0 } },
    };
    moveShapes(&list, r);
    try testing.expectEqual(Point{ .x = 4, .y = 3 }, list[0].p1);
    try testing.expectEqual(px[4 * 8 + 6], out.pixels[@intCast(list[0].p1.y * 5 + list[0].p1.x)]);
    // one outside the crop moves outside the picture (and is cut off)
    try testing.expectEqual(Point{ .x = -2, .y = -1 }, list[1].p0);
}

test "aspect ratios from a corner, an edge and a fit" {
    // 16:9 from a corner: the wider drag wins
    const a = fromCorner(.{ .x = 100, .y = 100 }, .{ .x = 260, .y = 120 }, 16.0 / 9.0);
    try testing.expect(a.eql(.{ .x = 100, .y = 100, .w = 160, .h = 90 }));
    // dragging up-left
    const b = fromCorner(.{ .x = 100, .y = 100 }, .{ .x = 40, .y = 0 }, 1);
    try testing.expect(b.eql(.{ .x = 0, .y = 0, .w = 100, .h = 100 }));
    // the south edge of a square keeps it square, centred
    const orig = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const c = constrainResize(orig, 5, .{ .x = 0, .y = 0, .w = 100, .h = 140 }, 1);
    try testing.expect(c.eql(.{ .x = -20, .y = 0, .w = 140, .h = 140 }));
    // the north-west corner pivots on the south-east one
    const d = constrainResize(orig, 0, .{ .x = 40, .y = 10, .w = 60, .h = 90 }, 1);
    try testing.expect(d.eql(.{ .x = 10, .y = 10, .w = 90, .h = 90 }));
    // 4:3 inside a 1600x900 picture
    const e = fitInside(.{ .x = 0, .y = 0, .w = 1600, .h = 900 }, 4.0 / 3.0);
    try testing.expect(e.eql(.{ .x = 200, .y = 0, .w = 1200, .h = 900 }));
    try testing.expectEqual(@as(?f64, null), ratio(.free));
}

test "the store owns what it adopts" {
    const alloc = testing.allocator;
    var st: Store = .{};
    defer st.deinit(alloc);
    const px = try alloc.alloc(u32, 4);
    const im = try st.adopt(alloc, .{ .width = 2, .height = 2, .pixels = px });
    try st.entries.append(alloc, .{ .mark = 3, .rect = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .before = im, .after = im });
    try testing.expect(st.find(3) != null);
    try testing.expect(st.find(4) == null);
}
