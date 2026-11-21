//! Box blurs: `blur` for redaction (with anti-recovery noise) and
//! `softBlur` for looks. Pixels are 0xAARRGGBB, row-major.

const std = @import("std");
const rect = @import("rect.zig");
const Rect = rect.Rect;
const clip = rect.clip;

// Box passes work on 16 byte lanes at once: four pixels of a row in the
// vertical pass, the same pixel of four rows in the horizontal one.
const L = 16;
const VB = @Vector(L, u8);
const VS = @Vector(L, u32);
const VF = @Vector(L, f32);

inline fn widen(px: [4]u32) VS {
    const b: VB = @bitCast(px);
    return b;
}

/// floor(sum / n) per lane. (sum + 0.5) / n is at least 0.5/n away from an
/// integer, far more than f32 rounding error for sums below 2^24, so this
/// is exact.
inline fn quantize(sum: VS, inv_n: f32) VB {
    const f: VF = @floatFromInt(sum);
    return @intFromFloat((f + @as(VF, @splat(0.5))) * @as(VF, @splat(inv_n)));
}

/// `quantize`, as four pixels.
inline fn narrow(sum: VS, inv_n: f32) [4]u32 {
    return @bitCast(quantize(sum, inv_n));
}

/// Largest blur radius honoured; beyond it every window spans the region.
const max_blur_radius = 2048;

/// Blur the pixels inside `r` in place; strong enough at the default
/// radius that text below it cannot be recovered. Pixels outside `r` are
/// read (clamped at the buffer edge) but never written.
///
/// Three box passes per axis (close to a gaussian of sigma ~ radius),
/// each a sliding window: O(1) per pixel whatever the radius. A faint
/// noise (+-3 levels), keyed by a per-process random secret, is added
/// afterwards so the result is not a pure function of the pixels below,
/// which defeats matching blurred text against blurred candidates.
pub fn blur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, r: Rect, radius: u32) !void {
    const c = clip(r, w, h) orelse return;
    if (radius == 0) return;
    try boxBlur(alloc, pixels, w, h, c, @min(radius, max_blur_radius));
    if (radius >= 3) addNoise(pixels, w, c, r);
}

/// Blur for looks (backdrops under translucent UI): like `blur`, without
/// the anti-recovery noise.
pub fn softBlur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, r: Rect, radius: u32) !void {
    const c = clip(r, w, h) orelse return;
    if (radius == 0) return;
    try boxBlur(alloc, pixels, w, h, c, @min(radius, max_blur_radius));
}

/// Three horizontal + vertical box passes of radius `rad` over the clipped
/// rectangle `c`, with no noise.
pub fn boxBlur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, c: Rect, rad: usize) !void {
    const cw: usize = @intCast(c.w);
    const ch: usize = @intCast(c.h);
    const tmp = try alloc.alloc(u32, cw * ch);
    defer alloc.free(tmp);
    const sums = try alloc.alloc(u32, cw * 4);
    defer alloc.free(sums);
    const ext = try alloc.alloc(u32, 4 * (cw + 2 * rad + 1));
    defer alloc.free(ext);
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(2 * rad + 1));
    for (0..3) |_| {
        hPass(pixels, w, c, rad, inv, ext);
        vPass(pixels, w, h, c, rad, inv, tmp, sums);
    }
}

/// Horizontal box pass, four rows at a time; each row only depends on
/// itself, so results go straight back into `pixels`.
fn hPass(pixels: []u32, w: u32, c: Rect, rad: usize, inv: f32, ext_buf: []u32) void {
    const cw: usize = @intCast(c.w);
    const win = 2 * rad + 1;
    const len = cw + win;
    const y_end: usize = @intCast(c.y + c.h);
    var y: usize = @intCast(c.y);
    while (y < y_end) : (y += 4) {
        var ext: [4][]u32 = undefined;
        for (0..4) |k| {
            ext[k] = ext_buf[k * len ..][0..len];
            extendRow(ext[k], pixels[@min(y + k, y_end - 1) * w ..][0..w], c.x - @as(isize, @intCast(rad)));
        }
        var sum: VS = @splat(0);
        for (0..win) |i| sum += widen(.{ ext[0][i], ext[1][i], ext[2][i], ext[3][i] });
        const rows = @min(4, y_end - y);
        const base = y * w + @as(usize, @intCast(c.x));
        for (0..cw) |i| {
            const q = narrow(sum, inv);
            for (0..rows) |k| pixels[base + k * w + i] = q[k];
            sum = sum + widen(.{ ext[0][i + win], ext[1][i + win], ext[2][i + win], ext[3][i + win] }) -
                widen(.{ ext[0][i], ext[1][i], ext[2][i], ext[3][i] });
        }
    }
}

/// Copy the segment of `row` from column `x0` on that the windows read
/// into `ext`, edge pixels replicated. A copy, so results can go straight
/// back into the rows (rows past the end repeat the last one and are not
/// written).
inline fn extendRow(ext: []u32, row: []const u32, x0: isize) void {
    const last: isize = @intCast(row.len - 1);
    for (ext, 0..) |*e, i| {
        e.* = row[@intCast(std.math.clamp(x0 + @as(isize, @intCast(i)), 0, last))];
    }
}

