//! Fills and compositing: redaction, gradients, drop shadows, rounded
//! blits and the `over` operator. Pixels are 0xAARRGGBB, row-major.

const std = @import("std");
const rect = @import("rect.zig");
const Rect = rect.Rect;
const clip = rect.clip;
const dim = rect.dim;

/// Fill `r` with an opaque colour: redaction that cannot be undone.
pub fn redact(pixels: []u32, w: u32, h: u32, r: Rect, color: u32) void {
    const c = clip(r, w, h) orelse return;
    var y: usize = @intCast(c.y);
    while (y < @as(usize, @intCast(c.y + c.h))) : (y += 1) {
        @memset(pixels[y * w + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)], color | 0xFF000000);
    }
}

/// Fill `r` with a linear gradient from `from` (top-left) to `to`
/// (bottom-right), along the diagonal.
pub fn gradient(pixels: []u32, w: u32, h: u32, r: Rect, from: u32, to: u32) void {
    const c = clip(r, w, h) orelse return;
    const span: f32 = @floatFromInt(@max(1, @as(i64, r.w) + r.h - 2));
    const cw: usize = @intCast(c.w);
    const x0: usize = @intCast(c.x);
    // the colour depends only on x + y, so each row is the previous one
    // shifted left by a pixel plus one new pixel at the end
    var y: usize = @intCast(c.y);
    const y_end: usize = @intCast(c.y + c.h);
    const base: i64 = (@as(i64, c.x) - r.x) + (@as(i64, c.y) - r.y);
    {
        const row = pixels[y * w + x0 ..][0..cw];
        for (row, 0..) |*p, i| p.* = mix(from, to, @as(f32, @floatFromInt(base + @as(i64, @intCast(i)))) / span);
    }
    y += 1;
    while (y < y_end) : (y += 1) {
        const prev = pixels[(y - 1) * w + x0 ..][0..cw];
        const row = pixels[y * w + x0 ..][0..cw];
        if (cw > 1) @memcpy(row[0 .. cw - 1], prev[1..]);
        const s = base + @as(i64, @intCast(y - @as(usize, @intCast(c.y)))) + @as(i64, @intCast(cw - 1));
        row[cw - 1] = mix(from, to, @as(f32, @floatFromInt(s)) / span);
    }
}

/// A soft shadow under the rectangle `r`: `blur` pixels of falloff, moved
/// down by `offset_y`, blended over what is already in the buffer.
pub fn dropShadow(pixels: []u32, w: u32, h: u32, r: Rect, blur_px: u32, offset_y: i32, color: u32) void {
    if (r.w <= 0 or r.h <= 0) return;
    const b: i32 = @intCast(@min(blur_px, 1 << 20));
    const sh: Shadow = .{
        .x0 = r.x,
        .y0 = r.y +| offset_y,
        .x1 = r.x +| (r.w - 1),
        .y1 = (r.y +| offset_y) +| (r.h - 1),
        .b = b,
        .fb = @floatFromInt(b),
        .base_a = @floatFromInt((color >> 24) & 0xFF),
        .rgb = color & 0xFFFFFF,
    };
    const outer: Rect = .{ .x = r.x -| b, .y = sh.y0 -| b, .w = r.w +| (2 *| b), .h = r.h +| (2 *| b) };
    const c = clip(outer, w, h) orelse return;
    var y: i32 = c.y;
    while (y < c.y + c.h) : (y += 1) {
        sh.shadeRow(pixels[@as(usize, @intCast(y)) * w ..][0..w], y, c.x, c.x + c.w);
    }
}

/// The shadow rectangle [x0, x1] x [y0, y1] (inclusive, before falloff),
/// its falloff `b` and colour.
const Shadow = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    b: i32,
    fb: f32,
    base_a: f32,
    rgb: u32,

    /// Blend the shadow over columns [xa, xb) of row `y`.
    fn shadeRow(sh: Shadow, row: []u32, y: i32, xa: i32, xb: i32) void {
        const dy: i64 = @max(@max(@as(i64, sh.y0) - y, @as(i64, y) - sh.y1), 0);
        // columns over the rectangle itself: distance is dy alone
        const ia = @max(xa, sh.x0);
        const ib = @min(xb, sh.x1 +| 1);
        const row_src = sh.rowColor(dy);
        if (ia < ib and row_src >> 24 != 0) {
            for (row[@intCast(ia)..@intCast(ib)]) |*p| p.* = over(p.*, row_src);
        }
        var x: i32 = xa;
        while (x < xb) : (x += 1) {
            if (x == ia and ia < ib) {
                x = ib - 1;
                continue;
            }
            // distance outside the shadow rectangle
            const dx: i64 = @max(@max(@as(i64, sh.x0) - x, @as(i64, x) - sh.x1), 0);
            const d = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
            if (sh.b > 0 and d >= sh.fb) continue;
            const fall = if (sh.b == 0) 1.0 else 1.0 - d / sh.fb;
            const a: u32 = @intFromFloat(sh.base_a * fall * fall);
            const i: usize = @intCast(x);
            row[i] = over(row[i], (a << 24) | sh.rgb);
        }
    }

    /// Shadow colour over the rectangle's own columns, `dy` rows outside
    /// it; alpha 0 when beyond the falloff.
    fn rowColor(sh: Shadow, dy: i64) u32 {
        if (dy == 0) return (@as(u32, @intFromFloat(sh.base_a)) << 24) | sh.rgb;
        const d: f32 = @floatFromInt(dy);
        if (sh.b == 0 or d >= sh.fb) return 0;
        const fall = 1.0 - d / sh.fb;
        return (@as(u32, @intFromFloat(sh.base_a * fall * fall)) << 24) | sh.rgb;
    }
};

