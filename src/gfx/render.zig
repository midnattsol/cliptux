//! Software renderer over a 0xAARRGGBB pixel canvas: shapes, blending,
//! pixelation, text. All drawing is clipped to the canvas bounds.

const std = @import("std");
const font = @import("font.zig");
const utf8 = @import("utf8.zig");

/// f64 -> i32 for pixel coordinates: clamps far-off (and NaN) values to
/// +-1e9 so callers never hit an out-of-range @intFromFloat.
fn toI32(v: f64) i32 {
    if (!(v > -1e9)) return -1_000_000_000;
    if (v > 1e9) return 1_000_000_000;
    return @intFromFloat(v);
}

/// Bitmap-font byte for a codepoint: ASCII as is, anything else '?'.
fn bitmapChar(cp: u21) u8 {
    return if (cp >= 32 and cp <= 126) @intCast(cp) else '?';
}

pub const Canvas = struct {
    px: []u32,
    w: i32,
    h: i32,
    /// optional w*h coverage scratch buffer enabling the fast stroke path
    mask: []u8 = &.{},

    pub fn init(px: []u32, w: u32, h: u32) Canvas {
        std.debug.assert(px.len >= @as(usize, w) * h);
        return .{ .px = px, .w = @intCast(w), .h = @intCast(h) };
    }

    pub inline fn set(self: *Canvas, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        self.px[@intCast(y * self.w + x)] = color | 0xFF000000;
    }

    pub inline fn blend(self: *Canvas, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i: usize = @intCast(y * self.w + x);
        self.px[i] = blendPixel(self.px[i], color);
    }

    /// Exact x/255 for x <= 65407, without a division.
    inline fn div255(x: u32) u32 {
        return (x + 128 + ((x + 128) >> 8)) >> 8;
    }

    /// src-over blend of `src` (with alpha) onto opaque dst.
    pub fn blendPixel(dst: u32, src: u32) u32 {
        const a: u32 = src >> 24;
        if (a == 255) return src | 0xFF000000;
        if (a == 0) return dst;
        const inv = 255 - a;
        const sr = (src >> 16) & 0xFF;
        const sg = (src >> 8) & 0xFF;
        const sb = src & 0xFF;
        const dr = (dst >> 16) & 0xFF;
        const dg = (dst >> 8) & 0xFF;
        const db = dst & 0xFF;
        const r = div255(sr * a + dr * inv);
        const g = div255(sg * a + dg * inv);
        const b = div255(sb * a + db * inv);
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    /// Index range [a, b] (inclusive) of pixels whose centres can lie in
    /// [lo, hi], clipped to 0..max-1; null when empty or NaN.
    fn span(lo: f64, hi: f64, max: i32) ?[2]i32 {
        if (!(lo <= hi)) return null;
        const a = @max(0.0, @floor(lo));
        const b = @min(@as(f64, @floatFromInt(max - 1)), @ceil(hi));
        if (!(a <= b)) return null;
        return .{ @intFromFloat(a), @intFromFloat(b) };
    }

    pub fn fillRect(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
        if (w <= 0 or h <= 0) return;
        const xa = @max(0, x0);
        const ya = @max(0, y0);
        const xb = @min(self.w, x0 +| w);
        const yb = @min(self.h, y0 +| h);
        if (xa >= xb or ya >= yb) return;
        const opaque_color = (color >> 24) == 255;
        var y = ya;
        while (y < yb) : (y += 1) {
            const row = self.px[@intCast(y * self.w + xa)..@intCast(y * self.w + xb)];
            if (opaque_color) {
                @memset(row, color);
            } else {
                for (row) |*p| p.* = blendPixel(p.*, color);
            }
        }
    }

    pub fn rectOutline(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: i32, color: u32) void {
        if (w <= 0 or h <= 0) return;
        // thicker than half the rect: it is a filled rect
        const t = @max(1, @min(thickness, @divTrunc(@min(w, h) + 1, 2)));
        self.fillRect(x0, y0, w, t, color); // top
        self.fillRect(x0, (y0 +| h) -| t, w, t, color); // bottom
        self.fillRect(x0, y0 +| t, t, h -| 2 *| t, color); // left
        self.fillRect((x0 +| w) -| t, y0 +| t, t, h -| 2 *| t, color); // right
    }

    /// Stamp a filled disc (used as line brush). Row spans, clipped.
    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, r: i32, color: u32) void {
        if (r < 0) return;
        const r64: i64 = r;
        const ya: i32 = @intCast(@max(0, @as(i64, cy) - r64));
        const yb: i32 = @intCast(@min(@as(i64, self.h) - 1, @as(i64, cy) + r64));
        var y = ya;
        while (y <= yb) : (y += 1) {
            const dy: i64 = @as(i64, y) - cy;
            // largest dx with dx^2 + dy^2 <= r^2
            const half: i64 = std.math.sqrt(@as(u64, @intCast(r64 * r64 - dy * dy)));
            const xa = @max(0, @as(i64, cx) - half);
            const xb = @min(@as(i64, self.w) - 1, @as(i64, cx) + half);
            if (xa > xb) continue;
            self.hspan(@intCast(xa), @intCast(xb), y, color);
        }
    }

    /// Blend `color` over pixels xa..xb (inclusive, already clipped) of row y.
    inline fn hspan(self: *Canvas, xa: i32, xb: i32, y: i32, color: u32) void {
        const row = self.px[@intCast(y * self.w + xa)..@intCast(y * self.w + xb + 1)];
        if (color >> 24 == 255) {
            @memset(row, color);
        } else {
            for (row) |*p| p.* = blendPixel(p.*, color);
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
    pub fn line(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
        const r = @divTrunc(@max(1, thickness), 2);
        // for translucent colors, avoid double-blending: collect via mask for thick strokes
        if ((color >> 24) != 255 and thickness > 1) {
            self.thickLineMasked(x0, y0, x1, y1, r, color);
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
            @as(f64, @floatFromInt(self.w)) + m,
            @as(f64, @floatFromInt(self.h)) + m,
        ) orelse return;
        const sx0: i32 = @intFromFloat(@round(seg[0]));
        const sy0: i32 = @intFromFloat(@round(seg[1]));
        const dx = seg[2] - seg[0];
        const dy = seg[3] - seg[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.5) {
            if (thickness <= 1) self.blend(sx0, sy0, color) else self.fillCircle(sx0, sy0, r, color);
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
            if (thickness <= 1) self.blend(x, y, color) else self.fillCircle(x, y, r, color);
        }
    }

    /// Translucent thick line without overdraw: distance-to-segment test
    /// inside the bounding box.
    fn thickLineMasked(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, r: i32, color: u32) void {
        const xa = @max(0, @min(x0, x1) -| r);
        const ya = @max(0, @min(y0, y1) -| r);
        const xb = @min(self.w - 1, @max(x0, x1) +| r);
        const yb = @min(self.h - 1, @max(y0, y1) +| r);
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
                if (ddx * ddx + ddy * ddy <= rf * rf) self.blend(x, y, color);
            }
        }
    }

    pub fn arrow(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
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
        self.line(x0, y0, toI32(fx1 - ux * head * 0.6), toI32(fy1 - uy * head * 0.6), thickness, color);
        // filled triangle head
        const px = -uy;
        const py = ux;
        self.fillTriangle(
            x1,
            y1,
            toI32(fx1 - ux * head + px * head * 0.5),
            toI32(fy1 - uy * head + py * head * 0.5),
            toI32(fx1 - ux * head - px * head * 0.5),
            toI32(fy1 - uy * head - py * head * 0.5),
            color,
        );
    }

    pub fn fillTriangle(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
        const xa = @max(0, @min(@min(x0, x1), x2));
        const ya = @max(0, @min(@min(y0, y1), y2));
        const xb = @min(self.w - 1, @max(@max(x0, x1), x2));
        const yb = @min(self.h - 1, @max(@max(y0, y1), y2));
        var y = ya;
        while (y <= yb) : (y += 1) {
            var x = xa;
            while (x <= xb) : (x += 1) {
                const w0 = edge(x1, y1, x2, y2, x, y);
                const w1 = edge(x2, y2, x0, y0, x, y);
                const w2 = edge(x0, y0, x1, y1, x, y);
                if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0))
                    self.blend(x, y, color);
            }
        }
    }

    fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i128 {
        return (@as(i128, bx) - ax) * (@as(i128, py) - ay) - (@as(i128, by) - ay) * (@as(i128, px) - ax);
    }

    pub fn ellipseOutline(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: i32, color: u32) void {
        if (w < 2 or h < 2) return;
        const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
        const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
        const rx = @as(f64, @floatFromInt(w)) / 2.0;
        const ry = @as(f64, @floatFromInt(h)) / 2.0;
        const r = @divTrunc(@max(1, thickness), 2);
        const circumference = 2.0 * std.math.pi * @max(rx, ry);
        // past a few canvas perimeters more steps only revisit pixels
        const cap: f64 = @floatFromInt(8 * (@as(i64, self.w) + self.h) + 64);
        const steps: usize = @intFromFloat(@max(16.0, @min(circumference, cap)));
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const x = toI32(cx + rx * @cos(a));
            const y = toI32(cy + ry * @sin(a));
            if (thickness <= 1) self.set(x, y, color) else self.fillCircle(x, y, r, color | 0xFF000000);
        }
    }

    /// Mosaic the region with block averages (privacy redaction).
    pub fn pixelate(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, block: i32) void {
        if (w <= 0 or h <= 0) return;
        const xa = @max(0, x0);
        const ya = @max(0, y0);
        const xb = @min(self.w, x0 +| w);
        const yb = @min(self.h, y0 +| h);
        if (xa >= xb or ya >= yb) return;
        const blk = @max(2, block);
        var by = ya;
        while (by < yb) : (by +|= blk) {
            var bx = xa;
            while (bx < xb) : (bx +|= blk) {
                const ex = @min(bx +| blk, xb);
                const ey = @min(by +| blk, yb);
                var r: u64 = 0;
                var g: u64 = 0;
                var b: u64 = 0;
                var n: u64 = 0;
                var y = by;
                while (y < ey) : (y += 1) {
                    var x = bx;
                    while (x < ex) : (x += 1) {
                        const p = self.px[@intCast(y * self.w + x)];
                        r += (p >> 16) & 0xFF;
                        g += (p >> 8) & 0xFF;
                        b += p & 0xFF;
                        n += 1;
                    }
                }
                if (n == 0) continue;
                const avg = 0xFF000000 |
                    (@as(u32, @intCast(r / n)) << 16) |
                    (@as(u32, @intCast(g / n)) << 8) |
                    @as(u32, @intCast(b / n));
                y = by;
                while (y < ey) : (y += 1) {
                    @memset(self.px[@intCast(y * self.w + bx)..@intCast(y * self.w + ex)], avg);
                }
            }
        }
    }

    // --- anti-aliased primitives ---
    //
    // Each clips its bounding box to the canvas before iterating, and
    // fills the fully covered interior of a row as a span, so the per-pixel
    // distance math only runs along the anti-aliased edges.

    /// Blend with an extra coverage factor in [0,1].
    pub inline fn blendCov(self: *Canvas, x: i32, y: i32, color: u32, cov: f64) void {
        if (!(cov > 0.003)) return;
        const a: f64 = @floatFromInt(color >> 24);
        const scaled: u32 = @intFromFloat(@min(255.0, a * cov + 0.5));
        self.blend(x, y, (color & 0x00FFFFFF) | (scaled << 24));
    }

    /// Anti-aliased filled disc.
    pub fn fillCircleAA(self: *Canvas, cx: f64, cy: f64, r: f64, color: u32) void {
        if (!(r > 0)) return;
        const ys = span(cy - r - 1, cy + r + 1, self.h) orelse return;
        var y = ys[0];
        while (y <= ys[1]) : (y += 1) {
            const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const outer2 = (r + 0.5) * (r + 0.5) - dy * dy;
            if (outer2 <= 0) continue;
            const ho = @sqrt(outer2);
            const xs = span(cx - ho - 1, cx + ho + 1, self.w) orelse continue;
            // centres with d <= r - 0.5 are fully covered
            const inner2 = (r - 0.5) * (r - 0.5) - dy * dy;
            var ia: i32 = xs[1] + 1;
            var ib: i32 = xs[1];
            if (r > 0.5 and inner2 > 0) {
                const hi = @sqrt(inner2);
                ia = @max(xs[0], toI32(@ceil(cx - hi - 0.5)));
                ib = @min(xs[1], toI32(@floor(cx + hi - 0.5)));
                if (ia <= ib) self.hspan(ia, ib, y, color) else {
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
                self.blendCov(x, y, color, @max(0.0, @min(1.0, r - d + 0.5)));
            }
        }
    }

    /// Anti-aliased ring (circle outline).
    pub fn ringAA(self: *Canvas, cx: f64, cy: f64, r: f64, ring_w: f64, color: u32) void {
        if (!(ring_w > 0) or !(r >= 0)) return;
        const half = ring_w / 2.0;
        const ro = r + half + 0.5; // beyond: no coverage
        const ri = r - half - 0.5; // within: no coverage
        const ys = span(cy - ro - 1, cy + ro + 1, self.h) orelse return;
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
                const xs = span(pt[0], pt[1], self.w) orelse continue;
                var x = xs[0];
                while (x <= xs[1]) : (x += 1) {
                    const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                    const d = @abs(@sqrt(dx * dx + dy * dy) - r);
                    self.blendCov(x, y, color, @max(0.0, @min(1.0, half - d + 0.5)));
                }
            }
        }
    }

    /// Anti-aliased rounded rectangle fill.
    pub fn fillRoundRectAA(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, radius: f64, color: u32) void {
        if (w <= 0 or h <= 0) return;
        const fx0: f64 = @floatFromInt(x0);
        const fy0: f64 = @floatFromInt(y0);
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        const fx1 = fx0 + fw;
        const fy1 = fy0 + fh;
        const r = if (radius > 0) @min(radius, @min(fw / 2.0, fh / 2.0)) else 0;
        const ys = span(fy0 - 1, fy1, self.h) orelse return;
        const xs = span(fx0 - 1, fx1, self.w) orelse return;
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
                if (cov >= 1.0) self.hspan(mid_a, mid_b, y, color) else {
                    var x = mid_a;
                    while (x <= mid_b) : (x += 1) self.blendCov(x, y, color, cov);
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
                self.blendCov(x, y, color, @max(0.0, @min(1.0, -d + 0.5)));
            }
        }
    }

    /// Anti-aliased capsule stroke over a polyline with no self-overlap
    /// artifacts. With a mask buffer attached the cost is linear in stroke
    /// length (per-segment rasterization, max-coverage accumulation).
    pub fn strokePolylineAA(self: *Canvas, pts: anytype, width: f64, color: u32) void {
        if (pts.len == 0 or !(width > 0)) return;
        const half = @min(@max(0.5, width / 2.0), 1e6);
        if (self.mask.len >= @as(usize, @intCast(self.w * self.h))) {
            self.strokeMasked(pts, half, color);
            return;
        }
        // fallback: O(bbox * segments); fine for short 2-point strokes
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
        const xs = span(minx - half - 1, maxx + half + 1, self.w) orelse return;
        const ys = span(miny - half - 1, maxy + half + 1, self.h) orelse return;
        var y = ys[0];
        while (y <= ys[1]) : (y += 1) {
            var x = xs[0];
            while (x <= xs[1]) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                var best: f64 = std.math.floatMax(f64);
                if (pts.len == 1) {
                    best = segDist(px, py, pts[0], pts[0]);
                } else {
                    var i: usize = 0;
                    while (i + 1 < pts.len) : (i += 1) {
                        best = @min(best, segDist(px, py, pts[i], pts[i + 1]));
                        if (best <= half - 1.0) break; // fully covered already
                    }
                }
                self.blendCov(x, y, color, @max(0.0, @min(1.0, half - best + 0.5)));
            }
        }
    }

    /// Fast path: rasterize each segment into the mask (max coverage), then
    /// blend the whole stroke once and clear the touched region.
    fn strokeMasked(self: *Canvas, pts: anytype, half: f64, color: u32) void {
        const wu: usize = @intCast(self.w);
        var gx0: i32 = self.w;
        var gy0: i32 = self.h;
        var gx1: i32 = -1;
        var gy1: i32 = -1;

        const n_segs: usize = if (pts.len == 1) 1 else pts.len - 1;
        var i: usize = 0;
        while (i < n_segs) : (i += 1) {
            const a = pts[i];
            const b = if (pts.len == 1) pts[0] else pts[i + 1];
            const ext = half + 1.5;
            const ax: f64 = @floatFromInt(a.x);
            const ay: f64 = @floatFromInt(a.y);
            const bx: f64 = @floatFromInt(b.x);
            const by: f64 = @floatFromInt(b.y);
            const xs = span(@min(ax, bx) - ext, @max(ax, bx) + ext, self.w) orelse continue;
            const ys = span(@min(ay, by) - ext, @max(ay, by) + ext, self.h) orelse continue;
            gx0 = @min(gx0, xs[0]);
            gy0 = @min(gy0, ys[0]);
            gx1 = @max(gx1, xs[1]);
            gy1 = @max(gy1, ys[1]);
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
                    if (cv > self.mask[idx]) self.mask[idx] = cv;
                }
            }
        }
        if (gx1 < gx0) return;
        // single blend pass + mask clear over the touched bbox
        var y = gy0;
        while (y <= gy1) : (y += 1) {
            const row = @as(usize, @intCast(y)) * wu;
            var x = gx0;
            while (x <= gx1) : (x += 1) {
                const idx = row + @as(usize, @intCast(x));
                const cv = self.mask[idx];
                if (cv != 0) {
                    self.blendCov(x, y, color, @as(f64, @floatFromInt(cv)) / 255.0);
                    self.mask[idx] = 0;
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

    /// Anti-aliased filled triangle (3x3 supersampling on edge pixels;
    /// pixels whose four corners are all inside are filled directly).
    pub fn fillTriangleAA(self: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, color: u32) void {
        // orient counter-clockwise so "inside" means all edges >= 0
        var bx = x1;
        var by = y1;
        var cx = x2;
        var cy = y2;
        const area = edgeF(x0, y0, x1, y1, x2, y2);
        if (!(area != 0)) return; // degenerate or NaN
        if (area < 0) {
            bx = x2;
            by = y2;
            cx = x1;
            cy = y1;
        }
        const xs = span(@min(@min(x0, x1), x2) - 1, @max(@max(x0, x1), x2), self.w) orelse return;
        const ys = span(@min(@min(y0, y1), y2) - 1, @max(@max(y0, y1), y2), self.h) orelse return;
        const T = struct {
            fn inside(ax: f64, ay: f64, b_x: f64, b_y: f64, c_x: f64, c_y: f64, px: f64, py: f64) bool {
                return edgeF(b_x, b_y, c_x, c_y, px, py) >= 0 and edgeF(c_x, c_y, ax, ay, px, py) >= 0 and edgeF(ax, ay, b_x, b_y, px, py) >= 0;
            }
        };
        var y = ys[0];
        while (y <= ys[1]) : (y += 1) {
            const fy: f64 = @floatFromInt(y);
            var x = xs[0];
            while (x <= xs[1]) : (x += 1) {
                const fx: f64 = @floatFromInt(x);
                if (T.inside(x0, y0, bx, by, cx, cy, fx, fy) and T.inside(x0, y0, bx, by, cx, cy, fx + 1, fy) and
                    T.inside(x0, y0, bx, by, cx, cy, fx, fy + 1) and T.inside(x0, y0, bx, by, cx, cy, fx + 1, fy + 1))
                {
                    self.blend(x, y, color);
                    continue;
                }
                var hits: u32 = 0;
                var sy: u32 = 0;
                while (sy < 3) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < 3) : (sx += 1) {
                        const px = fx + (@as(f64, @floatFromInt(sx)) + 0.5) / 3.0;
                        const py = fy + (@as(f64, @floatFromInt(sy)) + 0.5) / 3.0;
                        if (T.inside(x0, y0, bx, by, cx, cy, px, py)) hits += 1;
                    }
                }
                if (hits > 0) self.blendCov(x, y, color, @as(f64, @floatFromInt(hits)) / 9.0);
            }
        }
    }

    fn edgeF(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    }

    /// Anti-aliased elliptic ring (ellipse outline). Each row walks in from
    /// the outer edge on both sides and stops once it has crossed the
    /// band, so the cost follows the outline, not the bounding box.
    pub fn ellipseRingAA(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: f64, color: u32) void {
        if (w < 2 or h < 2) return;
        const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
        const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
        const rx = @max(1.0, @as(f64, @floatFromInt(w)) / 2.0);
        const ry = @max(1.0, @as(f64, @floatFromInt(h)) / 2.0);
        const half = @min(@max(0.5, if (thickness > 0) thickness / 2.0 else 0.5), 1e6);
        // same footprint as a plain bounding-box scan: the box padded by
        // half + 2 (the approximate distance can reach past the ellipse
        // band near thin tips, so the box, not an ellipse, bounds the walk)
        const pad: f64 = @floor(half + 2);
        const fx0: f64 = @floatFromInt(x0);
        const fy0: f64 = @floatFromInt(y0);
        const ys = span(fy0 - pad, fy0 + @as(f64, @floatFromInt(h)) + pad, self.h) orelse return;
        const irx2 = 1.0 / (rx * rx);
        const iry2 = 1.0 / (ry * ry);
        var y = ys[0];
        while (y <= ys[1]) : (y += 1) {
            const py = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const left = span(fx0 - pad, cx, self.w);
            const right = span(cx, fx0 + @as(f64, @floatFromInt(w)) + pad, self.w);
            var left_end: i32 = -1; // last column the left walk looked at
            inline for (.{ true, false }) |is_left| {
                if (if (is_left) left else right) |xs| {
                    var seen = false;
                    var k: i32 = 0;
                    while (k <= xs[1] - xs[0]) : (k += 1) {
                        const x = if (is_left) xs[0] + k else xs[1] - k;
                        const px = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                        // approximate distance to the ellipse: f / |grad f|
                        const f = px * px * irx2 + py * py * iry2 - 1.0;
                        const gx = 2.0 * px * irx2;
                        const gy = 2.0 * py * iry2;
                        const g = @sqrt(gx * gx + gy * gy);
                        const cov = if (g < 1e-9) 0 else @max(0.0, @min(1.0, half - @abs(f) / g + 0.5));
                        if (!is_left and x <= left_end) break; // the left walk did it
                        if (is_left) left_end = x;
                        if (cov > 0.003) {
                            self.blendCov(x, y, color, cov);
                            seen = true;
                        } else if (seen) break;
                    }
                }
            }
        }
    }

    /// Anti-aliased arrow with filled head.
    pub fn arrowAA(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
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
        self.strokePolylineAA(seg[0..], tf, color);
        const px = -uy;
        const py = ux;
        self.fillTriangleAA(
            fx1,
            fy1,
            fx1 - ux * head + px * head * 0.45,
            fy1 - uy * head + py * head * 0.45,
            fx1 - ux * head - px * head * 0.45,
            fy1 - uy * head - py * head * 0.45,
            color,
        );
    }

    pub fn text(self: *Canvas, x0: i32, y0: i32, scale: i32, color: u32, s: []const u8) void {
        if (scale >= 2) {
            self.textSmooth(x0, y0, scale, color, s);
            return;
        }
        var pen_x = x0;
        var it = utf8.Iterator.init(s);
        while (it.next()) |cp| {
            if (pen_x >= self.w) break;
            const g = font.glyphFor(bitmapChar(cp));
            for (g, 0..) |row, gy| {
                var gx: u3 = 0;
                while (gx < font.glyph_w) : (gx += 1) {
                    if (row & (@as(u8, 0x10) >> gx) != 0) {
                        self.fillRect(
                            pen_x +| @as(i32, gx) *| scale,
                            y0 +| @as(i32, @intCast(gy)) *| scale,
                            scale,
                            scale,
                            color,
                        );
                    }
                }
            }
            pen_x +|= (font.glyph_w + 1) *| scale;
        }
    }

    /// EPX/Scale2x-smoothed text for even scales: doubles the glyph bitmap
    /// with diagonal interpolation, then draws blocks of scale/2. Removes the
    /// staircase look of the 5x7 font at display sizes.
    fn textSmooth(self: *Canvas, x0: i32, y0: i32, scale: i32, color: u32, s: []const u8) void {
        const ha = scale - @divTrunc(scale, 2); // first subcell (ceil)
        const hb = scale - ha; // second subcell
        var pen_x = x0;
        var it = utf8.Iterator.init(s);
        while (it.next()) |cp| {
            if (pen_x >= self.w) break;
            const g = font.glyphFor(bitmapChar(cp));
            const src = struct {
                fn at(glyph: *const font.Glyph, gx: i32, gy: i32) bool {
                    if (gx < 0 or gy < 0 or gx >= font.glyph_w or gy >= font.glyph_h) return false;
                    return glyph[@intCast(gy)] & (@as(u8, 0x10) >> @intCast(gx)) != 0;
                }
            }.at;
            var gy: i32 = 0;
            while (gy < font.glyph_h) : (gy += 1) {
                var gx: i32 = 0;
                while (gx < font.glyph_w) : (gx += 1) {
                    const p = src(g, gx, gy);
                    const a = src(g, gx, gy - 1); // up
                    const b = src(g, gx + 1, gy); // right
                    const cl = src(g, gx - 1, gy); // left
                    const d = src(g, gx, gy + 1); // down
                    // EPX expansion
                    var q = [4]bool{ p, p, p, p }; // tl, tr, bl, br
                    if (cl == a and cl != d and a != b) q[0] = a;
                    if (a == b and a != cl and b != d) q[1] = b;
                    if (d == cl and d != b and cl != a) q[2] = cl;
                    if (b == d and b != a and d != cl) q[3] = d;
                    const bx = pen_x +| gx *| scale;
                    const by = y0 +| gy *| scale;
                    if (q[0]) self.fillRect(bx, by, ha, ha, color);
                    if (q[1]) self.fillRect(bx +| ha, by, hb, ha, color);
                    if (q[2]) self.fillRect(bx, by +| ha, ha, hb, color);
                    if (q[3]) self.fillRect(bx +| ha, by +| ha, hb, hb, color);
                }
            }
            pen_x +|= (font.glyph_w + 1) *| scale;
        }
    }

    pub fn textWidth(scale: i32, s: []const u8) i32 {
        const n: i64 = @intCast(utf8.count(s));
        return @intCast(@min(std.math.maxInt(i32), n * (font.glyph_w + 1) * scale));
    }

    pub fn textHeight(scale: i32) i32 {
        return font.glyph_h * scale;
    }
};