/// Vertical box pass, all columns at once (row-major, cache friendly).
fn vPass(pixels: []u32, w: u32, h: u32, c: Rect, rad: usize, inv: f32, tmp: []u32, sums: []u32) void {
    const hi: isize = @intCast(h);
    const cy: isize = c.y;
    const cx: usize = @intCast(c.x);
    const cw: usize = @intCast(c.w);
    const ch: usize = @intCast(c.h);
    const r: isize = @intCast(rad);
    seedColumnSums(sums, pixels, w, h, c, r);
    for (0..ch) |j| {
        const y: isize = cy + @as(isize, @intCast(j));
        const add: usize = @intCast(@min(y + r + 1, hi - 1));
        const sub: usize = @intCast(@max(y - r, 0));
        slideRow(
            std.mem.sliceAsBytes(tmp[j * cw ..][0..cw]),
            sums,
            std.mem.sliceAsBytes(pixels[add * w + cx ..][0..cw]),
            std.mem.sliceAsBytes(pixels[sub * w + cx ..][0..cw]),
            inv,
        );
    }
    for (0..ch) |j| @memcpy(pixels[(@as(usize, @intCast(c.y)) + j) * w + cx ..][0..cw], tmp[j * cw ..][0..cw]);
}

/// Per-byte sums of the window around the first row of `c`: rows
/// c.y - r ..= c.y + r, clamped to the buffer.
fn seedColumnSums(sums: []u32, pixels: []const u32, w: u32, h: u32, c: Rect, r: isize) void {
    const hi: isize = @intCast(h);
    const cx: usize = @intCast(c.x);
    const cw: usize = @intCast(c.w);
    @memset(sums, 0);
    var k: isize = -r;
    while (k <= r) : (k += 1) {
        const sy: usize = @intCast(std.math.clamp(c.y + k, 0, hi - 1));
        const b = std.mem.sliceAsBytes(pixels[sy * w + cx ..][0..cw]);
        for (sums, b) |*s, v| s.* += v;
    }
}

/// Write the window means `sums` to `out`, then slide the windows one
/// row down: add the bytes of row `ab`, drop those of row `sb`.
inline fn slideRow(out: []u8, sums: []u32, ab: []const u8, sb: []const u8, inv: f32) void {
    const lanes = sums.len;
    const full = lanes / L * L;
    var i: usize = 0;
    while (i < full) : (i += L) {
        const s: VS = sums[i..][0..L].*;
        out[i..][0..L].* = quantize(s, inv);
        const av: VB = ab[i..][0..L].*;
        const sv: VB = sb[i..][0..L].*;
        sums[i..][0..L].* = s + @as(VS, av) - @as(VS, sv);
    }
    while (i < lanes) : (i += 1) {
        out[i] = @intFromFloat((@as(f32, @floatFromInt(sums[i])) + 0.5) * inv);
        sums[i] = sums[i] + ab[i] - sb[i];
    }
}

var noise_key: u32 = 0;

/// The per-process noise secret, drawn on first use.
fn noiseKey() u32 {
    if (noise_key == 0) {
        var k: u32 = 0;
        _ = std.os.linux.getrandom(std.mem.asBytes(&k), 4, 0);
        noise_key = k | 1;
    }
    return noise_key;
}

/// Add the faint keyed noise of `blur` to the clipped rectangle `c` of
/// the blur rectangle `r`.
fn addNoise(pixels: []u32, w: u32, c: Rect, r: Rect) void {
    const key = noiseKey();
    const V = @Vector(4, u8);
    var y: u32 = @intCast(c.y);
    while (y < @as(u32, @intCast(c.y + c.h))) : (y += 1) {
        const row = pixels[@as(usize, y) * w + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        var x: u32 = @intCast(c.x);
        for (row) |*p| {
            // a hash of the position inside the (unclipped) blur rectangle,
            // so repainting part of a blur, or the same blur on a buffer
            // shifted by any offset, gives the same noise as painting it all
            const ux: u32 = @bitCast(@as(i32, @intCast(x)) -% r.x);
            const uy: u32 = @bitCast(@as(i32, @intCast(y)) -% r.y);
            const st = noiseHash(ux, uy, key);
            x += 1;
            // per colour byte: (0..3) - (0..3), alpha untouched
            const plus: V = @bitCast(st & 0x00030303);
            const minus: V = @bitCast((st >> 2) & 0x00030303);
            const v: V = @bitCast(p.*);
            p.* = @bitCast((v +| plus) -| minus);
        }
    }
}

/// Keyed 32-bit hash of a position (murmur3 finalizer).
inline fn noiseHash(ux: u32, uy: u32, key: u32) u32 {
    var st: u32 = uy *% 0x9E3779B1 ^ ux *% 0x85EBCA77 ^ key;
    st ^= st >> 16;
    st *%= 0x85EBCA6B;
    st ^= st >> 13;
    st *%= 0xC2B2AE35;
    st ^= st >> 16;
    return st;
}
