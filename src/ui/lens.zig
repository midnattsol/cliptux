//! A magnifying lens: the pixels around one pixel of a picture, each
//! drawn as a `cell`-sized square, in a rounded window. It reads over any
//! colour: the target pixel framed by a light line with a dark hairline
//! around it, a faint grid at high zooms only (it darkens light pixels
//! and lightens dark ones), and a two-tone hairline edge (dark outside,
//! light inside) for the shadow its owner draws to sit on. With a
//! selection, what lies outside it is dimmed as on the overlay and its
//! edge drawn on the outside pixels, so the cut's exact pixel shows. The
//! capture screen's magnifier and the colour picker draw it
//! (editor_ui/loupe.zig); the shadow and the label are theirs.
//!
//! Stable API:
//!   Pixels                the picture (0xAARRGGBB rows), `at` outside it
//!   Lens                  where: the rect on screen, the full size (the
//!                         rect is smaller while it scales in), radius,
//!                         cell, the centre pixel, grid, target, selection
//!   Selection             the selection inside it: rect, dim, edge colours
//!   draw(cv, lens, pixels)

const std = @import("std");
const render = @import("../gfx/render.zig");
const shapes = @import("shapes.zig");
const dim = @import("dim.zig");

const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;

/// beyond the picture's edges
const outside: u32 = 0xFF161618;
/// how far grid lines move toward black (light pixels) or white, of 256
const grid_dark_k = 18;
const grid_light_k = 22;
/// the target pixel's frame: light inside, dark around it
const mark_inner: u32 = 0xFFFFFFFF;
const mark_outer: u32 = 0xB3000000;
/// the edge: a faint dark line around the lens, a light one just inside
/// it (the shadow does the rest)
pub const edge_outer: u32 = 0x38000000;
pub const edge_inner: u32 = 0x2EFFFFFF;

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

/// A selection seen through the lens.
pub const Selection = struct {
    /// image px, normalized
    rect: Rect,
    /// the overlay's dim outside it (dim.zig: kept, of 256)
    keep: u32,
    /// its edge's two tones (theme.sel_edge, sel_edge_outer)
    light: u32,
    dark: u32,
};

pub const Lens = struct {
    /// on screen; `size` square when fully open
    rect: Rect,
    size: i32,
    radius: f64,
    cell: i32,
    /// the picture's pixel in the middle
    centre: Point,
    /// the light part of the target's frame and of the selection's edge,
    /// physical px (one logical px)
    mark: i32 = 1,
    /// a line between the pixels
    grid: bool = false,
    /// frame the centre pixel
    target: bool = true,
    selection: ?Selection = null,

    /// Where the centre cell starts, in lens coordinates (both axes).
    fn origin(self: Lens) i32 {
        return @divFloor(self.size - self.cell, 2);
    }
};

/// The lens and its edge (the edge reaches one pixel past `lens.rect`).
pub fn draw(cv: *Canvas, lens: Lens, pixels: Pixels) void {
    const r = lens.rect;
    if (r.w <= 0 or r.h <= 0 or lens.size <= 0 or lens.cell <= 0) return;
    const clip = Rect.intersect(r, .{ .x = 0, .y = 0, .w = cv.w, .h = cv.h }) orelse return;
    var y = clip.y;
    while (y < clip.bottom()) : (y += 1) {
        const v = @divFloor((y - r.y) * lens.size, r.h);
        var x = clip.x;
        while (x < clip.right()) : (x += 1) {
            const u = @divFloor((x - r.x) * lens.size, r.w);
            const c = cellColor(lens, pixels, u, v);
            const cov = cornerCoverage(r, lens.radius, x, y);
            const i: usize = @intCast(y * cv.w + x);
            cv.px[i] = if (cov >= 1) c else Canvas.blendPixel(cv.px[i], (c & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(cov * 255))) << 24));
        }
    }
    shapes.roundRectRing(cv, r.expand(1), lens.radius + 1, 1, edge_outer);
    shapes.roundRectRing(cv, r, lens.radius, 1, edge_inner);
}