test "fill and blend" {
    var pixels: [16]u32 = @splat(0xFF000000);
    var c = Canvas.init(&pixels, 4, 4);
    c.fillRect(0, 0, 2, 2, 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[3]);
    // 50% white over black ~ 0x7F gray
    c.fillRect(3, 3, 1, 1, 0x80FFFFFF);
    const p = pixels[15];
    try std.testing.expect(((p >> 16) & 0xFF) > 0x70 and ((p >> 16) & 0xFF) < 0x90);
}

/// Reference rasterizers: the plain bounding-box versions the optimized
/// primitives must match pixel for pixel.
const Ref = struct {
    fn circle(c: *Canvas, cx: f64, cy: f64, r: f64, color: u32) void {
        var y: i32 = -2;
        while (y < c.h + 2) : (y += 1) {
            var x: i32 = -2;
            while (x < c.w + 2) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                c.blendCov(x, y, color, @max(0.0, @min(1.0, r - @sqrt(dx * dx + dy * dy) + 0.5)));
            }
        }
    }
    fn ring(c: *Canvas, cx: f64, cy: f64, r: f64, ring_w: f64, color: u32) void {
        var y: i32 = 0;
        while (y < c.h) : (y += 1) {
            var x: i32 = 0;
            while (x < c.w) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const d = @abs(@sqrt(dx * dx + dy * dy) - r);
                c.blendCov(x, y, color, @max(0.0, @min(1.0, ring_w / 2.0 - d + 0.5)));
            }
        }
    }
    fn roundRect(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, radius: f64, color: u32) void {
        const fx0: f64 = @floatFromInt(x0);
        const fy0: f64 = @floatFromInt(y0);
        const fx1 = fx0 + @as(f64, @floatFromInt(w));
        const fy1 = fy0 + @as(f64, @floatFromInt(h));
        const r = @min(radius, @min(@as(f64, @floatFromInt(w)) / 2.0, @as(f64, @floatFromInt(h)) / 2.0));
        var y: i32 = 0;
        while (y < c.h) : (y += 1) {
            var x: i32 = 0;
            while (x < c.w) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                const qx = @max(@max(fx0 + r - px, px - (fx1 - r)), 0.0);
                const qy = @max(@max(fy0 + r - py, py - (fy1 - r)), 0.0);
                const d = @sqrt(qx * qx + qy * qy) - r;
                c.blendCov(x, y, color, @max(0.0, @min(1.0, -d + 0.5)));
            }
        }
    }
    fn ellipseRing(c: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: f64, color: u32) void {
        const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
        const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
        const rx = @max(1.0, @as(f64, @floatFromInt(w)) / 2.0);
        const ry = @max(1.0, @as(f64, @floatFromInt(h)) / 2.0);
        const half = @max(0.5, thickness / 2.0);
        const pad: i32 = @intFromFloat(half + 2);
        var y = y0 - pad;
        while (y <= y0 + h + pad) : (y += 1) {
            var x = x0 - pad;
            while (x <= x0 + w + pad) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const py = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const f = (px * px) / (rx * rx) + (py * py) / (ry * ry) - 1.0;
                const gx = 2.0 * px / (rx * rx);
                const gy = 2.0 * py / (ry * ry);
                const g = @sqrt(gx * gx + gy * gy);
                if (g < 1e-9) continue;
                c.blendCov(x, y, color, @max(0.0, @min(1.0, half - @abs(f) / g + 0.5)));
            }
        }
    }
};

