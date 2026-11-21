//! The optimized effects checked against straightforward reference
//! versions.

const std = @import("std");
const Rect = @import("rect.zig").Rect;
const clip = @import("rect.zig").clip;
const boxBlur = @import("blur.zig").boxBlur;
const composite = @import("composite.zig");
const over = composite.over;
const mix = composite.mix;
const gradient = composite.gradient;
const dropShadow = composite.dropShadow;
const blitRounded = composite.blitRounded;

/// The straightforward versions the optimized effects must match.
const Ref = struct {
    fn overScalar(dst: u32, src: u32) u32 {
        const sa = (src >> 24) & 0xFF;
        if (sa == 0) return dst;
        if (sa == 255) return src;
        const inv = 255 - sa;
        var out: u32 = 0;
        var shift: u5 = 0;
        while (shift < 24) : (shift += 8) {
            const s = (src >> shift) & 0xFF;
            const d = (dst >> shift) & 0xFF;
            out |= ((s * sa + d * inv) / 255) << shift;
        }
        const da = (dst >> 24) & 0xFF;
        return out | ((sa + da * inv / 255) << 24);
    }

    fn boxPass(pixels: []u32, w: u32, h: u32, c: Rect, rad: i32, tmp: []u32, horizontal: bool) void {
        const cw: usize = @intCast(c.w);
        const iw: i32 = @intCast(w);
        const ih: i32 = @intCast(h);
        var y: i32 = c.y;
        while (y < c.y + c.h) : (y += 1) {
            var x: i32 = c.x;
            while (x < c.x + c.w) : (x += 1) {
                var acc: [4]u32 = .{ 0, 0, 0, 0 };
                var k: i32 = -rad;
                while (k <= rad) : (k += 1) {
                    const sx = if (horizontal) std.math.clamp(x + k, 0, iw - 1) else x;
                    const sy = if (horizontal) y else std.math.clamp(y + k, 0, ih - 1);
                    const p = pixels[@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))];
                    acc[0] += (p >> 24) & 0xFF;
                    acc[1] += (p >> 16) & 0xFF;
                    acc[2] += (p >> 8) & 0xFF;
                    acc[3] += p & 0xFF;
                }
                const n: u32 = @intCast(2 * rad + 1);
                tmp[@as(usize, @intCast(y - c.y)) * cw + @as(usize, @intCast(x - c.x))] =
                    ((acc[0] / n) << 24) | ((acc[1] / n) << 16) | ((acc[2] / n) << 8) | (acc[3] / n);
            }
        }
        var row: usize = 0;
        while (row < @as(usize, @intCast(c.h))) : (row += 1) {
            const dst = (@as(usize, @intCast(c.y)) + row) * w + @as(usize, @intCast(c.x));
            @memcpy(pixels[dst..][0..cw], tmp[row * cw ..][0..cw]);
        }
    }

    fn blur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, r: Rect, radius: u32) !void {
        const c = clip(r, w, h) orelse return;
        const tmp = try alloc.alloc(u32, @intCast(c.w * c.h));
        defer alloc.free(tmp);
        for (0..3) |_| {
            boxPass(pixels, w, h, c, @intCast(radius), tmp, true);
            boxPass(pixels, w, h, c, @intCast(radius), tmp, false);
        }
    }

    fn gradient(pixels: []u32, w: u32, h: u32, r: Rect, from: u32, to: u32) void {
        const c = clip(r, w, h) orelse return;
        const span: f32 = @floatFromInt(@max(1, r.w + r.h - 2));
        var y: i32 = c.y;
        while (y < c.y + c.h) : (y += 1) {
            var x: i32 = c.x;
            while (x < c.x + c.w) : (x += 1) {
                const t: f32 = @as(f32, @floatFromInt((x - r.x) + (y - r.y))) / span;
                pixels[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))] = mix(from, to, t);
            }
        }
    }

    fn dropShadow(pixels: []u32, w: u32, h: u32, r: Rect, blur_px: u32, offset_y: i32, color: u32) void {
        const b: i32 = @intCast(blur_px);
        const outer: Rect = .{ .x = r.x - b, .y = r.y - b + offset_y, .w = r.w + 2 * b, .h = r.h + 2 * b };
        const c = clip(outer, w, h) orelse return;
        const base_a: f32 = @floatFromInt((color >> 24) & 0xFF);
        var y: i32 = c.y;
        while (y < c.y + c.h) : (y += 1) {
            var x: i32 = c.x;
            while (x < c.x + c.w) : (x += 1) {
                const dx = @max(@max(r.x - x, x - (r.x + r.w - 1)), 0);
                const dy = @max(@max(r.y + offset_y - y, y - (r.y + offset_y + r.h - 1)), 0);
                const d = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
                if (b > 0 and d >= @as(f32, @floatFromInt(b))) continue;
                const fall = if (b == 0) 1.0 else 1.0 - d / @as(f32, @floatFromInt(b));
                const a: u32 = @intFromFloat(base_a * fall * fall);
                const i = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
                pixels[i] = over(pixels[i], (a << 24) | (color & 0xFFFFFF));
            }
        }
    }

    fn blitRounded(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, radius: u32) void {
        const c = clip(.{ .x = x, .y = y, .w = @intCast(sw), .h = @intCast(sh) }, dw, dh) orelse return;
        const rad: f32 = @floatFromInt(@min(radius, @min(sw, sh) / 2));
        const fw: f32 = @floatFromInt(sw);
        const fh: f32 = @floatFromInt(sh);
        var dy: i32 = c.y;
        while (dy < c.y + c.h) : (dy += 1) {
            var dx: i32 = c.x;
            while (dx < c.x + c.w) : (dx += 1) {
                const sx: usize = @intCast(dx - x);
                const sy: usize = @intCast(dy - y);
                const p = src[sy * sw + sx];
                const di = @as(usize, @intCast(dy)) * dw + @as(usize, @intCast(dx));
                const px = @as(f32, @floatFromInt(sx)) + 0.5;
                const py = @as(f32, @floatFromInt(sy)) + 0.5;
                const qx = @max(rad - px, px - (fw - rad), 0);
                const qy = @max(rad - py, py - (fh - rad), 0);
                const cov = if (qx == 0 or qy == 0 or rad == 0) 1.0 else std.math.clamp(rad - @sqrt(qx * qx + qy * qy) + 0.5, 0, 1);
                if (cov >= 1.0) {
                    dst[di] = p;
                } else if (cov > 0) {
                    const a: u32 = @intFromFloat(@as(f32, @floatFromInt((p >> 24) & 0xFF)) * cov);
                    dst[di] = over(dst[di], (a << 24) | (p & 0xFFFFFF));
                }
            }
        }
    }
};

