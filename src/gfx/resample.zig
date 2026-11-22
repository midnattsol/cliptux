//! Pictures at another size, smoothly: an area (box) filter when
//! shrinking, so each target pixel is the exact average of the source
//! area it covers (text in a thumbnail stays readable instead of turning
//! into noise), and bilinear when enlarging. Every weight is positive and
//! they sum to one, so nothing rings or overshoots. Colours are averaged
//! weighted by alpha (as premultiplied), so transparent pixels do not
//! darken their neighbours.
//!
//! Stable API:
//!   Region                       a part of the source, in source pixels
//!   scale(gpa, src, sw, sh, dst, dw, dh)            all of src into dst
//!   region(gpa, src, sw, sh, r, dst, dw, dh)        part of src into dst

const std = @import("std");

/// A rectangle of the source in (fractional) source pixels.
pub const Region = struct { x: f64, y: f64, w: f64, h: f64 };

/// The taps of one axis: target pixel i reads `idx[i * stride ..][0..n]`
/// weighted by `wt[...]` (unused slots weigh 0).
const Axis = struct {
    stride: usize,
    idx: []u32,
    wt: []f32,

    fn init(gpa: std.mem.Allocator, n_src: u32, start: f64, extent: f64, n_dst: u32) !Axis {
        const step = extent / @as(f64, @floatFromInt(n_dst));
        const stride: usize = @as(usize, @intFromFloat(@ceil(@max(step, 1)))) + 2;
        const idx = try gpa.alloc(u32, stride * n_dst);
        errdefer gpa.free(idx);
        const wt = try gpa.alloc(f32, stride * n_dst);
        @memset(idx, 0);
        @memset(wt, 0);
        const a: Axis = .{ .stride = stride, .idx = idx, .wt = wt };
        for (0..n_dst) |i| {
            const lo = start + @as(f64, @floatFromInt(i)) * step;
            if (step >= 1) a.boxTaps(i, n_src, lo, lo + step) else a.tentTaps(i, n_src, lo + step / 2 - 0.5);
        }
        return a;
    }

    fn deinit(a: Axis, gpa: std.mem.Allocator) void {
        gpa.free(a.idx);
        gpa.free(a.wt);
    }

    /// Shrinking: each source pixel by how much of [lo, hi) it covers.
    fn boxTaps(a: Axis, i: usize, n_src: u32, lo: f64, hi: f64) void {
        var sum: f64 = 0;
        var k: usize = 0;
        var j = @floor(lo);
        while (j < hi and k < a.stride) : (j += 1) {
            const cover = @min(hi, j + 1) - @max(lo, j);
            if (cover <= 0) continue;
            a.idx[i * a.stride + k] = clampIndex(j, n_src);
            a.wt[i * a.stride + k] = @floatCast(cover);
            sum += cover;
            k += 1;
        }
        normalize(a.wt[i * a.stride ..][0..a.stride], sum);
    }

    /// Enlarging: the two source pixels around the centre `c`.
    fn tentTaps(a: Axis, i: usize, n_src: u32, c: f64) void {
        const j0 = @floor(c);
        const t = c - j0;
        a.idx[i * a.stride] = clampIndex(j0, n_src);
        a.idx[i * a.stride + 1] = clampIndex(j0 + 1, n_src);
        a.wt[i * a.stride] = @floatCast(1 - t);
        a.wt[i * a.stride + 1] = @floatCast(t);
    }
};

fn clampIndex(j: f64, n: u32) u32 {
    return @intFromFloat(std.math.clamp(j, 0, @as(f64, @floatFromInt(n - 1))));
}

fn normalize(w: []f32, sum: f64) void {
    if (sum <= 0) return;
    for (w) |*x| x.* = @floatCast(x.* / sum);
}

/// All of `src` (sw x sh) resampled into `dst` (dw x dh).
pub fn scale(gpa: std.mem.Allocator, src: []const u32, sw: u32, sh: u32, dst: []u32, dw: u32, dh: u32) !void {
    if (sw == dw and sh == dh) {
        @memcpy(dst[0 .. @as(usize, dw) * dh], src[0 .. @as(usize, sw) * sh]);
        return;
    }
    const all: Region = .{ .x = 0, .y = 0, .w = @floatFromInt(sw), .h = @floatFromInt(sh) };
    try region(gpa, src, sw, sh, all, dst, dw, dh);
}

/// The part `r` of `src` (sw x sh) resampled to fill `dst` (dw x dh).
pub fn region(gpa: std.mem.Allocator, src: []const u32, sw: u32, sh: u32, r: Region, dst: []u32, dw: u32, dh: u32) !void {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return;
    const ax = try Axis.init(gpa, sw, r.x, r.w, dw);
    defer ax.deinit(gpa);
    const ay = try Axis.init(gpa, sh, r.y, r.h, dh);
    defer ay.deinit(gpa);
    for (0..dh) |y| {
        const yi = ay.idx[y * ay.stride ..][0..ay.stride];
        const yw = ay.wt[y * ay.stride ..][0..ay.stride];
        for (0..dw) |x| {
            dst[y * dw + x] = pixel(src, sw, yi, yw, ax.idx[x * ax.stride ..][0..ax.stride], ax.wt[x * ax.stride ..][0..ax.stride]);
        }
    }
}

