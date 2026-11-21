//! JPEG block transforms: zigzag order, the 8x8 inverse DCT and YCbCr to
//! RGB.

const std = @import("std");

/// Natural (row-major) index of the k-th coefficient in zigzag order.
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// cos_table[x][u] = C(u) / 2 * cos((2x + 1) u pi / 16)
const cos_table: [8][8]f32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [8][8]f32 = undefined;
    for (0..8) |x| for (0..8) |u| {
        const c: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        t[x][u] = @floatCast(c / 2.0 * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0));
    };
    break :blk t;
};

/// Inverse DCT of `coef` (natural order, dequantized) into 8x8 samples
/// at `out` (row stride `stride`), level-shifted and clamped to 0..255.
pub fn idct(coef: *const [64]i32, out: []u8, stride: usize) void {
    var tmp: [64]f32 = undefined;
    // columns
    for (0..8) |u| {
        for (0..8) |y| {
            var s: f32 = 0;
            for (0..8) |v| s += cos_table[y][v] * @as(f32, @floatFromInt(coef[v * 8 + u]));
            tmp[y * 8 + u] = s;
        }
    }
    // rows
    for (0..8) |y| {
        for (0..8) |x| {
            var s: f32 = 0;
            for (0..8) |u| s += cos_table[x][u] * tmp[y * 8 + u];
            out[y * stride + x] = clamp8(s + 128);
        }
    }
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// One pixel from Y, Cb, Cr (JFIF, full range).
pub fn ycc(y: u8, cb: u8, cr: u8) u32 {
    const fy: f32 = @floatFromInt(y);
    const fb = @as(f32, @floatFromInt(cb)) - 128;
    const fr = @as(f32, @floatFromInt(cr)) - 128;
    const r: u32 = clamp8(fy + 1.402 * fr);
    const g: u32 = clamp8(fy - 0.344136 * fb - 0.714136 * fr);
    const b: u32 = clamp8(fy + 1.772 * fb);
    return 0xFF000000 | r << 16 | g << 8 | b;
}

test "a DC-only block is flat" {
    var c: [64]i32 = @splat(0);
    c[0] = 8 * 50; // DC of a block whose samples are 50 above the shift
    var out: [64]u8 = undefined;
    idct(&c, &out, 8);
    for (out) |v| try std.testing.expectEqual(@as(u8, 178), v);
}

test "colour conversion of greys and primaries" {
    try std.testing.expectEqual(@as(u32, 0xFF808080), ycc(128, 128, 128));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), ycc(255, 128, 128));
    const red = ycc(76, 85, 255);
    try std.testing.expect((red >> 16) & 0xFF > 250 and (red >> 8) & 0xFF < 5);
}
