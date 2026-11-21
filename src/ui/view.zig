//! A view maps image pixels onto a pixel buffer: buf = img * scale + off.
//! The editor keeps its whole document in image coordinates and renders
//! through one View per buffer, so rendering a given image rectangle into
//! a given buffer at a given scale is `resample` (plus overlays on top).
//! One View per monitor surface works the same way.

const std = @import("std");
const shapes = @import("shapes.zig");

pub const Rect = shapes.Rect;
pub const Point = shapes.Point;

/// Colour of buffer pixels that show no image (letterbox bars).
pub const letterbox: u32 = 0xFF101010;

pub const View = struct {
    scale: f64 = 1.0,
    /// buffer position of image pixel (0, 0); integers keep 1:1 crisp
    off_x: i32 = 0,
    off_y: i32 = 0,

    /// Centre an `iw`×`ih` image inside `area`, scaled to fit and never
    /// above `max_scale`.
    pub fn fit(iw: u32, ih: u32, area: Rect, max_scale: f64) View {
        const fw: f64 = @floatFromInt(@max(1, area.w));
        const fh: f64 = @floatFromInt(@max(1, area.h));
        const s = @min(max_scale, @min(fw / @as(f64, @floatFromInt(@max(1, iw))), fh / @as(f64, @floatFromInt(@max(1, ih)))));
        const dw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(iw)) * s));
        const dh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(ih)) * s));
        return .{
            .scale = s,
            .off_x = area.x + @divTrunc(area.w - dw, 2),
            .off_y = area.y + @divTrunc(area.h - dh, 2),
        };
    }

    pub fn xform(self: View) shapes.Xform {
        return .{ .scale = self.scale, .ox = @floatFromInt(self.off_x), .oy = @floatFromInt(self.off_y) };
    }

    /// Image point under buffer pixel `b` (the pixel containing its centre).
    pub fn toImg(self: View, b: Point) Point {
        return .{
            .x = @intFromFloat(@floor((@as(f64, @floatFromInt(b.x - self.off_x)) + 0.5) / self.scale)),
            .y = @intFromFloat(@floor((@as(f64, @floatFromInt(b.y - self.off_y)) + 0.5) / self.scale)),
        };
    }

    /// Image point nearest to the buffer pixel edge `b` (for rect corners).
    pub fn toImgEdge(self: View, b: Point) Point {
        return .{
            .x = @intFromFloat(@round(@as(f64, @floatFromInt(b.x - self.off_x)) / self.scale)),
            .y = @intFromFloat(@round(@as(f64, @floatFromInt(b.y - self.off_y)) / self.scale)),
        };
    }

    pub fn toBuf(self: View, p: Point) Point {
        return self.xform().pt(p);
    }

    /// Buffer rectangle showing image rect `r` (edges rounded).
    pub fn rectToBuf(self: View, r: Rect) Rect {
        return self.xform().rect(r);
    }

    /// Buffer rectangle covering every pixel image rect `r` affects.
    pub fn rectToBufOuter(self: View, r: Rect) Rect {
        const x0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(r.x)) * self.scale));
        const y0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(r.y)) * self.scale));
        const x1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.right())) * self.scale));
        const y1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.bottom())) * self.scale));
        return (Rect{ .x = x0 + self.off_x, .y = y0 + self.off_y, .w = x1 - x0, .h = y1 - y0 }).expand(1);
    }

    /// Image length of `px` buffer pixels.
    pub fn lenToImg(self: View, px: f64) f64 {
        return px / self.scale;
    }

    /// Supersamples per axis when shrinking, so thin strokes don't vanish.
    fn taps(self: View) u32 {
        if (self.scale >= 1.0) return 1;
        return @min(4, @as(u32, @intFromFloat(@ceil(1.0 / self.scale - 1e-9))));
    }
};