/// Copy `src` (sw×sh) into `dst` (dw×dh) at (x, y) with its corners rounded
/// to `radius`, blending the corner edges over what `dst` already holds.
pub fn blitRounded(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, radius: u32) void {
    const c = clip(.{ .x = x, .y = y, .w = dim(sw), .h = dim(sh) }, dw, dh) orelse return;
    const radi: u32 = @min(radius, @min(sw, sh) / 2);
    const rad: f32 = @floatFromInt(radi);
    const fw: f32 = @floatFromInt(sw);
    const fh: f32 = @floatFromInt(sh);
    const sx0: usize = @intCast(c.x - x); // first source column drawn
    const cw: usize = @intCast(c.w);
    var dy: i32 = c.y;
    while (dy < c.y + c.h) : (dy += 1) {
        const sy: usize = @intCast(dy - y);
        const srow = src[sy * sw ..][0..sw];
        const drow = dst[@as(usize, @intCast(dy)) * dw + @as(usize, @intCast(c.x)) ..][0..cw];
        const py = @as(f32, @floatFromInt(sy)) + 0.5;
        const qy = @max(rad - py, py - (fh - rad), 0);
        if (qy == 0 or radi == 0) {
            @memcpy(drow, srow[sx0..][0..cw]); // no corner on this row
            continue;
        }
        for (drow, srow[sx0..][0..cw], sx0..) |*d, p, sx| {
            // coverage of this pixel by the rounded rectangle
            const px = @as(f32, @floatFromInt(sx)) + 0.5;
            const qx = @max(rad - px, px - (fw - rad), 0);
            const cov = if (qx == 0) 1.0 else std.math.clamp(rad - @sqrt(qx * qx + qy * qy) + 0.5, 0, 1);
            if (cov >= 1.0) {
                d.* = p;
            } else if (cov > 0) {
                const a: u32 = @intFromFloat(@as(f32, @floatFromInt((p >> 24) & 0xFF)) * cov);
                d.* = over(d.*, (a << 24) | (p & 0xFFFFFF));
            }
        }
    }
}

/// Per-channel linear interpolation from `a` to `b`; `t` clamped to [0, 1].
pub fn mix(a: u32, b: u32, t: f32) u32 {
    const tt = if (t > 0) @min(t, 1) else 0; // also maps NaN to 0
    var out: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const ca: f32 = @floatFromInt((a >> shift) & 0xFF);
        const cb: f32 = @floatFromInt((b >> shift) & 0xFF);
        out |= @as(u32, @intFromFloat(ca + (cb - ca) * tt)) << shift;
        if (shift == 24) break;
    }
    return out;
}

/// `src` over `dst`, both 0xAARRGGBB; the result is opaque when dst is.
pub fn over(dst: u32, src: u32) u32 {
    const sa = (src >> 24) & 0xFF;
    if (sa == 0) return dst;
    if (sa == 255) return src;
    const inv = 255 - sa;
    const V = @Vector(4, u32);
    const s: V = @as(@Vector(4, u8), @bitCast(src));
    const d: V = @as(@Vector(4, u8), @bitCast(dst));
    // floor(x / 255) == (x * 0x8081) >> 23 for every x <= 255 * 255
    const da = (dst >> 24) & 0xFF;
    if (da == 255) {
        const m = ((s * @as(V, @splat(sa)) + d * @as(V, @splat(inv))) * @as(V, @splat(0x8081))) >> @splat(23);
        var out: @Vector(4, u8) = @intCast(m);
        out[3] = 255;
        return @bitCast(out);
    }
    // translucent destination (a transparent beautify background): straight
    // alpha, so edges over nothing keep their colour instead of darkening
    const dw = da * inv / 255; // destination's remaining weight
    const oa = sa + dw;
    if (oa == 0) return 0;
    const m = (s * @as(V, @splat(sa)) + d * @as(V, @splat(dw)) + @as(V, @splat(oa / 2))) / @as(V, @splat(oa));
    var out: @Vector(4, u8) = @intCast(@min(m, @as(V, @splat(255))));
    out[3] = @intCast(oa);
    return @bitCast(out);
}

test "over keeps colour on a transparent destination" {
    // half-covered red edge over nothing: still red, half opaque
    const p = over(0x00000000, 0x80FF0000);
    try std.testing.expectEqual(@as(u32, 0x80), p >> 24);
    try std.testing.expectEqual(@as(u32, 0xFF), (p >> 16) & 0xFF);
    // over an opaque destination nothing changes from before
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F) & 0xFF000000, over(0xFF000000, 0x80FFFFFF) & 0xFF000000);
}

/// dst = a + (b - a) * k / 256 per colour channel, opaque. dst may be a or b.
pub fn mixRows(dst: []u32, a: []const u32, b: []const u32, k: u32) void {
    @setRuntimeSafety(false);
    const ka = 256 - k;
    for (dst, a, b) |*d, pa, pb| {
        const rb = ((pa & 0x00FF00FF) * ka + (pb & 0x00FF00FF) * k) >> 8;
        const g = ((pa & 0x0000FF00) * ka + (pb & 0x0000FF00) * k) >> 8;
        d.* = 0xFF000000 | (rb & 0x00FF00FF) | (g & 0x0000FF00);
    }
}

test "mixRows goes from a to b" {
    var a = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var b = [_]u32{ 0xFFFFFFFF, 0xFF000000 };
    var d: [2]u32 = undefined;
    mixRows(&d, &a, &b, 0);
    try std.testing.expectEqualSlices(u32, &a, &d);
    mixRows(&d, &a, &b, 256);
    try std.testing.expectEqualSlices(u32, &b, &d);
    mixRows(&d, &a, &b, 128);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), d[0]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), d[1]);
}
