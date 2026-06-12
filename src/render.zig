//! Software renderer over a 0xAARRGGBB pixel canvas: shapes, blending,
//! pixelation, text. All drawing is clipped to the canvas bounds.

const std = @import("std");
const font = @import("font.zig");

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

    pub fn fillRect(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
        const xa = @max(0, x0);
        const ya = @max(0, y0);
        const xb = @min(self.w, x0 + w);
        const yb = @min(self.h, y0 + h);
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
        const t = @max(1, thickness);
        self.fillRect(x0, y0, w, t, color); // top
        self.fillRect(x0, y0 + h - t, w, t, color); // bottom
        self.fillRect(x0, y0 + t, t, h - 2 * t, color); // left
        self.fillRect(x0 + w - t, y0 + t, t, h - 2 * t, color); // right
    }

    /// Stamp a filled disc (used as line brush).
    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, r: i32, color: u32) void {
        var dy = -r;
        while (dy <= r) : (dy += 1) {
            var dx = -r;
            while (dx <= r) : (dx += 1) {
                if (dx * dx + dy * dy <= r * r) self.blend(cx + dx, cy + dy, color);
            }
        }
    }

    /// Thick line: disc stamped along the segment. For 1px uses Bresenham.
    pub fn line(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, thickness: i32, color: u32) void {
        const r = @divTrunc(@max(1, thickness), 2);
        const dx: f64 = @floatFromInt(x1 - x0);
        const dy: f64 = @floatFromInt(y1 - y0);
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.5) {
            if (thickness <= 1) self.blend(x0, y0, color) else self.fillCircle(x0, y0, r, color);
            return;
        }
        const steps: usize = @intFromFloat(@max(1.0, len));
        var i: usize = 0;
        // for translucent colors, avoid double-blending: collect via mask for thick strokes
        if ((color >> 24) != 255 and thickness > 1) {
            self.thickLineMasked(x0, y0, x1, y1, r, color);
            return;
        }
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const x: i32 = x0 + @as(i32, @intFromFloat(@round(dx * t)));
            const y: i32 = y0 + @as(i32, @intFromFloat(@round(dy * t)));
            if (thickness <= 1) self.blend(x, y, color) else self.fillCircle(x, y, r, color);
        }
    }

    /// Translucent thick line without overdraw: distance-to-segment test
    /// inside the bounding box.
    fn thickLineMasked(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, r: i32, color: u32) void {
        const xa = @max(0, @min(x0, x1) - r);
        const ya = @max(0, @min(y0, y1) - r);
        const xb = @min(self.w - 1, @max(x0, x1) + r);
        const yb = @min(self.h - 1, @max(y0, y1) + r);
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
        const dxf: f64 = @floatFromInt(x1 - x0);
        const dyf: f64 = @floatFromInt(y1 - y0);
        const len = @sqrt(dxf * dxf + dyf * dyf);
        if (len < 1) return;
        const head = @max(10.0, @as(f64, @floatFromInt(thickness)) * 4.0);
        const ux = dxf / len;
        const uy = dyf / len;
        // shorten shaft so it doesn't poke through the head
        const sx1: i32 = x1 - @as(i32, @intFromFloat(ux * head * 0.6));
        const sy1: i32 = y1 - @as(i32, @intFromFloat(uy * head * 0.6));
        self.line(x0, y0, sx1, sy1, thickness, color);
        // filled triangle head
        const px = -uy;
        const py = ux;
        const bx1: f64 = @as(f64, @floatFromInt(x1)) - ux * head + px * head * 0.5;
        const by1: f64 = @as(f64, @floatFromInt(y1)) - uy * head + py * head * 0.5;
        const bx2: f64 = @as(f64, @floatFromInt(x1)) - ux * head - px * head * 0.5;
        const by2: f64 = @as(f64, @floatFromInt(y1)) - uy * head - py * head * 0.5;
        self.fillTriangle(
            x1,
            y1,
            @intFromFloat(bx1),
            @intFromFloat(by1),
            @intFromFloat(bx2),
            @intFromFloat(by2),
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

    fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
        return @as(i64, bx - ax) * @as(i64, py - ay) - @as(i64, by - ay) * @as(i64, px - ax);
    }

    pub fn ellipseOutline(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: i32, color: u32) void {
        if (w < 2 or h < 2) return;
        const cx = @as(f64, @floatFromInt(x0)) + @as(f64, @floatFromInt(w)) / 2.0;
        const cy = @as(f64, @floatFromInt(y0)) + @as(f64, @floatFromInt(h)) / 2.0;
        const rx = @as(f64, @floatFromInt(w)) / 2.0;
        const ry = @as(f64, @floatFromInt(h)) / 2.0;
        const r = @divTrunc(@max(1, thickness), 2);
        const circumference = 2.0 * std.math.pi * @max(rx, ry);
        const steps: usize = @intFromFloat(@max(16.0, circumference));
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const x: i32 = @intFromFloat(cx + rx * @cos(a));
            const y: i32 = @intFromFloat(cy + ry * @sin(a));
            if (thickness <= 1) self.set(x, y, color) else self.fillCircle(x, y, r, color | 0xFF000000);
        }
    }

    /// Mosaic the region with block averages (privacy redaction).
    pub fn pixelate(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, block: i32) void {
        const xa = @max(0, x0);
        const ya = @max(0, y0);
        const xb = @min(self.w, x0 + w);
        const yb = @min(self.h, y0 + h);
        if (xa >= xb or ya >= yb) return;
        const blk = @max(2, block);
        var by = ya;
        while (by < yb) : (by += blk) {
            var bx = xa;
            while (bx < xb) : (bx += blk) {
                const ex = @min(bx + blk, xb);
                const ey = @min(by + blk, yb);
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
                    var x = bx;
                    while (x < ex) : (x += 1) {
                        self.px[@intCast(y * self.w + x)] = avg;
                    }
                }
            }
        }
    }

    // --- anti-aliased primitives ---

    /// Blend with an extra coverage factor in [0,1].
    pub inline fn blendCov(self: *Canvas, x: i32, y: i32, color: u32, cov: f64) void {
        if (cov <= 0.003) return;
        const a: f64 = @floatFromInt(color >> 24);
        const scaled: u32 = @intFromFloat(@min(255.0, a * cov));
        self.blend(x, y, (color & 0x00FFFFFF) | (scaled << 24));
    }

    /// Anti-aliased filled disc.
    pub fn fillCircleAA(self: *Canvas, cx: f64, cy: f64, r: f64, color: u32) void {
        const x0: i32 = @intFromFloat(@floor(cx - r - 1));
        const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
        const y0: i32 = @intFromFloat(@floor(cy - r - 1));
        const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(dx * dx + dy * dy);
                self.blendCov(x, y, color, @max(0.0, @min(1.0, r - d + 0.5)));
            }
        }
    }

    /// Anti-aliased ring (circle outline).
    pub fn ringAA(self: *Canvas, cx: f64, cy: f64, r: f64, ring_w: f64, color: u32) void {
        const half = ring_w / 2.0;
        const x0: i32 = @intFromFloat(@floor(cx - r - half - 1));
        const x1: i32 = @intFromFloat(@ceil(cx + r + half + 1));
        const y0: i32 = @intFromFloat(@floor(cy - r - half - 1));
        const y1: i32 = @intFromFloat(@ceil(cy + r + half + 1));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
                const d = @abs(@sqrt(dx * dx + dy * dy) - r);
                self.blendCov(x, y, color, @max(0.0, @min(1.0, half - d + 0.5)));
            }
        }
    }

    /// Anti-aliased rounded rectangle fill.
    pub fn fillRoundRectAA(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, radius: f64, color: u32) void {
        if (w <= 0 or h <= 0) return;
        const fx0: f64 = @floatFromInt(x0);
        const fy0: f64 = @floatFromInt(y0);
        const fx1 = fx0 + @as(f64, @floatFromInt(w));
        const fy1 = fy0 + @as(f64, @floatFromInt(h));
        const r = @min(radius, @min(@as(f64, @floatFromInt(w)) / 2.0, @as(f64, @floatFromInt(h)) / 2.0));
        var y = y0 - 1;
        while (y <= y0 + h) : (y += 1) {
            var x = x0 - 1;
            while (x <= x0 + w) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                // signed distance to the rounded rect
                const qx = @max(@max(fx0 + r - px, px - (fx1 - r)), 0.0);
                const qy = @max(@max(fy0 + r - py, py - (fy1 - r)), 0.0);
                const d = @sqrt(qx * qx + qy * qy) - r;
                self.blendCov(x, y, color, @max(0.0, @min(1.0, -d + 0.5)));
            }
        }
    }

    /// Anti-aliased capsule stroke over a polyline with no self-overlap
    /// artifacts. With a mask buffer attached the cost is linear in stroke
    /// length (per-segment rasterization, max-coverage accumulation).
    pub fn strokePolylineAA(self: *Canvas, pts: anytype, width: f64, color: u32) void {
        if (pts.len == 0) return;
        const half = @max(0.5, width / 2.0);
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
        const x0: i32 = @intFromFloat(@floor(minx - half - 1));
        const x1: i32 = @intFromFloat(@ceil(maxx + half + 1));
        const y0: i32 = @intFromFloat(@floor(miny - half - 1));
        const y1: i32 = @intFromFloat(@ceil(maxy + half + 1));
        var y = @max(0, y0);
        const yend = @min(self.h - 1, y1);
        const xstart = @max(0, x0);
        const xend = @min(self.w - 1, x1);
        while (y <= yend) : (y += 1) {
            var x = xstart;
            while (x <= xend) : (x += 1) {
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
            const x0 = @max(0, @min(a.x, b.x) - @as(i32, @intFromFloat(half + 1.5)));
            const y0 = @max(0, @min(a.y, b.y) - @as(i32, @intFromFloat(half + 1.5)));
            const x1 = @min(self.w - 1, @max(a.x, b.x) + @as(i32, @intFromFloat(half + 1.5)));
            const y1 = @min(self.h - 1, @max(a.y, b.y) + @as(i32, @intFromFloat(half + 1.5)));
            if (x0 > x1 or y0 > y1) continue;
            gx0 = @min(gx0, x0);
            gy0 = @min(gy0, y0);
            gx1 = @max(gx1, x1);
            gy1 = @max(gy1, y1);
            var y = y0;
            while (y <= y1) : (y += 1) {
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                var x = x0;
                while (x <= x1) : (x += 1) {
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

    /// Anti-aliased filled triangle (3x3 supersampling).
    pub fn fillTriangleAA(self: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, x2: f64, y2: f64, color: u32) void {
        const xa: i32 = @intFromFloat(@floor(@min(@min(x0, x1), x2)));
        const ya: i32 = @intFromFloat(@floor(@min(@min(y0, y1), y2)));
        const xb: i32 = @intFromFloat(@ceil(@max(@max(x0, x1), x2)));
        const yb: i32 = @intFromFloat(@ceil(@max(@max(y0, y1), y2)));
        var y = ya;
        while (y <= yb) : (y += 1) {
            var x = xa;
            while (x <= xb) : (x += 1) {
                var hits: u32 = 0;
                var sy: u32 = 0;
                while (sy < 3) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < 3) : (sx += 1) {
                        const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 3.0;
                        const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 3.0;
                        const w0 = edgeF(x1, y1, x2, y2, px, py);
                        const w1 = edgeF(x2, y2, x0, y0, px, py);
                        const w2 = edgeF(x0, y0, x1, y1, px, py);
                        if ((w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0)) hits += 1;
                    }
                }
                if (hits > 0) self.blendCov(x, y, color, @as(f64, @floatFromInt(hits)) / 9.0);
            }
        }
    }

    fn edgeF(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    }

    /// Anti-aliased elliptic ring (ellipse outline).
    pub fn ellipseRingAA(self: *Canvas, x0: i32, y0: i32, w: i32, h: i32, thickness: f64, color: u32) void {
        if (w < 2 or h < 2) return;
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
                // approximate signed distance to the ellipse: f / |grad f|
                const f = (px * px) / (rx * rx) + (py * py) / (ry * ry) - 1.0;
                const gx = 2.0 * px / (rx * rx);
                const gy = 2.0 * py / (ry * ry);
                const g = @sqrt(gx * gx + gy * gy);
                if (g < 1e-9) continue;
                const d = @abs(f) / g;
                self.blendCov(x, y, color, @max(0.0, @min(1.0, half - d + 0.5)));
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
        const sx1: i32 = @intFromFloat(fx1 - ux * head * 0.7);
        const sy1: i32 = @intFromFloat(fy1 - uy * head * 0.7);
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
        for (s) |c| {
            const g = font.glyphFor(c);
            for (g, 0..) |row, gy| {
                var gx: u3 = 0;
                while (gx < font.glyph_w) : (gx += 1) {
                    if (row & (@as(u8, 0x10) >> gx) != 0) {
                        self.fillRect(
                            pen_x + @as(i32, gx) * scale,
                            y0 + @as(i32, @intCast(gy)) * scale,
                            scale,
                            scale,
                            color,
                        );
                    }
                }
            }
            pen_x += (font.glyph_w + 1) * scale;
        }
    }

    /// EPX/Scale2x-smoothed text for even scales: doubles the glyph bitmap
    /// with diagonal interpolation, then draws blocks of scale/2. Removes the
    /// staircase look of the 5x7 font at display sizes.
    fn textSmooth(self: *Canvas, x0: i32, y0: i32, scale: i32, color: u32, s: []const u8) void {
        const ha = scale - @divTrunc(scale, 2); // first subcell (ceil)
        const hb = scale - ha; // second subcell
        var pen_x = x0;
        for (s) |c| {
            const g = font.glyphFor(c);
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
                    const bx = pen_x + gx * scale;
                    const by = y0 + gy * scale;
                    if (q[0]) self.fillRect(bx, by, ha, ha, color);
                    if (q[1]) self.fillRect(bx + ha, by, hb, ha, color);
                    if (q[2]) self.fillRect(bx, by + ha, ha, hb, color);
                    if (q[3]) self.fillRect(bx + ha, by + ha, hb, hb, color);
                }
            }
            pen_x += (font.glyph_w + 1) * scale;
        }
    }

    pub fn textWidth(scale: i32, s: []const u8) i32 {
        return @as(i32, @intCast(s.len)) * (font.glyph_w + 1) * scale;
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