/// What lens point (u, v) shows: the magnified pixel (dimmed outside the
/// selection), the selection's edge, a grid line, or the target's frame.
fn cellColor(lens: Lens, pixels: Pixels, u: i32, v: i32) u32 {
    const o = lens.origin();
    const cell = lens.cell;
    const ring = @max(ringDist(u - o, cell), ringDist(v - o, cell));
    if (lens.target and ring >= 1 and ring <= lens.mark) return mark_inner;
    const p: Point = .{ .x = lens.centre.x + @divFloor(u - o, cell), .y = lens.centre.y + @divFloor(v - o, cell) };
    const fu = @mod(u - o, cell);
    const fv = @mod(v - o, cell);
    var c = pixels.at(p.x, p.y);
    if (lens.grid and (fu == 0 or fv == 0)) c = gridTint(c);
    if (lens.selection) |s| c = selColor(s, c, p, .{ fu, fv }, cell, lens.mark);
    if (lens.target and ring == lens.mark + 1) return blendOpaque(c, mark_outer);
    return c;
}

/// Pixel `p` (colour `c`) seen with selection `s`, at `f` within its
/// cell: inside as it is; outside dimmed, but along a side that touches
/// the selection its edge, `w` light then one dark.
fn selColor(s: Selection, c: u32, p: Point, f: [2]i32, cell: i32, w: i32) u32 {
    const r = s.rect;
    if (r.contains(p.x, p.y)) return c;
    var d: [1]u32 = undefined;
    dim.dimRow(&.{c}, &d, s.keep);
    const near = edgeDist(r, p, f, cell);
    if (near < w) return blendOpaque(d[0], s.light);
    if (near == w) return blendOpaque(d[0], s.dark);
    return d[0];
}

/// How far point `f` of outside pixel `p`'s cell is from the nearest of
/// its sides (or corners) that touch selection `r`; maxInt when none does.
fn edgeDist(r: Rect, p: Point, f: [2]i32, cell: i32) i32 {
    const to_hi = [2]i32{ cell - 1 - f[0], cell - 1 - f[1] };
    var best: i32 = std.math.maxInt(i32);
    var sy: i32 = -1;
    while (sy <= 1) : (sy += 1) {
        var sx: i32 = -1;
        while (sx <= 1) : (sx += 1) {
            if ((sx == 0 and sy == 0) or !r.contains(p.x + sx, p.y + sy)) continue;
            const ax: i32 = if (sx < 0) f[0] else if (sx > 0) to_hi[0] else 0;
            const ay: i32 = if (sy < 0) f[1] else if (sy > 0) to_hi[1] else 0;
            best = @min(best, @max(ax, ay));
        }
    }
    return best;
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
    draw(&cv, lens, .{ .px = &pic, .w = 3, .h = 3 });
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
    draw(&cv, lens, .{ .px = &pic, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), px[15 * 40 + 15] | 0xFF000000);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[35 * 40 + 35]);
}

test "a selection: inside as it is, outside dimmed, its edge on the outside pixels" {
    const pic: [5 * 5]u32 = @splat(0xFF808080);
    var px: [50 * 50]u32 = @splat(0);
    var cv = Canvas.init(&px, 50, 50);
    // pixels 2..4 of the picture are selected; the centre pixel is (2, 2),
    // its cell at 20..29: the selection starts at buffer 20, both ways
    const sel: Selection = .{ .rect = .{ .x = 2, .y = 2, .w = 3, .h = 3 }, .keep = 128, .light = 0xFFFFFFFF, .dark = 0xFF000000 };
    const lens: Lens = .{ .rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 }, .size = 50, .radius = 0, .cell = 10, .centre = .{ .x = 2, .y = 2 }, .target = false, .selection = sel };
    draw(&cv, lens, .{ .px = &pic, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(u32, 0xFF808080), px[25 * 50 + 25]);
    try std.testing.expectEqual(@as(u32, 0xFF808080), px[25 * 50 + 20]);
    // the light line on the last outside column, the dark one before it
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[25 * 50 + 19]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[25 * 50 + 18]);
    try std.testing.expectEqual(@as(u32, 0xFF404040), px[25 * 50 + 14]);
    // the corner wraps around
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[19 * 50 + 19]);
    try std.testing.expectEqual(@as(u32, 0xFF404040), px[5 * 50 + 25]);
}

test "the grid shows only when asked" {
    const pic: [9]u32 = @splat(0xFFFFFFFF);
    var px: [30 * 30]u32 = @splat(0);
    var cv = Canvas.init(&px, 30, 30);
    var lens: Lens = .{ .rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 }, .size = 30, .radius = 0, .cell = 10, .centre = .{ .x = 1, .y = 1 }, .target = false };
    draw(&cv, lens, .{ .px = &pic, .w = 3, .h = 3 });
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[5 * 30 + 10]);
    lens.grid = true;
    draw(&cv, lens, .{ .px = &pic, .w = 3, .h = 3 });
    try std.testing.expect(px[5 * 30 + 10] != 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[5 * 30 + 15]);
}
