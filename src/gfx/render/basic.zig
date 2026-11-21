//! Hard-edged (aliased) primitives: rectangles, discs, lines, arrows,
//! triangles, ellipse outlines and pixelation.

const std = @import("std");
const Canvas = @import("../render.zig").Canvas;
const pixel = @import("pixel.zig");
const toI32 = pixel.toI32;

pub fn fillRect(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const xa = @max(0, x0);
    const ya = @max(0, y0);
    const xb = @min(c.w, x0 +| w);
    const yb = @min(c.h, y0 +| h);
    if (xa >= xb or ya >= yb) return;
    var y = ya;
    while (y < yb) : (y += 1) {
        pixel.fillRow(c.px[@intCast(y * c.w + xa)..@intCast(y * c.w + xb)], color);
    }
}

pub fn rectOutline(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    // thicker than half the rect: it is a filled rect
    const t = @max(1, @min(thickness, @divTrunc(@min(w, h) + 1, 2)));
    fillRect(c, x0, y0, w, t, color); // top
    fillRect(c, x0, (y0 +| h) -| t, w, t, color); // bottom
    fillRect(c, x0, y0 +| t, t, h -| 2 *| t, color); // left
    fillRect(c, (x0 +| w) -| t, y0 +| t, t, h -| 2 *| t, color); // right
}

/// Stamp a filled disc (used as line brush). Row spans, clipped.
pub fn fillCircle(c: *Canvas, cx: i32, cy: i32, r: i32, color: u32) void {
    if (r < 0) return;
    const r64: i64 = r;
    const ya: i32 = @intCast(@max(0, @as(i64, cy) - r64));
    const yb: i32 = @intCast(@min(@as(i64, c.h) - 1, @as(i64, cy) + r64));
    var y = ya;
    while (y <= yb) : (y += 1) {
        const dy: i64 = @as(i64, y) - cy;
        // largest dx with dx^2 + dy^2 <= r^2
        const half: i64 = std.math.sqrt(@as(u64, @intCast(r64 * r64 - dy * dy)));
        const xa = @max(0, @as(i64, cx) - half);
        const xb = @min(@as(i64, c.w) - 1, @as(i64, cx) + half);
        if (xa > xb) continue;
        pixel.hspan(c, @intCast(xa), @intCast(xb), y, color);
    }
}

/// Clip segment a-b (float) to the rectangle [lo, hi] (Liang-Barsky).
fn clipSegment(ax: f64, ay: f64, bx: f64, by: f64, lo_x: f64, lo_y: f64, hi_x: f64, hi_y: f64) ?[4]f64 {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const dx = bx - ax;
    const dy = by - ay;
    const ps = [4]f64{ -dx, dx, -dy, dy };
    const qs = [4]f64{ ax - lo_x, hi_x - ax, ay - lo_y, hi_y - ay };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return null;
            continue;
        }
        const t = q / p;
        if (p < 0) {
            if (t > t1) return null;
            t0 = @max(t0, t);
        } else {
            if (t < t0) return null;
            t1 = @min(t1, t);
        }
    }
    return .{ ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1 };
}

/// Thick line: disc stamped along the segment. For 1px uses Bresenham.
pub fn line(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
    const r = @divTrunc(@max(1, thickness), 2);
    // for translucent colors, avoid double-blending: collect via mask for thick strokes
    if ((color >> 24) != 255 and thickness > 1) {
        thickLineMasked(c, x0, y0, x1, y1, r, color);
        return;
    }
    // only the part of the segment within reach of the canvas
    const m: f64 = @floatFromInt(r + 1);
    const seg = clipSegment(
        @floatFromInt(x0),
        @floatFromInt(y0),
        @floatFromInt(x1),
        @floatFromInt(y1),
        -m,
        -m,
        @as(f64, @floatFromInt(c.w)) + m,
        @as(f64, @floatFromInt(c.h)) + m,
    ) orelse return;
    const dx = seg[2] - seg[0];
    const dy = seg[3] - seg[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.5) {
        stamp(c, @intFromFloat(@round(seg[0])), @intFromFloat(@round(seg[1])), thickness, r, color);
        return;
    }
    // discs one pixel apart; for big brushes sqrt(r) apart, which still
    // leaves the edge within 1/8 px of the true capsule
    const spacing: f64 = if (r > 16) @sqrt(@as(f64, @floatFromInt(r))) else 1.0;
    const steps: usize = @intFromFloat(@max(1.0, len / spacing));
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x: i32 = @intFromFloat(@round(seg[0] + dx * t));
        const y: i32 = @intFromFloat(@round(seg[1] + dy * t));
        stamp(c, x, y, thickness, r, color);
    }
}

/// One brush dab of `line`: a pixel for 1px lines, else a disc of radius r.
inline fn stamp(c: *Canvas, x: i32, y: i32, thickness: i32, r: i32, color: u32) void {
    if (thickness <= 1) c.blend(x, y, color) else fillCircle(c, x, y, r, color);
}