test "over matches the per-channel formula" {
    var sa: u32 = 0;
    while (sa < 256) : (sa += 1) {
        var v: u32 = 0;
        while (v < 256) : (v += 5) {
            const src = (sa << 24) | (v << 16) | ((255 - v) << 8) | (v / 2);
            for ([_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF000000 | v * 0x010101 }) |dst| {
                try std.testing.expectEqual(Ref.overScalar(dst, src), over(dst, src));
            }
            // translucent destinations use straight alpha: colour is the
            // alpha-weighted mix, alpha is the usual union
            for ([_]u32{ 0x80123456, 0x00FEDCBA }) |dst| {
                const got = over(dst, src);
                if (sa == 0) {
                    try std.testing.expectEqual(dst, got);
                    continue;
                }
                const da = dst >> 24;
                const dw = da * (255 - sa) / 255;
                try std.testing.expectEqual(sa + dw, got >> 24);
                const oa = sa + dw;
                const want_r = (((src >> 16) & 0xFF) * sa + ((dst >> 16) & 0xFF) * dw + oa / 2) / oa;
                try std.testing.expectEqual(@min(want_r, 255), (got >> 16) & 0xFF);
            }
        }
    }
}

fn randomImage(px: []u32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    for (px) |*p| p.* = prng.random().int(u32) | 0xFF000000;
}

test "optimized effects match the straightforward versions" {
    const alloc = std.testing.allocator;
    const W = 37;
    const H = 29;
    var a: [W * H]u32 = undefined;
    var b: [W * H]u32 = undefined;
    var src: [13 * 11]u32 = undefined;
    var prng = std.Random.DefaultPrng.init(5);
    const r = prng.random();
    for (0..200) |it| {
        randomImage(&a, it);
        b = a;
        const rect: Rect = .{
            .x = r.intRangeAtMost(i32, -20, 40),
            .y = r.intRangeAtMost(i32, -20, 30),
            .w = r.intRangeAtMost(i32, 1, 50),
            .h = r.intRangeAtMost(i32, 1, 40),
        };
        switch (it % 4) {
            0 => {
                const rad = r.intRangeAtMost(u32, 1, 20);
                const c = clip(rect, W, H) orelse continue;
                try boxBlur(alloc, &a, W, H, c, rad);
                try Ref.blur(alloc, &b, W, H, rect, rad);
            },
            1 => {
                const from = r.int(u32);
                const to = r.int(u32);
                gradient(&a, W, H, rect, from, to);
                Ref.gradient(&b, W, H, rect, from, to);
            },
            2 => {
                const blur_px = r.intRangeAtMost(u32, 0, 12);
                const off = r.intRangeAtMost(i32, -5, 9);
                dropShadow(&a, W, H, rect, blur_px, off, 0x90102030);
                Ref.dropShadow(&b, W, H, rect, blur_px, off, 0x90102030);
            },
            else => {
                randomImage(&src, it + 1000);
                for (&src) |*p| p.* &= 0xC0FFFFFF; // translucent too
                const rad = r.intRangeAtMost(u32, 0, 9);
                blitRounded(&a, W, H, &src, 13, 11, rect.x, rect.y, rad);
                Ref.blitRounded(&b, W, H, &src, 13, 11, rect.x, rect.y, rad);
            },
        }
        try std.testing.expectEqualSlices(u32, &b, &a);
    }
}