/// Largest per-channel difference between two canvases.
fn maxDiff(a: []const u32, b: []const u32) u32 {
    var m: u32 = 0;
    for (a, b) |p, q| {
        var s: u5 = 0;
        while (s < 24) : (s += 8) {
            const x: i32 = @intCast((p >> s) & 0xFF);
            const y: i32 = @intCast((q >> s) & 0xFF);
            m = @max(m, @abs(x - y));
        }
    }
    return m;
}

test "anti-aliased primitives match their bounding-box references" {
    const W = 72;
    const H = 50;
    var a: [W * H]u32 = undefined;
    var b: [W * H]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    for (0..300) |_| {
        @memset(&a, 0xFF102030);
        @memset(&b, 0xFF102030);
        var ca = Canvas.init(&a, W, H);
        var cb = Canvas.init(&b, W, H);
        const color: u32 = if (r.boolean()) 0xFFE0C040 else 0x80E0C040;
        const fx = r.float(f64) * 120 - 24;
        const fy = r.float(f64) * 90 - 20;
        const rad = r.float(f64) * 40;
        const th = r.float(f64) * 12 + 0.2;
        const ix = r.intRangeAtMost(i32, -40, 80);
        const iy = r.intRangeAtMost(i32, -40, 60);
        const iw = r.intRangeAtMost(i32, 2, 100);
        const ih = r.intRangeAtMost(i32, 2, 80);
        const which = r.intRangeAtMost(u8, 0, 3);
        switch (which) {
            0 => {
                ca.fillCircleAA(fx, fy, rad, color);
                Ref.circle(&cb, fx, fy, rad, color);
            },
            1 => {
                ca.ringAA(fx, fy, rad, th, color);
                Ref.ring(&cb, fx, fy, rad, th, color);
            },
            2 => {
                ca.fillRoundRectAA(ix, iy, iw, ih, rad, color);
                Ref.roundRect(&cb, ix, iy, iw, ih, rad, color);
            },
            else => {
                ca.ellipseRingAA(ix, iy, iw, ih, th, color);
                Ref.ellipseRing(&cb, ix, iy, iw, ih, th, color);
            },
        }
        const md = maxDiff(&a, &b);
        if (md > 1) {
            std.debug.print("which={d} md={d} f=({d},{d}) rad={d} th={d} i=({d},{d},{d},{d}) col={x}\n", .{ which, md, fx, fy, rad, th, ix, iy, iw, ih, color });
            return error.Mismatch;
        }
    }
}