/// Translucent thick line without overdraw: distance-to-segment test
/// inside the bounding box.
fn thickLineMasked(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, r: i32, color: u32) void {
    const xa = @max(0, @min(x0, x1) -| r);
    const ya = @max(0, @min(y0, y1) -| r);
    const xb = @min(c.w - 1, @max(x0, x1) +| r);
    const yb = @min(c.h - 1, @max(y0, y1) +| r);
    const ax: f64 = @floatFromInt(x0);
    const ay: f64 = @floatFromInt(y0);
    const bx: f64 = @floatFromInt(x1);
    const by: f64 = @floatFromInt(y1);
    const abx = bx - ax;
    const aby = by - ay;
    const ab2 = abx * abx + aby * aby;
    const rf: f64 = @floatFromInt(r);
    var y = ya;
    while (y <= yb) : (y += 1) {
        var x = xa;
        while (x <= xb) : (x += 1) {
            const px_: f64 = @floatFromInt(x);
            const py_: f64 = @floatFromInt(y);
            var t = if (ab2 == 0) 0.0 else ((px_ - ax) * abx + (py_ - ay) * aby) / ab2;
            t = @max(0.0, @min(1.0, t));
            const ddx = px_ - (ax + abx * t);
            const ddy = py_ - (ay + aby * t);
            if (ddx * ddx + ddy * ddy <= rf * rf) c.blend(x, y, color);
        }
    }
}

pub fn arrow(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
    const dxf = @as(f64, @floatFromInt(x1)) - @as(f64, @floatFromInt(x0));
    const dyf = @as(f64, @floatFromInt(y1)) - @as(f64, @floatFromInt(y0));
    const len = @sqrt(dxf * dxf + dyf * dyf);
    if (len < 1) return;
    const head = @max(10.0, @as(f64, @floatFromInt(thickness)) * 4.0);
    const ux = dxf / len;
    const uy = dyf / len;
    const fx1: f64 = @floatFromInt(x1);
    const fy1: f64 = @floatFromInt(y1);
    // shorten shaft so it doesn't poke through the head
    line(c, x0, y0, toI32(fx1 - ux * head * 0.6), toI32(fy1 - uy * head * 0.6), thickness, color);
    // filled triangle head
    const px = -uy;
    const py = ux;
    fillTriangle(
        c,
        x1,
        y1,
        toI32(fx1 - ux * head + px * head * 0.5),
        toI32(fy1 - uy * head + py * head * 0.5),
        toI32(fx1 - ux * head - px * head * 0.5),
        toI32(fy1 - uy * head - py * head * 0.5),
        color,
    );
}

pub fn fillTriangle(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    const xa = @max(0, @min(@min(x0, x1), x2));
    const ya = @max(0, @min(@min(y0, y1), y2));
    const xb = @min(c.w - 1, @max(@max(x0, x1), x2));
    const yb = @min(c.h - 1, @max(@max(y0, y1), y2));
    var y = ya;
    while (y <= yb) : (y += 1) {
        var x = xa;
        while (x <= xb) : (x += 1) {
            const w0 = edge(x1, y1, x2, y2, x, y);
            const w1 = edge(x2, y2, x0, y0, x, y);
            const w2 = edge(x0, y0, x1, y1, x, y);
            if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0))
                c.blend(x, y, color);
        }
    }
}

fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i128 {
    return (@as(i128, bx) - ax) * (@as(i128, py) - ay) - (@as(i128, by) - ay) * (@as(i128, px) - ax);
}

pub fn ellipseOutline(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: i32, color: u32) void {
    if (w < 2 or h < 2) return;
    const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
    const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
    const rx = @as(f64, @floatFromInt(w)) / 2.0;
    const ry = @as(f64, @floatFromInt(h)) / 2.0;
    const r = @divTrunc(@max(1, thickness), 2);
    const circumference = 2.0 * std.math.pi * @max(rx, ry);
    // past a few canvas perimeters more steps only revisit pixels
    const cap: f64 = @floatFromInt(8 * (@as(i64, c.w) + c.h) + 64);
    const steps: usize = @intFromFloat(@max(16.0, @min(circumference, cap)));
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x = toI32(cx + rx * @cos(a));
        const y = toI32(cy + ry * @sin(a));
        if (thickness <= 1) c.set(x, y, color) else fillCircle(c, x, y, r, color | 0xFF000000);
    }
}

/// Mosaic the region with block averages (privacy redaction).
pub fn pixelate(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, block: i32) void {
    if (w <= 0 or h <= 0) return;
    const xa = @max(0, x0);
    const ya = @max(0, y0);
    const xb = @min(c.w, x0 +| w);
    const yb = @min(c.h, y0 +| h);
    if (xa >= xb or ya >= yb) return;
    const blk = @max(2, block);
    var by = ya;
    while (by < yb) : (by +|= blk) {
        var bx = xa;
        while (bx < xb) : (bx +|= blk) {
            const ex = @min(bx +| blk, xb);
            const ey = @min(by +| blk, yb);
            const avg = blockAverage(c, bx, by, ex, ey) orelse continue;
            var y = by;
            while (y < ey) : (y += 1) {
                @memset(c.px[@intCast(y * c.w + bx)..@intCast(y * c.w + ex)], avg);
            }
        }
    }
}

/// Opaque mean colour of the pixels in [bx, ex) x [by, ey); null if empty.
fn blockAverage(c: *Canvas, bx: i32, by: i32, ex: i32, ey: i32) ?u32 {
    var r: u64 = 0;
    var g: u64 = 0;
    var b: u64 = 0;
    var n: u64 = 0;
    var y = by;
    while (y < ey) : (y += 1) {
        var x = bx;
        while (x < ex) : (x += 1) {
            const p = c.px[@intCast(y * c.w + x)];
            r += (p >> 16) & 0xFF;
            g += (p >> 8) & 0xFF;
            b += p & 0xFF;
            n += 1;
        }
    }
    if (n == 0) return null;
    return 0xFF000000 |
        (@as(u32, @intCast(r / n)) << 16) |
        (@as(u32, @intCast(g / n)) << 8) |
        @as(u32, @intCast(b / n));
}
