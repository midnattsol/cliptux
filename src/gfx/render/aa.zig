//! Anti-aliased primitives: discs, rings, rounded rectangles, triangles,
//! elliptic rings and arrows.
//!
//! Each clips its bounding box to the canvas before iterating, and fills
//! the fully covered interior of a row as a span, so the per-pixel
//! distance math only runs along the anti-aliased edges.

const std = @import("std");
const Canvas = @import("../render.zig").Canvas;
const pixel = @import("pixel.zig");
const stroke = @import("stroke.zig");
const toI32 = pixel.toI32;
const span = pixel.span;

/// Anti-aliased filled disc.
pub fn fillCircleAA(c: *Canvas, cx: f64, cy: f64, r: f64, color: u32) void {
    if (!(r > 0)) return;
    const ys = span(cy - r - 1, cy + r + 1, c.h) orelse return;
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
        const outer2 = (r + 0.5) * (r + 0.5) - dy * dy;
        if (outer2 <= 0) continue;
        const ho = @sqrt(outer2);
        const xs = span(cx - ho - 1, cx + ho + 1, c.w) orelse continue;
        // centres with d <= r - 0.5 are fully covered
        const inner2 = (r - 0.5) * (r - 0.5) - dy * dy;
        var ia: i32 = xs[1] + 1;
        var ib: i32 = xs[1];
        if (r > 0.5 and inner2 > 0) {
            const hi = @sqrt(inner2);
            ia = @max(xs[0], toI32(@ceil(cx - hi - 0.5)));
            ib = @min(xs[1], toI32(@floor(cx + hi - 0.5)));
            if (ia <= ib) pixel.hspan(c, ia, ib, y, color) else {
                ia = xs[1] + 1;
                ib = xs[1];
            }
        }
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            if (x == ia) {
                x = ib;
                continue;
            }
            const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
            const d = @sqrt(dx * dx + dy * dy);
            c.blendCov(x, y, color, @max(0.0, @min(1.0, r - d + 0.5)));
        }
    }
}

/// Anti-aliased ring (circle outline).
pub fn ringAA(c: *Canvas, cx: f64, cy: f64, r: f64, ring_w: f64, color: u32) void {
    if (!(ring_w > 0) or !(r >= 0)) return;
    const half = ring_w / 2.0;
    const ro = r + half + 0.5; // beyond: no coverage
    const ri = r - half - 0.5; // within: no coverage
    const ys = span(cy - ro - 1, cy + ro + 1, c.h) orelse return;
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
        const o2 = ro * ro - dy * dy;
        if (o2 <= 0) continue;
        const ho = @sqrt(o2);
        // the hole: centres closer than ri to the centre
        // (only when wider than a pixel, so the two parts never overlap)
        const hole: f64 = if (ri > 0 and ri * ri - dy * dy > 1) @sqrt(ri * ri - dy * dy) else -1;
        const parts = [2][2]f64{
            .{ cx - ho - 1, if (hole > 1) cx - hole else cx + ho + 1 },
            .{ if (hole > 1) cx + hole - 1 else cx + ho + 2, cx + ho + 1 },
        };
        for (parts) |pt| {
            const xs = span(pt[0], pt[1], c.w) orelse continue;
            var x = xs[0];
            while (x <= xs[1]) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const d = @abs(@sqrt(dx * dx + dy * dy) - r);
                c.blendCov(x, y, color, @max(0.0, @min(1.0, half - d + 0.5)));
            }
        }
    }
}

