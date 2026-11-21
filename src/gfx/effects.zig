//! Image effects used by redaction and the "beautify" frame. Pixels are
//! 0xAARRGGBB, row-major, `stride` pixels per row. Every function clips the
//! rectangle to the buffer, so callers may pass rectangles partly outside.
//!
//! These first versions are simple and correct; they define the API.

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Clip `r` to a `w`×`h` buffer; null when nothing is left.
pub fn clip(r: Rect, w: u32, h: u32) ?Rect {
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x + r.w, @as(i32, @intCast(w)));
    const y1 = @min(r.y + r.h, @as(i32, @intCast(h)));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Blur the pixels inside `r` in place; strong enough at the default
/// radius that text below it cannot be recovered. Pixels outside `r` are
/// read (clamped at the buffer edge) but never written.
pub fn blur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, r: Rect, radius: u32) !void {
    const c = clip(r, w, h) orelse return;
    if (radius == 0) return;
    const cw: usize = @intCast(c.w);
    const ch: usize = @intCast(c.h);
    const tmp = try alloc.alloc(u32, cw * ch);
    defer alloc.free(tmp);
    const rad: i32 = @intCast(radius);
    // three box passes approximate a gaussian
    for (0..3) |_| {
        boxPass(pixels, w, h, c, rad, tmp, true);
        boxPass(pixels, w, h, c, rad, tmp, false);
    }
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

/// A soft shadow under the rectangle `r`: `blur` pixels of falloff, moved
/// down by `offset_y`, blended over what is already in the buffer.
pub fn dropShadow(pixels: []u32, w: u32, h: u32, r: Rect, blur_px: u32, offset_y: i32, color: u32) void {
    const b: i32 = @intCast(blur_px);
    const outer: Rect = .{ .x = r.x - b, .y = r.y - b + offset_y, .w = r.w + 2 * b, .h = r.h + 2 * b };
    const c = clip(outer, w, h) orelse return;
    const base_a: f32 = @floatFromInt((color >> 24) & 0xFF);
    var y: i32 = c.y;
    while (y < c.y + c.h) : (y += 1) {
        var x: i32 = c.x;
        while (x < c.x + c.w) : (x += 1) {
            // distance outside the shadow rectangle
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

/// Copy `src` (sw×sh) into `dst` (dw×dh) at (x, y) with its corners rounded
/// to `radius`, blending the corner edges over what `dst` already holds.
pub fn blitRounded(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, radius: u32) void {
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
            // coverage of this pixel by the rounded rectangle
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

fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const ca: f32 = @floatFromInt((a >> shift) & 0xFF);
        const cb: f32 = @floatFromInt((b >> shift) & 0xFF);
        out |= @as(u32, @intFromFloat(ca + (cb - ca) * std.math.clamp(t, 0, 1))) << shift;
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

test "effects clip to the buffer and leave the outside alone" {
    const alloc = std.testing.allocator;
    var px: [16]u32 = @splat(0xFF000000);
    px[5] = 0xFFFFFFFF;
    redact(&px, 4, 4, .{ .x = -2, .y = -2, .w = 3, .h = 3 }, 0x123456);
    try std.testing.expectEqual(@as(u32, 0xFF123456), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2]);
    try blur(alloc, &px, 4, 4, .{ .x = 2, .y = 2, .w = 10, .h = 10 }, 2);
    try std.testing.expectEqual(@as(u32, 0xFF123456), px[0]);
    gradient(&px, 4, 4, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, 0xFF000000, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[15]);
    dropShadow(&px, 4, 4, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, 1, 0, 0x80000000);
    const src: [4]u32 = @splat(0xFFABCDEF);
    blitRounded(&px, 4, 4, &src, 2, 2, 3, 3, 0);
    try std.testing.expectEqual(@as(u32, 0xFFABCDEF), px[15]);
}
