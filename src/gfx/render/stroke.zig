//! Anti-aliased capsule strokes over polylines.

const std = @import("std");
const Canvas = @import("../render.zig").Canvas;
const span = @import("pixel.zig").span;

/// Anti-aliased capsule stroke over a polyline with no self-overlap
/// artifacts. With a mask buffer attached the cost is linear in stroke
/// length (per-segment rasterization, max-coverage accumulation).
pub fn strokePolylineAA(c: *Canvas, pts: anytype, width: f64, color: u32) void {
    if (pts.len == 0 or !(width > 0)) return;
    const half = @min(@max(0.5, width / 2.0), 1e6);
    if (c.mask.len >= @as(usize, @intCast(c.w * c.h))) {
        strokeMasked(c, pts, half, color);
        return;
    }
    strokeBBox(c, pts, half, color);
}

/// Fallback without a mask: O(bbox * segments); fine for short 2-point
/// strokes.
fn strokeBBox(c: *Canvas, pts: anytype, half: f64, color: u32) void {
    var minx: f64 = std.math.floatMax(f64);
    var miny: f64 = std.math.floatMax(f64);
    var maxx: f64 = -std.math.floatMax(f64);
    var maxy: f64 = -std.math.floatMax(f64);
    for (pts) |p| {
        const fx: f64 = @floatFromInt(p.x);
        const fy: f64 = @floatFromInt(p.y);
        minx = @min(minx, fx);
        miny = @min(miny, fy);
        maxx = @max(maxx, fx);
        maxy = @max(maxy, fy);
    }
    const xs = span(minx - half - 1, maxx + half + 1, c.w) orelse return;
    const ys = span(miny - half - 1, maxy + half + 1, c.h) orelse return;
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const best = polylineDist(px, py, pts, half);
            c.blendCov(x, y, color, @max(0.0, @min(1.0, half - best + 0.5)));
        }
    }
}

/// Distance from (px, py) to the polyline, stopping early once the point
/// is fully covered by a stroke of half-width `half`.
inline fn polylineDist(px: f64, py: f64, pts: anytype, half: f64) f64 {
    if (pts.len == 1) return segDist(px, py, pts[0], pts[0]);
    var best: f64 = std.math.floatMax(f64);
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        best = @min(best, segDist(px, py, pts[i], pts[i + 1]));
        if (best <= half - 1.0) break; // fully covered already
    }
    return best;
}

/// Pixel bounding box [x0, x1] x [y0, y1] (inclusive) touched in the mask.
const Box = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn include(b: *Box, xs: [2]i32, ys: [2]i32) void {
        b.x0 = @min(b.x0, xs[0]);
        b.y0 = @min(b.y0, ys[0]);
        b.x1 = @max(b.x1, xs[1]);
        b.y1 = @max(b.y1, ys[1]);
    }
};

/// Fast path: rasterize each segment into the mask (max coverage), then
/// blend the whole stroke once and clear the touched region.
fn strokeMasked(c: *Canvas, pts: anytype, half: f64, color: u32) void {
    var box: Box = .{ .x0 = c.w, .y0 = c.h, .x1 = -1, .y1 = -1 };
    const n_segs: usize = if (pts.len == 1) 1 else pts.len - 1;
    var i: usize = 0;
    while (i < n_segs) : (i += 1) {
        const b = if (pts.len == 1) pts[0] else pts[i + 1];
        rasterSegment(c, pts[i], b, half, &box);
    }
    if (box.x1 < box.x0) return;
    blendMask(c, box, color);
}

/// Max-accumulate the coverage of the capsule a-b into the mask.
fn rasterSegment(c: *Canvas, a: anytype, b: anytype, half: f64, box: *Box) void {
    const wu: usize = @intCast(c.w);
    const ext = half + 1.5;
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const bx: f64 = @floatFromInt(b.x);
    const by: f64 = @floatFromInt(b.y);
    const xs = span(@min(ax, bx) - ext, @max(ax, bx) + ext, c.w) orelse return;
    const ys = span(@min(ay, by) - ext, @max(ay, by) + ext, c.h) orelse return;
    box.include(xs, ys);
    var y = ys[0];
    while (y <= ys[1]) : (y += 1) {
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const d = segDist(px, py, a, b);
            const cov = @max(0.0, @min(1.0, half - d + 0.5));
            if (cov <= 0.003) continue;
            const cv: u8 = @intFromFloat(cov * 255.0);
            const idx = @as(usize, @intCast(y)) * wu + @as(usize, @intCast(x));
            if (cv > c.mask[idx]) c.mask[idx] = cv;
        }
    }
}

/// Single blend pass + mask clear over the touched box.
fn blendMask(c: *Canvas, box: Box, color: u32) void {
    const wu: usize = @intCast(c.w);
    var y = box.y0;
    while (y <= box.y1) : (y += 1) {
        const row = @as(usize, @intCast(y)) * wu;
        var x = box.x0;
        while (x <= box.x1) : (x += 1) {
            const idx = row + @as(usize, @intCast(x));
            const cv = c.mask[idx];
            if (cv != 0) {
                c.blendCov(x, y, color, @as(f64, @floatFromInt(cv)) / 255.0);
                c.mask[idx] = 0;
            }
        }
    }
}

fn segDist(px: f64, py: f64, a: anytype, b: anytype) f64 {
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const bx: f64 = @floatFromInt(b.x);
    const by: f64 = @floatFromInt(b.y);
    const abx = bx - ax;
    const aby = by - ay;
    const ab2 = abx * abx + aby * aby;
    var t: f64 = if (ab2 == 0) 0.0 else ((px - ax) * abx + (py - ay) * aby) / ab2;
    t = @max(0.0, @min(1.0, t));
    const dx = px - (ax + abx * t);
    const dy = py - (ay + aby * t);
    return @sqrt(dx * dx + dy * dy);
}