/// Anti-aliased rounded rectangle fill.
pub fn fillRoundRectAA(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, radius: f64, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const fx0: f64 = @floatFromInt(x0);
    const fy0: f64 = @floatFromInt(y0);
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    const fx1 = fx0 + fw;
    const fy1 = fy0 + fh;
    const r = if (radius > 0) @min(radius, @min(fw / 2.0, fh / 2.0)) else 0;
    const ys = span(fy0 - 1, fy1, c.h) orelse return;
    const xs = span(fx0 - 1, fx1, c.w) orelse return;
    // columns whose coverage does not depend on x (between the corners)
    const mid_a = @max(xs[0], toI32(@ceil(fx0 + r)));
    const mid_b = @min(xs[1], toI32(@floor(fx1 - r)) - 1);
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        const qy = @max(@max(fy0 + r - py, py - (fy1 - r)), 0.0);
        if (mid_a <= mid_b) {
            // signed distance with qx = 0 is qy - r
            const cov = @max(0.0, @min(1.0, r - qy + 0.5));
            if (cov >= 1.0) pixel.hspan(c, mid_a, mid_b, y, color) else {
                var x = mid_a;
                while (x <= mid_b) : (x += 1) c.blendCov(x, y, color, cov);
            }
        }
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            if (x == mid_a and mid_a <= mid_b) {
                x = mid_b;
                continue;
            }
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            // signed distance to the rounded rect
            const qx = @max(@max(fx0 + r - px, px - (fx1 - r)), 0.0);
            const d = @sqrt(qx * qx + qy * qy) - r;
            c.blendCov(x, y, color, @max(0.0, @min(1.0, -d + 0.5)));
        }
    }
}

/// A counter-clockwise triangle; "inside" means all edge functions >= 0.
const Triangle = struct {
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    cx: f64,
    cy: f64,

    inline fn inside(t: Triangle, px: f64, py: f64) bool {
        return edgeF(t.bx, t.by, t.cx, t.cy, px, py) >= 0 and
            edgeF(t.cx, t.cy, t.ax, t.ay, px, py) >= 0 and
            edgeF(t.ax, t.ay, t.bx, t.by, px, py) >= 0;
    }

    /// All four corners of pixel (fx, fy) inside.
    inline fn coversPixel(t: Triangle, fx: f64, fy: f64) bool {
        return t.inside(fx, fy) and t.inside(fx + 1, fy) and
            t.inside(fx, fy + 1) and t.inside(fx + 1, fy + 1);
    }

    /// How many of the 3x3 subsamples of pixel (fx, fy) are inside.
    inline fn subsampleHits(t: Triangle, fx: f64, fy: f64) u32 {
        var hits: u32 = 0;
        var sy: u32 = 0;
        while (sy < 3) : (sy += 1) {
            var sx: u32 = 0;
            while (sx < 3) : (sx += 1) {
                const px = fx + (@as(f64, @floatFromInt(sx)) + 0.5) / 3.0;
                const py = fy + (@as(f64, @floatFromInt(sy)) + 0.5) / 3.0;
                if (t.inside(px, py)) hits += 1;
            }
        }
        return hits;
    }
};

/// Anti-aliased filled triangle (3x3 supersampling on edge pixels;
/// pixels whose four corners are all inside are filled directly).
pub fn fillTriangleAA(c: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, color: u32) void {
    const area = edgeF(x0, y0, x1, y1, x2, y2);
    if (!(area != 0)) return; // degenerate or NaN
    // orient counter-clockwise so "inside" means all edges >= 0
    const tri: Triangle = if (area < 0)
        .{ .ax = x0, .ay = y0, .bx = x2, .by = y2, .cx = x1, .cy = y1 }
    else
        .{ .ax = x0, .ay = y0, .bx = x1, .by = y1, .cx = x2, .cy = y2 };
    const xs = span(@min(@min(x0, x1), x2) - 1, @max(@max(x0, x1), x2), c.w) orelse return;
    const ys = span(@min(@min(y0, y1), y2) - 1, @max(@max(y0, y1), y2), c.h) orelse return;
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const fy: f64 = @floatFromInt(y);
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            const fx: f64 = @floatFromInt(x);
            if (tri.coversPixel(fx, fy)) {
                c.blend(x, y, color);
                continue;
            }
            const hits = tri.subsampleHits(fx, fy);
            if (hits > 0) c.blendCov(x, y, color, @as(f64, @floatFromInt(hits)) / 9.0);
        }
    }
}

