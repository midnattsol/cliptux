//! Hand-drawn pointer cursors, for compositors that cannot draw the
//! desktop's own (no cursor-shape-v1): a white shape with a black edge,
//! like the Adwaita theme, drawn at any whole scale. Each shape is a
//! union of capsules, rounded boxes and polygons in a 24x24 unit box
//! (one unit per logical pixel), rendered through its signed distance:
//! anti-aliased and outlined in one pass. Black cuts inside a shape
//! (between a fist's fingers) are capsules drawn over the white.

const std = @import("std");
const Cursor = @import("../../api/window.zig").Cursor;

/// logical pixels per side
pub const size = 24;

const V = [2]f32;

const Prim = union(enum) {
    /// a segment widened by `r`
    capsule: struct { a: V, b: V, r: f32 },
    /// a box around `c` with half sides `h` and corners rounded by `r`
    box: struct { c: V, h: V, r: f32 },
    /// a closed polygon, any shape
    poly: []const V,
};

const Art = struct {
    parts: []const Prim,
    cuts: []const Prim = &.{},
    /// the point that clicks, in units
    hot: V = .{ 12, 12 },
    /// turned by this many quarter turns about the centre (an eighth is
    /// half a quarter: 0.5)
    turn: f32 = 0,
};

/// the black edge's width, units
const edge = 1.0;

/// The point that clicks, logical pixels from the top left.
pub fn hotspot(kind: Cursor) [2]i32 {
    const h = art(kind).hot;
    return .{ @intFromFloat(@round(h[0])), @intFromFloat(@round(h[1])) };
}

/// Draw `kind` into `px` ((size * scale)^2 pixels, premultiplied ARGB).
pub fn draw(kind: Cursor, scale: u32, px: []u32) void {
    const a = art(kind);
    const n = size * scale;
    const k: f32 = @floatFromInt(scale);
    const ang = a.turn * std.math.pi / 2.0;
    const cs = @cos(ang);
    const sn = @sin(ang);
    for (0..n) |y| for (0..n) |x| {
        // the pixel's centre in units, turned back into the art's frame
        const ux = (@as(f32, @floatFromInt(x)) + 0.5) / k - 12;
        const uy = (@as(f32, @floatFromInt(y)) + 0.5) / k - 12;
        const p: V = .{ 12 + ux * cs + uy * sn, 12 - ux * sn + uy * cs };
        px[y * n + x] = shade(a, p, k);
    };
}

/// One pixel: black edge, white inside, black cuts.
fn shade(a: Art, p: V, k: f32) u32 {
    const d = dist(a.parts, p) * k;
    const outer = cover(d - edge * k);
    if (outer == 0) return 0;
    const fill = cover(d);
    const cut = if (a.cuts.len > 0) cover(dist(a.cuts, p) * k) else 0;
    const white = fill * (1 - cut);
    return pack(outer, white);
}

/// Coverage of a pixel whose centre is `d` pixels outside an edge.
fn cover(d: f32) f32 {
    return std.math.clamp(0.5 - d, 0, 1);
}

/// Premultiplied ARGB of white at `white` over black at `alpha`.
fn pack(alpha: f32, white: f32) u32 {
    const a: u32 = @intFromFloat(@round(255 * @max(alpha, white)));
    const c: u32 = @intFromFloat(@round(255 * white));
    return a << 24 | c << 16 | c << 8 | c;
}

/// Signed distance (units) from `p` to the union of `parts`.
fn dist(parts: []const Prim, p: V) f32 {
    var best: f32 = std.math.floatMax(f32);
    for (parts) |part| best = @min(best, switch (part) {
        .capsule => |c| segDist(p, c.a, c.b) - c.r,
        .box => |b| boxDist(p, b.c, b.h, b.r),
        .poly => |pts| polyDist(p, pts),
    });
    return best;
}

fn segDist(p: V, a: V, b: V) f32 {
    const ab: V = .{ b[0] - a[0], b[1] - a[1] };
    const ap: V = .{ p[0] - a[0], p[1] - a[1] };
    const len2 = ab[0] * ab[0] + ab[1] * ab[1];
    const t = if (len2 == 0) 0 else std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / len2, 0, 1);
    return std.math.hypot(ap[0] - ab[0] * t, ap[1] - ab[1] * t);
}

fn boxDist(p: V, c: V, h: V, r: f32) f32 {
    const qx = @abs(p[0] - c[0]) - h[0] + r;
    const qy = @abs(p[1] - c[1]) - h[1] + r;
    return std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;
}

