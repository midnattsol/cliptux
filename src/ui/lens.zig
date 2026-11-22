//! A magnifying lens: the pixels around one pixel of a picture, each
//! drawn as a `cell`-sized square, in a rounded window. It reads over any
//! colour: a faint grid that darkens light pixels and lightens dark ones,
//! a gentle accent band along the centre row and column, a two-tone frame
//! around the centre pixel and a two-tone hairline edge (dark outside,
//! light inside). The capture screen's magnifier and the colour picker
//! draw it (editor_ui/loupe.zig); the shadow and the label are theirs.
//!
//! Stable API:
//!   Pixels                the picture (0xAARRGGBB rows), `at` outside it
//!   Lens                  where: the rect on screen, the full size (the
//!                         rect is smaller while it scales in), radius,
//!                         cell, the centre pixel
//!   draw(cv, lens, pixels, accent)
//!   grid_min_cell         no grid below this cell size (physical px)

const std = @import("std");
const render = @import("../gfx/render.zig");
const shapes = @import("shapes.zig");

const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;

/// Cells smaller than this (physical px) get no grid: it would hide them.
pub const grid_min_cell = 6;
/// beyond the picture's edges
const outside: u32 = 0xFF161618;
/// how much of the accent tints the centre row and column, of 256
const band_k = 40;
/// how far grid lines move toward black (light pixels) or white, of 256
const grid_dark_k = 22;
const grid_light_k = 26;
/// the centre pixel's frame: light inside, dark around it
const mark_inner: u32 = 0xFFFFFFFF;
const mark_outer: u32 = 0xD9000000;
/// the edge: a dark line around the lens, a light one just inside it
pub const edge_outer: u32 = 0x59000000;
pub const edge_inner: u32 = 0x33FFFFFF;

pub const Pixels = struct {
    px: []const u32,
    w: usize,
    h: usize,

    /// Pixel (x, y), opaque; a dark grey outside the picture.
    pub fn at(self: Pixels, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return outside;
        return self.px[@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))] | 0xFF000000;
    }
};

pub const Lens = struct {
    /// on screen; `size` square when fully open
    rect: Rect,
    size: i32,
    radius: f64,
    cell: i32,
    /// the picture's pixel in the middle
    centre: Point,

    /// Where the centre cell starts, in lens coordinates (both axes).
    fn origin(self: Lens) i32 {
        return @divFloor(self.size - self.cell, 2);
    }
};

/// The lens and its edge (the edge reaches one pixel past `lens.rect`).
pub fn draw(cv: *Canvas, lens: Lens, pixels: Pixels, accent: u32) void {
    const r = lens.rect;
    if (r.w <= 0 or r.h <= 0 or lens.size <= 0 or lens.cell <= 0) return;
    const clip = Rect.intersect(r, .{ .x = 0, .y = 0, .w = cv.w, .h = cv.h }) orelse return;
    var y = clip.y;
    while (y < clip.bottom()) : (y += 1) {
        const v = @divFloor((y - r.y) * lens.size, r.h);
        var x = clip.x;
        while (x < clip.right()) : (x += 1) {
            const u = @divFloor((x - r.x) * lens.size, r.w);
            const c = cellColor(lens, pixels, accent, u, v);
            const cov = cornerCoverage(r, lens.radius, x, y);
            const i: usize = @intCast(y * cv.w + x);
            cv.px[i] = if (cov >= 1) c else Canvas.blendPixel(cv.px[i], (c & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(cov * 255))) << 24));
        }
    }
    shapes.roundRectRing(cv, r.expand(1), lens.radius + 1, 1, edge_outer);
    shapes.roundRectRing(cv, r, lens.radius, 1, edge_inner);
}

/// What lens point (u, v) shows: the magnified pixel, its grid line, the
/// band, or the centre pixel's frame.
fn cellColor(lens: Lens, pixels: Pixels, accent: u32, u: i32, v: i32) u32 {
    const o = lens.origin();
    const cell = lens.cell;
    const dx = @divFloor(u - o, cell);
    const dy = @divFloor(v - o, cell);
    // the centre pixel's frame: one light pixel around it, a dark one
    // around that
    const ring = @max(ringDist(u - o, cell), ringDist(v - o, cell));
    if (ring == 1) return mark_inner;
    var c = pixels.at(lens.centre.x + dx, lens.centre.y + dy);
    if (ring == 2) return blendOpaque(c, mark_outer);
    if (cell >= grid_min_cell and (@mod(u - o, cell) == 0 or @mod(v - o, cell) == 0)) c = gridTint(c);
    if ((dx == 0) != (dy == 0)) c = mixRgb(c, accent, band_k);
    return c;
}

