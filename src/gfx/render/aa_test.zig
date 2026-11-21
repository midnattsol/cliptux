//! The anti-aliased primitives checked pixel for pixel against plain
//! bounding-box reference rasterizers.

const std = @import("std");
const Canvas = @import("../render.zig").Canvas;

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