/// Distance to the nearest edge, negative inside (even-odd).
fn polyDist(p: V, pts: []const V) f32 {
    var best: f32 = std.math.floatMax(f32);
    var inside = false;
    var j = pts.len - 1;
    for (pts, 0..) |a, i| {
        const b = pts[j];
        best = @min(best, segDist(p, a, b));
        if ((a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
        j = i;
    }
    return if (inside) -best else best;
}

// --- the shapes ---

fn art(kind: Cursor) Art {
    return switch (kind) {
        .arrow => arrow,
        .crosshair => crosshair,
        .text => text,
        .grab => grab,
        .grabbing => grabbing,
        .resize_ew => resize,
        .resize_ns => turned(1),
        .resize_nwse => turned(0.5),
        .resize_nesw => turned(-0.5),
    };
}

const arrow: Art = .{
    .parts = &.{.{ .poly = &.{ .{ 5, 3 }, .{ 5, 19.5 }, .{ 9, 15.8 }, .{ 11.6, 21.4 }, .{ 14.2, 20.2 }, .{ 11.7, 14.8 }, .{ 17, 14.8 } } }},
    .hot = .{ 5, 3 },
};

const crosshair: Art = .{ .parts = &.{
    .{ .box = .{ .c = .{ 12, 5.5 }, .h = .{ 1, 3.5 }, .r = 0.3 } },
    .{ .box = .{ .c = .{ 12, 18.5 }, .h = .{ 1, 3.5 }, .r = 0.3 } },
    .{ .box = .{ .c = .{ 5.5, 12 }, .h = .{ 3.5, 1 }, .r = 0.3 } },
    .{ .box = .{ .c = .{ 18.5, 12 }, .h = .{ 3.5, 1 }, .r = 0.3 } },
} };

const text: Art = .{ .parts = &.{
    .{ .box = .{ .c = .{ 12, 12 }, .h = .{ 1, 7.5 }, .r = 0 } },
    .{ .box = .{ .c = .{ 12, 4 }, .h = .{ 3, 1 }, .r = 0.4 } },
    .{ .box = .{ .c = .{ 12, 20 }, .h = .{ 3, 1 }, .r = 0.4 } },
} };

/// An open hand: four fingers apart, the thumb out to the left.
const grab: Art = .{ .parts = &.{
    .{ .capsule = .{ .a = .{ 7.9, 13 }, .b = .{ 7.9, 6.4 }, .r = 1.3 } },
    .{ .capsule = .{ .a = .{ 11.4, 13 }, .b = .{ 11.4, 4.4 }, .r = 1.3 } },
    .{ .capsule = .{ .a = .{ 14.9, 13 }, .b = .{ 14.9, 5.2 }, .r = 1.3 } },
    .{ .capsule = .{ .a = .{ 18.2, 13.5 }, .b = .{ 18.2, 7.8 }, .r = 1.2 } },
    .{ .capsule = .{ .a = .{ 8, 16.2 }, .b = .{ 4, 12 }, .r = 1.4 } },
    .{ .box = .{ .c = .{ 13.1, 15.6 }, .h = .{ 6.3, 4.6 }, .r = 3 } },
} };

/// A fist: the curled fingers' knuckles on top, the thumb across.
const grabbing: Art = .{
    .parts = &.{
        .{ .capsule = .{ .a = .{ 8.3, 11.2 }, .b = .{ 8.3, 10.2 }, .r = 1.6 } },
        .{ .capsule = .{ .a = .{ 11.5, 11.2 }, .b = .{ 11.5, 9.4 }, .r = 1.6 } },
        .{ .capsule = .{ .a = .{ 14.7, 11.2 }, .b = .{ 14.7, 9.8 }, .r = 1.6 } },
        .{ .capsule = .{ .a = .{ 17.7, 11.6 }, .b = .{ 17.7, 10.8 }, .r = 1.5 } },
        .{ .box = .{ .c = .{ 13, 15.3 }, .h = .{ 6.3, 4.5 }, .r = 3 } },
    },
    .cuts = &.{
        .{ .capsule = .{ .a = .{ 9.9, 9 }, .b = .{ 9.9, 12.2 }, .r = 0.45 } },
        .{ .capsule = .{ .a = .{ 13.1, 8.6 }, .b = .{ 13.1, 12.2 }, .r = 0.45 } },
        .{ .capsule = .{ .a = .{ 16.2, 9.2 }, .b = .{ 16.2, 12.4 }, .r = 0.45 } },
        .{ .capsule = .{ .a = .{ 7.2, 14.5 }, .b = .{ 10.8, 14.5 }, .r = 0.45 } },
        .{ .capsule = .{ .a = .{ 10.8, 14.5 }, .b = .{ 11.8, 16.4 }, .r = 0.45 } },
    },
};

/// A double arrow along x; turned for the other directions.
const resize: Art = .{ .parts = &.{
    .{ .box = .{ .c = .{ 12, 12 }, .h = .{ 5, 1 }, .r = 0 } },
    .{ .poly = &.{ .{ 2.5, 12 }, .{ 8, 7 }, .{ 8, 17 } } },
    .{ .poly = &.{ .{ 21.5, 12 }, .{ 16, 7 }, .{ 16, 17 } } },
} };

fn turned(quarters: f32) Art {
    var a = resize;
    a.turn = quarters;
    return a;
}

test "every cursor is drawn: opaque inside, clear in the corners, edged" {
    var px: [size * size * 4]u32 = undefined;
    for (std.enums.values(Cursor)) |kind| for ([_]u32{ 1, 2 }) |s| {
        const n = size * s;
        draw(kind, s, px[0 .. n * n]);
        const h = hotspot(kind);
        try std.testing.expect(h[0] >= 0 and h[0] < size and h[1] >= 0 and h[1] < size);
        try std.testing.expectEqual(@as(u32, 0), px[0]);
        var white: usize = 0;
        var black: usize = 0;
        for (px[0 .. n * n]) |v| {
            if (v == 0xFFFFFFFF) white += 1;
            if (v >> 24 == 0xFF and v & 0xFF < 0x40) black += 1;
        }
        try std.testing.expect(white > 6 * s * s);
        try std.testing.expect(black > 6 * s * s);
    };
}

test "the arrow's tip clicks; a resize arrow's centre is white" {
    try std.testing.expectEqual([2]i32{ 5, 3 }, hotspot(.arrow));
    var px: [size * size]u32 = undefined;
    for ([_]Cursor{ .resize_ew, .resize_ns, .resize_nwse, .resize_nesw }) |kind| {
        draw(kind, 1, &px);
        const c = px[12 * size + 12];
        try std.testing.expectEqual(@as(u32, 0xFF), c >> 24);
        try std.testing.expect(c & 0xFF > 0xC0);
    }
    // turned a quarter, the horizontal arrow stands up
    draw(.resize_ns, 1, &px);
    try std.testing.expectEqual(@as(u32, 0), px[12 * size + 2]);
    try std.testing.expect(px[3 * size + 12] != 0);
}