fn edgeF(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

/// Coverage of the band of half-width `half` around an ellipse centred
/// at (cx, ·) with inverse squared radii irx2, iry2.
const EllipseBand = struct {
    cx: f64,
    irx2: f64,
    iry2: f64,
    half: f64,

    /// Coverage of column x on a row at offset py from the centre, using
    /// the approximate distance to the ellipse f / |grad f|.
    inline fn cov(e: EllipseBand, x: i32, py: f64) f64 {
        const px = @as(f64, @floatFromInt(x)) + 0.5 - e.cx;
        const f = px * px * e.irx2 + py * py * e.iry2 - 1.0;
        const gx = 2.0 * px * e.irx2;
        const gy = 2.0 * py * e.iry2;
        const g = @sqrt(gx * gx + gy * gy);
        return if (g < 1e-9) 0 else @max(0.0, @min(1.0, e.half - @abs(f) / g + 0.5));
    }
};

/// Anti-aliased elliptic ring (ellipse outline). Each row walks in from
/// the outer edge on both sides and stops once it has crossed the
/// band, so the cost follows the outline, not the bounding box.
pub fn ellipseRingAA(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: f64, color: u32) void {
    if (w < 2 or h < 2) return;
    const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
    const rx = @max(1.0, @as(f64, @floatFromInt(w)) / 2.0);
    const ry = @max(1.0, @as(f64, @floatFromInt(h)) / 2.0);
    const half = @min(@max(0.5, if (thickness > 0) thickness / 2.0 else 0.5), 1e6);
    const band: EllipseBand = .{ .cx = cx, .irx2 = 1.0 / (rx * rx), .iry2 = 1.0 / (ry * ry), .half = half };
    // same footprint as a plain bounding-box scan: the box padded by
    // half + 2 (the approximate distance can reach past the ellipse
    // band near thin tips, so the box, not an ellipse, bounds the walk)
    const pad: f64 = @floor(half + 2);
    const fx0: f64 = @floatFromInt(x0);
    const fy0: f64 = @floatFromInt(y0);
    const ys = span(fy0 - pad, fy0 + @as(f64, @floatFromInt(h)) + pad, c.h) orelse return;
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const py = @as(f64, @floatFromInt(y)) + 0.5 - cy;
        var left_end: i32 = -1; // last column the left walk looked at
        if (span(fx0 - pad, cx, c.w)) |xs| walkBand(c, band, y, py, xs, true, &left_end, color);
        if (span(cx, fx0 + @as(f64, @floatFromInt(w)) + pad, c.w)) |xs|
            walkBand(c, band, y, py, xs, false, &left_end, color);
    }
}

/// One side of an `ellipseRingAA` row: walk inwards over `xs` from its
/// outer end, blending the band, and stop once past it. The right walk
/// also stops where the left one ended.
inline fn walkBand(c: *Canvas, band: EllipseBand, y: i32, py: f64, xs: [2]i32, comptime is_left: bool, left_end: *i32, color: u32) void {
    var seen = false;
    var k: i32 = 0;
    while (k <= xs[1] - xs[0]) : (k += 1) {
        const x = if (is_left) xs[0] + k else xs[1] - k;
        if (!is_left and x <= left_end.*) break; // the left walk did it
        if (is_left) left_end.* = x;
        const cov = band.cov(x, py);
        if (cov > 0.003) {
            c.blendCov(x, y, color, cov);
            seen = true;
        } else if (seen) break;
    }
}

/// Anti-aliased arrow with filled head.
pub fn arrowAA(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
    const fx0: f64 = @floatFromInt(x0);
    const fy0: f64 = @floatFromInt(y0);
    const fx1: f64 = @floatFromInt(x1);
    const fy1: f64 = @floatFromInt(y1);
    const dx = fx1 - fx0;
    const dy = fy1 - fy0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    const tf: f64 = @floatFromInt(@max(1, thickness));
    const head = @max(12.0, tf * 3.5);
    const ux = dx / len;
    const uy = dy / len;
    const sx1 = toI32(fx1 - ux * head * 0.7);
    const sy1 = toI32(fy1 - uy * head * 0.7);
    const seg = [_]struct { x: i32, y: i32 }{ .{ .x = x0, .y = y0 }, .{ .x = sx1, .y = sy1 } };
    stroke.strokePolylineAA(c, seg[0..], tf, color);
    const px = -uy;
    const py = ux;
    fillTriangleAA(
        c,
        fx1,
        fy1,
        fx1 - ux * head + px * head * 0.45,
        fy1 - uy * head + py * head * 0.45,
        fx1 - ux * head - px * head * 0.45,
        fy1 - uy * head - py * head * 0.45,
        color,
    );
}