/// Render the image `src` (sw×sh) into `dst` (dw×dh) through `view`,
/// touching only `region` (buffer coordinates). Pixels outside the image
/// get `letterbox`. Shrinking averages a small grid of samples; enlarging
/// picks the nearest pixel, so zoomed screenshots stay sharp.
pub fn resample(src: []const u32, sw: u32, sh: u32, view: View, dst: []u32, dw: u32, dh: u32, region: Rect) void {
    @setRuntimeSafety(false);
    const r = Rect.intersect(region, .{ .x = 0, .y = 0, .w = @intCast(dw), .h = @intCast(dh) }) orelse return;
    const n = view.taps();
    const inv = 1.0 / view.scale;
    const swi: i64 = sw;
    const shi: i64 = sh;
    // fixed-point (16.16) source coordinates for each sub-sample
    const step: i64 = @intFromFloat(@round(inv * 65536.0));
    const sub: i64 = @divTrunc(step, n);
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        const row = dst[@as(usize, @intCast(y)) * dw ..][0..dw];
        const fy0: i64 = @intFromFloat(@round((@as(f64, @floatFromInt(y - view.off_y))) * inv * 65536.0));
        var x = r.x;
        const fx_base: i64 = @intFromFloat(@round((@as(f64, @floatFromInt(r.x - view.off_x))) * inv * 65536.0));
        var fx0 = fx_base;
        while (x < r.right()) : ({
            x += 1;
            fx0 += step;
        }) {
            if (n == 1) {
                const sx = (fx0 + @divTrunc(step, 2)) >> 16;
                const sy = (fy0 + @divTrunc(step, 2)) >> 16;
                row[@intCast(x)] = if (sx < 0 or sy < 0 or sx >= swi or sy >= shi)
                    letterbox
                else
                    src[@intCast(sy * swi + sx)];
                continue;
            }
            var acc_r: u32 = 0;
            var acc_g: u32 = 0;
            var acc_b: u32 = 0;
            var cnt: u32 = 0;
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                const sy = (fy0 + sub * j + @divTrunc(sub, 2)) >> 16;
                if (sy < 0 or sy >= shi) continue;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const sx = (fx0 + sub * i + @divTrunc(sub, 2)) >> 16;
                    if (sx < 0 or sx >= swi) continue;
                    const p = src[@intCast(sy * swi + sx)];
                    acc_r += (p >> 16) & 0xFF;
                    acc_g += (p >> 8) & 0xFF;
                    acc_b += p & 0xFF;
                    cnt += 1;
                }
            }
            row[@intCast(x)] = if (cnt == 0)
                letterbox
            else
                0xFF000000 | (acc_r / cnt) << 16 | (acc_g / cnt) << 8 | (acc_b / cnt);
        }
    }
}

test "fit centres and caps the scale" {
    const v = View.fit(1000, 500, .{ .x = 0, .y = 0, .w = 500, .h = 500 }, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), v.scale, 1e-9);
    try std.testing.expectEqual(@as(i32, 0), v.off_x);
    try std.testing.expectEqual(@as(i32, 125), v.off_y);
    const small = View.fit(100, 100, .{ .x = 0, .y = 0, .w = 500, .h = 300 }, 1.0);
    try std.testing.expectEqual(@as(f64, 1.0), small.scale);
    try std.testing.expectEqual(@as(i32, 200), small.off_x);
    const zoom = View.fit(100, 100, .{ .x = 0, .y = 0, .w = 500, .h = 300 }, 8.0);
    try std.testing.expectEqual(@as(f64, 3.0), zoom.scale);
}

test "view round trips image points" {
    const views = [_]View{
        .{ .scale = 1.0, .off_x = 7, .off_y = -3 },
        .{ .scale = 0.5, .off_x = 0, .off_y = 40 },
        .{ .scale = 2.0, .off_x = 10, .off_y = 10 },
        .{ .scale = 0.8333, .off_x = 3, .off_y = 0 },
        .{ .scale = 1.25, .off_x = 0, .off_y = 0 },
    };
    for (views) |v| {
        // integer image points map to buffer pixels that map back (when not shrinking)
        for ([_]i32{ 0, 1, 17, 640, 1919 }) |c| {
            const b = v.toBuf(.{ .x = c, .y = c });
            const back = v.toImgEdge(b);
            const tol: i32 = if (v.scale < 1) @intFromFloat(@ceil(1.0 / v.scale)) else 0;
            try std.testing.expect(@abs(back.x - c) <= tol);
            try std.testing.expect(@abs(back.y - c) <= tol);
        }
    }
}

test "resample: letterbox outside, nearest when enlarging, average when shrinking" {
    const src = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF };
    var dst: [6 * 2]u32 = @splat(0);
    // 2x1 image at scale 2 with offset 1
    resample(src[0..2], 2, 1, .{ .scale = 2, .off_x = 1, .off_y = 0 }, &dst, 6, 2, .{ .x = 0, .y = 0, .w = 6, .h = 2 });
    try std.testing.expectEqual(letterbox, dst[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), dst[1]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), dst[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), dst[3]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), dst[4]);
    try std.testing.expectEqual(letterbox, dst[5]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), dst[6 + 1]);

    // 4x1 image at scale 0.5: each output averages two pixels
    var small: [2]u32 = @splat(0);
    resample(&src, 4, 1, .{ .scale = 0.5 }, &small, 2, 1, .{ .x = 0, .y = 0, .w = 2, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), small[0]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), small[1]);

    // only the region is written
    var part: [4]u32 = @splat(0x12345678);
    resample(&src, 4, 1, .{}, &part, 4, 1, .{ .x = 1, .y = 0, .w = 2, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0x12345678), part[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), part[1]);
    try std.testing.expectEqual(@as(u32, 0x12345678), part[3]);
}