test "primitives at extreme coordinates stay in bounds" {
    var px: [8 * 6]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 8, 6);
    var mask: [8 * 6]u8 = @splat(0);
    const big = std.math.maxInt(i32);
    const small = std.math.minInt(i32);
    const ints = [_]i32{ small, -1_000_000, -5, 0, 3, 7, 1_000_000, big };
    const floats = [_]f64{ -1e300, -1e9, -3.5, 0, 4.2, 1e9, 1e300, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (ints) |a| for (ints) |b| {
        c.fillRect(a, b, big, big, 0x80FFFFFF);
        c.fillRect(a, b, a, b, 0xFFFFFFFF);
        c.rectOutline(a, b, big, 9, big, 0xFF00FF00);
        c.rectOutline(b, a, 9, 9, 3, 0x8000FF00);
        c.fillCircle(a, b, 3, 0xFF0000FF);
        c.fillCircle(3, 3, @min(big, @abs(b)), 0xFF0000FF);
        c.line(a, b, b, a, 5, 0xFFFFFFFF);
        c.line(a, b, 3, 3, 1, 0x80FFFFFF);
        c.line(a, b, 4, 2, 7, 0x80FFFFFF);
        c.arrow(a, b, 4, 4, 3, 0xFFFFFFFF);
        c.arrow(4, 4, a, b, big, 0xFFFFFFFF);
        c.fillTriangle(a, b, b, a, 4, 4, 0xFF123456);
        c.ellipseOutline(a, b, 20, 20, 3, 0xFFABCDEF);
        c.ellipseOutline(-10, -10, @min(big, @abs(a)), 30, 1, 0xFFABCDEF);
        c.pixelate(a, b, big, big, b);
        c.fillRoundRectAA(a, b, big, big, 1e300, 0xFF654321);
        c.fillRoundRectAA(a, 2, 5, 5, std.math.nan(f64), 0xFF654321);
        c.ellipseRingAA(a, b, 40, 40, 3, 0xFF00FFFF);
        c.ellipseRingAA(-100, -100, 400, 300, 1e9, 0x8000FFFF);
        c.arrowAA(a, b, 4, 4, 3, 0xFFFF00FF);
        c.arrowAA(4, 4, a, b, big, 0xFFFF00FF);
        c.text(a, b, 3, 0xFFFFFFFF, "Hi\xFF");
        c.text(2, 2, big, 0xFFFFFFFF, "x");
        const pts = [_]struct { x: i32, y: i32 }{ .{ .x = a, .y = b }, .{ .x = 3, .y = 3 }, .{ .x = b, .y = a } };
        c.mask = &.{};
        c.strokePolylineAA(pts[0..], 4, 0x80FFFFFF);
        c.mask = &mask;
        c.strokePolylineAA(pts[0..], 4, 0x80FFFFFF);
        c.strokePolylineAA(pts[0..], 1e300, 0x80FFFFFF);
    };
    for (floats) |f| for (floats) |g| {
        c.fillCircleAA(f, g, 3, 0xFFFFFFFF);
        c.fillCircleAA(3, 3, f, 0xFFFFFFFF);
        c.ringAA(f, g, 2, 1, 0xFFFFFFFF);
        c.ringAA(3, 3, f, g, 0xFFFFFFFF);
        c.fillTriangleAA(f, g, g, f, 4, 4, 0xFFFFFFFF);
        c.ellipseRingAA(1, 1, 6, 4, f, 0xFFFFFFFF);
        c.blendCov(2, 2, 0xFFFFFFFF, f);
    };
    for (mask) |m| try std.testing.expectEqual(@as(u8, 0), m);
}