/// One target pixel: the weighted sum of its taps, alpha-weighted.
inline fn pixel(src: []const u32, sw: u32, yi: []const u32, yw: []const f32, xi: []const u32, xw: []const f32) u32 {
    var acc: @Vector(4, f32) = @splat(0);
    for (yi, yw) |sy, wy| {
        if (wy == 0) continue;
        const row = src[@as(usize, sy) * sw ..];
        for (xi, xw) |sx, wx| {
            if (wx == 0) continue;
            const p = row[sx];
            const w = wy * wx;
            const a: f32 = @floatFromInt(p >> 24);
            const wa = w * a;
            acc += @Vector(4, f32){
                wa * @as(f32, @floatFromInt((p >> 16) & 0xFF)),
                wa * @as(f32, @floatFromInt((p >> 8) & 0xFF)),
                wa * @as(f32, @floatFromInt(p & 0xFF)),
                wa,
            };
        }
    }
    if (acc[3] <= 0) return 0;
    const k = 1 / acc[3];
    return (channel(acc[3]) << 24) | (channel(acc[0] * k) << 16) | (channel(acc[1] * k) << 8) | channel(acc[2] * k);
}

inline fn channel(v: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

const testing = std.testing;

fn checkerboard(px: []u32, w: u32) void {
    for (px, 0..) |*p, i| p.* = if (((i % w) + (i / w)) % 2 == 0) 0xFFFFFFFF else 0xFF000000;
}

test "a 1 px checkerboard shrunk 4x is an even grey" {
    var src: [64 * 64]u32 = undefined;
    checkerboard(&src, 64);
    var dst: [16 * 16]u32 = undefined;
    try scale(testing.allocator, &src, 64, 64, &dst, 16, 16);
    for (dst) |p| {
        try testing.expectEqual(@as(u32, 0xFF), p >> 24);
        const g = p & 0xFF;
        try testing.expect(g == 127 or g == 128);
        try testing.expectEqual(g, (p >> 8) & 0xFF);
        try testing.expectEqual(g, (p >> 16) & 0xFF);
    }
}

test "odd ratios stay near grey and never overshoot" {
    var src: [50 * 30]u32 = undefined;
    checkerboard(&src, 50);
    var dst: [20 * 12]u32 = undefined;
    // 2.5x: each target pixel covers 2.5 x 2.5 source pixels
    try scale(testing.allocator, &src, 50, 30, &dst, 20, 12);
    for (dst) |p| {
        const g = p & 0xFF;
        try testing.expect(g >= 100 and g <= 155);
    }
    // a flat colour stays exactly that colour at any size, up or down
    var flat: [7 * 5]u32 = @splat(0xFF336699);
    var big: [23 * 11]u32 = undefined;
    try scale(testing.allocator, &flat, 7, 5, &big, 23, 11);
    for (big) |p| try testing.expectEqual(@as(u32, 0xFF336699), p);
    var small: [3 * 2]u32 = undefined;
    try scale(testing.allocator, &flat, 7, 5, &small, 3, 2);
    for (small) |p| try testing.expectEqual(@as(u32, 0xFF336699), p);
}

test "enlarging blends neighbours, a region picks its part" {
    const src = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var dst: [4]u32 = undefined;
    try scale(testing.allocator, &src, 2, 1, &dst, 4, 1);
    // the ends keep their colours, the middle is in between
    try testing.expectEqual(@as(u32, 0xFF000000), dst[0]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), dst[3]);
    try testing.expect(dst[1] & 0xFF > 0 and dst[1] & 0xFF < dst[2] & 0xFF);
    // the right half of a black | white picture is white
    const pic = [_]u32{ 0xFF000000, 0xFF000000, 0xFFFFFFFF, 0xFFFFFFFF };
    var half: [1]u32 = undefined;
    try region(testing.allocator, &pic, 4, 1, .{ .x = 2, .y = 0, .w = 2, .h = 1 }, &half, 1, 1);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), half[0]);
}

test "transparent pixels do not darken their neighbours" {
    // red and fully transparent black: the average is half-transparent red
    const src = [_]u32{ 0xFFFF0000, 0x00000000 };
    var dst: [1]u32 = undefined;
    try scale(testing.allocator, &src, 2, 1, &dst, 1, 1);
    try testing.expectEqual(@as(u32, 0xFF0000), dst[0] & 0xFFFFFF);
    const a = dst[0] >> 24;
    try testing.expect(a == 127 or a == 128);
}