/// How far outside the centre cell [0, cell) the offset `d` lies along
/// one axis (0 inside it).
fn ringDist(d: i32, cell: i32) i32 {
    if (d < 0) return -d;
    if (d >= cell) return d - cell + 1;
    return 0;
}

/// A grid line over `c`: a touch darker on light pixels, lighter on dark.
fn gridTint(c: u32) u32 {
    const l = ((c >> 16) & 0xFF) * 299 + ((c >> 8) & 0xFF) * 587 + (c & 0xFF) * 114;
    return if (l > 140 * 1000) mixRgb(c, 0xFF000000, grid_dark_k) else mixRgb(c, 0xFFFFFFFF, grid_light_k);
}

/// `a` moved `k`/256 of the way to `b`, opaque.
fn mixRgb(a: u32, b: u32, k: u32) u32 {
    const rb = ((a & 0xFF00FF) * (256 - k) + (b & 0xFF00FF) * k) >> 8;
    const g = ((a & 0x00FF00) * (256 - k) + (b & 0x00FF00) * k) >> 8;
    return 0xFF000000 | (rb & 0xFF00FF) | (g & 0x00FF00);
}

/// `src` (with its alpha) over the opaque `dst`.
fn blendOpaque(dst: u32, src: u32) u32 {
    return Canvas.blendPixel(dst, src) | 0xFF000000;
}

/// Coverage of pixel (x, y) by the rounded rect `r` (1 away from the
/// corners).
fn cornerCoverage(r: Rect, radius: f64, x: i32, y: i32) f64 {
    const rad: i32 = @intFromFloat(@ceil(radius));
    const in_x = x >= r.x + rad and x < r.right() - rad;
    const in_y = y >= r.y + rad and y < r.bottom() - rad;
    if (in_x or in_y) return 1;
    const fx = @as(f64, @floatFromInt(x)) + 0.5;
    const fy = @as(f64, @floatFromInt(y)) + 0.5;
    const cx = if (x < r.x + rad) @as(f64, @floatFromInt(r.x)) + radius else @as(f64, @floatFromInt(r.right())) - radius;
    const cy = if (y < r.y + rad) @as(f64, @floatFromInt(r.y)) + radius else @as(f64, @floatFromInt(r.bottom())) - radius;
    const d = @sqrt((fx - cx) * (fx - cx) + (fy - cy) * (fy - cy)) - radius;
    return std.math.clamp(0.5 - d, 0, 1);
}

test "the centre pixel lands in the middle, framed light then dark" {
    var pic: [9]u32 = @splat(0xFF336699);
    pic[4] = 0xFFFF0000;
    var px: [64 * 64]u32 = @splat(0xFF000000);
    var cv = Canvas.init(&px, 64, 64);
    const lens: Lens = .{ .rect = .{ .x = 4, .y = 4, .w = 50, .h = 50 }, .size = 50, .radius = 8, .cell = 10, .centre = .{ .x = 1, .y = 1 } };
    draw(&cv, lens, .{ .px = &pic, .w = 3, .h = 3 }, 0xFF0A84FF);
    // the centre cell spans lens 20..29: buffer 24..33
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[28 * 64 + 28]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[28 * 64 + 23]);
    try std.testing.expect(px[28 * 64 + 22] & 0xFFFFFF < 0x202020);
    // beyond the picture: dark grey; the very corner stays the canvas'
    try std.testing.expectEqual(outside, px[12 * 64 + 12]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[4 * 64 + 4]);
}

test "the grid darkens light pixels and lightens dark ones" {
    try std.testing.expect(gridTint(0xFFFFFFFF) & 0xFF < 0xFF);
    try std.testing.expect(gridTint(0xFF000000) & 0xFF > 0);
}

test "the lens shrinks into a smaller rect (scaling in) without gaps" {
    var pic: [1]u32 = .{0xFF00FF00};
    var px: [40 * 40]u32 = @splat(0xFF000000);
    var cv = Canvas.init(&px, 40, 40);
    const lens: Lens = .{ .rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 }, .size = 40, .radius = 4, .cell = 40, .centre = .{ .x = 0, .y = 0 } };
    draw(&cv, lens, .{ .px = &pic, .w = 1, .h = 1 }, 0xFF0A84FF);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[15 * 40 + 15] | 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[35 * 40 + 35]);
}
