//! Pixel conversions for the video encoders: 0xAARRGGBB to planar
//! YUV 4:2:0 (BT.709, limited range, as players assume for HD video),
//! and box downscaling for GIFs with a maximum width.

const std = @import("std");

pub const Planes = struct {
    y: [*]u8,
    u: [*]u8,
    v: [*]u8,
    y_stride: usize,
    u_stride: usize,
    v_stride: usize,
};

/// BT.709 limited range, 8-bit fixed point (x256).
inline fn lumaOf(r: i32, g: i32, b: i32) u8 {
    return @intCast((47 * r + 157 * g + 16 * b + 128 >> 8) + 16);
}

/// Convert w x h pixels (`stride` per row; w and h even) into `p`.
pub fn toI420(px: []const u32, stride: usize, w: usize, h: usize, p: Planes) void {
    std.debug.assert(w % 2 == 0 and h % 2 == 0);
    var y: usize = 0;
    while (y < h) : (y += 2) {
        const r0 = px[y * stride ..][0..w];
        const r1 = px[(y + 1) * stride ..][0..w];
        const y0 = p.y[y * p.y_stride ..][0..w];
        const y1 = p.y[(y + 1) * p.y_stride ..][0..w];
        const uo = p.u[(y / 2) * p.u_stride ..][0 .. w / 2];
        const vo = p.v[(y / 2) * p.v_stride ..][0 .. w / 2];
        var x: usize = 0;
        while (x < w) : (x += 2) {
            var rs: i32 = 0;
            var gs: i32 = 0;
            var bs: i32 = 0;
            inline for (.{ .{ r0, y0 }, .{ r1, y1 } }) |pair| {
                inline for (0..2) |k| {
                    const c = pair[0][x + k];
                    const r: i32 = @intCast((c >> 16) & 0xFF);
                    const g: i32 = @intCast((c >> 8) & 0xFF);
                    const b: i32 = @intCast(c & 0xFF);
                    pair[1][x + k] = lumaOf(r, g, b);
                    rs += r;
                    gs += g;
                    bs += b;
                }
            }
            // averages of the 2x2 block, x4 folded into the shifts
            uo[x / 2] = @intCast(((-26 * rs - 86 * gs + 112 * bs + 512) >> 10) + 128);
            vo[x / 2] = @intCast(((112 * rs - 102 * gs - 10 * bs + 512) >> 10) + 128);
        }
    }
}

/// Back to RGB (tests, previews of decoded frames).
pub fn pixelOf(yv: u8, u: u8, v: u8) u32 {
    const c = @as(i32, yv) - 16;
    const d = @as(i32, u) - 128;
    const e = @as(i32, v) - 128;
    const r = std.math.clamp((298 * c + 459 * e + 128) >> 8, 0, 255);
    const g = std.math.clamp((298 * c - 55 * d - 136 * e + 128) >> 8, 0, 255);
    const b = std.math.clamp((298 * c + 541 * d + 128) >> 8, 0, 255);
    return 0xFF000000 | @as(u32, @intCast(r)) << 16 | @as(u32, @intCast(g)) << 8 | @as(u32, @intCast(b));
}

/// Area-average downscale of sw x sh (stride `ss`) into dw x dh.
pub fn downscale(src: []const u32, ss: usize, sw: usize, sh: usize, dst: []u32, dw: usize, dh: usize) void {
    for (0..dh) |dy| {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        for (0..dw) |dx| {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            var acc: [3]u32 = @splat(0);
            for (y0..y1) |yy| for (src[yy * ss + x0 .. yy * ss + x1]) |c| {
                acc[0] += (c >> 16) & 0xFF;
                acc[1] += (c >> 8) & 0xFF;
                acc[2] += c & 0xFF;
            };
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            dst[dy * dw + dx] = 0xFF000000 | ((acc[0] + n / 2) / n) << 16 | ((acc[1] + n / 2) / n) << 8 | ((acc[2] + n / 2) / n);
        }
    }
}

test "I420 round-trips colours closely" {
    const colors = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFF2A5DB0, 0xFF808080 };
    for (colors) |c| {
        const px: [4]u32 = @splat(c);
        var yb: [4]u8 = undefined;
        var ub: [1]u8 = undefined;
        var vb: [1]u8 = undefined;
        toI420(&px, 2, 2, 2, .{ .y = &yb, .u = &ub, .v = &vb, .y_stride = 2, .u_stride = 1, .v_stride = 1 });
        const back = pixelOf(yb[0], ub[0], vb[0]);
        for (0..3) |k| {
            const sh: u5 = @intCast(k * 8);
            const a: i32 = @intCast((c >> sh) & 0xFF);
            const b: i32 = @intCast((back >> sh) & 0xFF);
            try std.testing.expect(@abs(a - b) <= 4);
        }
    }
}

test "downscale averages blocks" {
    const src = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFFFFFFFF };
    var dst: [2]u32 = undefined;
    downscale(&src, 4, 4, 2, &dst, 2, 1);
    try std.testing.expectEqual(@as(u32, 0xFF808080), dst[0]);
}
