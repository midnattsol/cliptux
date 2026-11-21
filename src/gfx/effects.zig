//! Image effects used by redaction and the "beautify" frame. Pixels are
//! 0xAARRGGBB, row-major, `w` pixels per row. Every function clips the
//! rectangle to the buffer, so callers may pass rectangles partly (or
//! entirely) outside, with any coordinates.

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

fn dim(v: u32) i32 {
    return @intCast(@min(v, std.math.maxInt(i32)));
}

/// Clip `r` to a `w`×`h` buffer; null when nothing is left.
pub fn clip(r: Rect, w: u32, h: u32) ?Rect {
    if (r.w <= 0 or r.h <= 0) return null;
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x +| r.w, dim(w));
    const y1 = @min(r.y +| r.h, dim(h));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

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
inline fn narrow(sum: VS, inv_n: f32) [4]u32 {
    const f: VF = @floatFromInt(sum);
    const q: VB = @intFromFloat((f + @as(VF, @splat(0.5))) * @as(VF, @splat(inv_n)));
    return @bitCast(q);
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
    if (radius >= 3) addNoise(pixels, w, c);
}

fn boxBlur(alloc: std.mem.Allocator, pixels: []u32, w: u32, h: u32, c: Rect, rad: usize) !void {
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
    const wi: isize = @intCast(w);
    const cx: isize = c.x;
    const cw: usize = @intCast(c.w);
    const r: isize = @intCast(rad);
    const win = 2 * rad + 1;
    const len = cw + win;
    const y_end: usize = @intCast(c.y + c.h);
    var y: usize = @intCast(c.y);
    while (y < y_end) : (y += 4) {
        // the row segments the windows read, edge pixels replicated; copies,
        // so results can go straight back into the rows (rows past the end
        // repeat the last one and are not written)
        var ext: [4][]u32 = undefined;
        for (0..4) |k| {
            ext[k] = ext_buf[k * len ..][0..len];
            const row = pixels[@min(y + k, y_end - 1) * w ..][0..w];
            for (ext[k], 0..) |*e, i| {
                e.* = row[@intCast(std.math.clamp(cx - r + @as(isize, @intCast(i)), 0, wi - 1))];
            }
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

/// Vertical box pass, all columns at once (row-major, cache friendly).
fn vPass(pixels: []u32, w: u32, h: u32, c: Rect, rad: usize, inv: f32, tmp: []u32, sums: []u32) void {
    const hi: isize = @intCast(h);
    const cy: isize = c.y;
    const cx: usize = @intCast(c.x);
    const cw: usize = @intCast(c.w);
    const ch: usize = @intCast(c.h);
    const r: isize = @intCast(rad);
    const lanes = cw * 4;
    const full = lanes / L * L;
    @memset(sums, 0);
    var k: isize = -r;
    while (k <= r) : (k += 1) {
        const sy: usize = @intCast(std.math.clamp(cy + k, 0, hi - 1));
        const b = std.mem.sliceAsBytes(pixels[sy * w + cx ..][0..cw]);
        for (sums, b) |*s, v| s.* += v;
    }
    for (0..ch) |j| {
        const out = std.mem.sliceAsBytes(tmp[j * cw ..][0..cw]);
        const y: isize = cy + @as(isize, @intCast(j));
        const add: usize = @intCast(@min(y + r + 1, hi - 1));
        const sub: usize = @intCast(@max(y - r, 0));
        const ab = std.mem.sliceAsBytes(pixels[add * w + cx ..][0..cw]);
        const sb = std.mem.sliceAsBytes(pixels[sub * w + cx ..][0..cw]);
        var i: usize = 0;
        while (i < full) : (i += L) {
            const s: VS = sums[i..][0..L].*;
            const f: VF = @floatFromInt(s);
            const q: VB = @intFromFloat((f + @as(VF, @splat(0.5))) * @as(VF, @splat(inv)));
            out[i..][0..L].* = q;
            const av: VB = ab[i..][0..L].*;
            const sv: VB = sb[i..][0..L].*;
            sums[i..][0..L].* = s + @as(VS, av) - @as(VS, sv);
        }
        while (i < lanes) : (i += 1) {
            out[i] = @intFromFloat((@as(f32, @floatFromInt(sums[i])) + 0.5) * inv);
            sums[i] = sums[i] + ab[i] - sb[i];
        }
    }
    for (0..ch) |j| @memcpy(pixels[(@as(usize, @intCast(c.y)) + j) * w + cx ..][0..cw], tmp[j * cw ..][0..cw]);
}

var noise_key: u32 = 0;

fn noiseKey() u32 {
    if (noise_key == 0) {
        var k: u32 = 0;
        _ = std.os.linux.getrandom(std.mem.asBytes(&k), 4, 0);
        noise_key = k | 1;
    }
    return noise_key;
}

fn addNoise(pixels: []u32, w: u32, c: Rect) void {
    const key = noiseKey();
    const V = @Vector(4, u8);
    var y: u32 = @intCast(c.y);
    while (y < @as(u32, @intCast(c.y + c.h))) : (y += 1) {
        // xorshift stream per row, seeded from (key, y, x0) by murmur3's
        // finalizer, so a given rectangle always gets the same noise
        var st: u32 = y *% 0x9E3779B1 ^ @as(u32, @intCast(c.x)) *% 0x85EBCA77 ^ key;
        st ^= st >> 16;
        st *%= 0x85EBCA6B;
        st ^= st >> 13;
        st *%= 0xC2B2AE35;
        st ^= st >> 16;
        st |= 1;
        const row = pixels[@as(usize, y) * w + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        for (row) |*p| {
            st ^= st << 13;
            st ^= st >> 17;
            st ^= st << 5;
            // per colour byte: (0..3) - (0..3), alpha untouched
            const plus: V = @bitCast(st & 0x00030303);
            const minus: V = @bitCast((st >> 2) & 0x00030303);
            const v: V = @bitCast(p.*);
            p.* = @bitCast((v +| plus) -| minus);
        }
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
    const sy0 = r.y +| offset_y; // shadow rectangle, before falloff
    const sx1 = r.x +| (r.w - 1);
    const sy1 = sy0 +| (r.h - 1);
    const outer: Rect = .{ .x = r.x -| b, .y = sy0 -| b, .w = r.w +| (2 *| b), .h = r.h +| (2 *| b) };
    const c = clip(outer, w, h) orelse return;
    const base_a: f32 = @floatFromInt((color >> 24) & 0xFF);
    const fb: f32 = @floatFromInt(b);
    const rgb = color & 0xFFFFFF;
    const full: u32 = (@as(u32, @intFromFloat(base_a)) << 24) | rgb;
    var y: i32 = c.y;
    while (y < c.y + c.h) : (y += 1) {
        const dy: i64 = @max(@max(@as(i64, sy0) - y, @as(i64, y) - sy1), 0);
        const row = pixels[@as(usize, @intCast(y)) * w ..][0..w];
        // columns over the rectangle itself: distance is dy alone
        const ia = @max(c.x, r.x);
        const ib = @min(c.x + c.w, sx1 +| 1);
        const row_src: u32 = if (dy == 0) full else blk: {
            const d: f32 = @floatFromInt(dy);
            if (b == 0 or d >= fb) break :blk 0;
            const fall = 1.0 - d / fb;
            break :blk (@as(u32, @intFromFloat(base_a * fall * fall)) << 24) | rgb;
        };
        if (ia < ib and row_src >> 24 != 0) {
            for (row[@intCast(ia)..@intCast(ib)]) |*p| p.* = over(p.*, row_src);
        }
        var x: i32 = c.x;
        while (x < c.x + c.w) : (x += 1) {
            if (x == ia and ia < ib) {
                x = ib - 1;
                continue;
            }
            // distance outside the shadow rectangle
            const dx: i64 = @max(@max(@as(i64, r.x) - x, @as(i64, x) - sx1), 0);
            const d = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
            if (b > 0 and d >= fb) continue;
            const fall = if (b == 0) 1.0 else 1.0 - d / fb;
            const a: u32 = @intFromFloat(base_a * fall * fall);
            const i: usize = @intCast(x);
            row[i] = over(row[i], (a << 24) | rgb);
        }
    }
}

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

fn mix(a: u32, b: u32, t: f32) u32 {
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
    const m = ((s * @as(V, @splat(sa)) + d * @as(V, @splat(inv))) * @as(V, @splat(0x8081))) >> @splat(23);
    var out: @Vector(4, u8) = @intCast(m);
    out[3] = @intCast(sa + (dst >> 24) * inv / 255);
    return @bitCast(out);
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
            for ([_]u32{ 0xFF000000, 0xFFFFFFFF, 0x80123456, 0x00FEDCBA, 0xFF000000 | v * 0x010101 }) |dst| {
                try std.testing.expectEqual(Ref.overScalar(dst, src), over(dst, src));
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

test "blur hides detail and noise stays faint" {
    const alloc = std.testing.allocator;
    const W = 120;
    const H = 40;
    var px: [W * H]u32 = undefined;
    // "text": one-pixel black strokes on white
    for (&px, 0..) |*p, i| p.* = if ((i % W) % 4 == 0) 0xFF000000 else 0xFFFFFFFF;
    var plain = px;
    const area: Rect = .{ .x = 0, .y = 0, .w = W, .h = H };
    try blur(alloc, &px, W, H, area, 12);
    try boxBlur(alloc, &plain, W, H, clip(area, W, H).?, 12);
    var lo: u32 = 255;
    var hi: u32 = 0;
    for (px, plain, 0..) |p, q, i| {
        const x = i % W;
        const inside = x >= 40 and x < 80;
        if (inside) {
            lo = @min(lo, (p >> 8) & 0xFF);
            hi = @max(hi, (p >> 8) & 0xFF);
        }
        const d = @as(i32, @intCast(p & 0xFF)) - @as(i32, @intCast(q & 0xFF));
        try std.testing.expect(@abs(d) <= 3);
    }
    // stroke contrast (255 originally) is gone
    std.testing.expect(hi - lo <= 12) catch |e| {
        std.debug.print("lo={d} hi={d}\n", .{ lo, hi });
        return e;
    };
    // extreme inputs: nothing to do or clipped, never a crash
    try blur(alloc, &px, W, H, .{ .x = std.math.maxInt(i32), .y = 0, .w = std.math.maxInt(i32), .h = 5 }, 5);
    try blur(alloc, &px, W, H, .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) }, std.math.maxInt(u32));
    gradient(&px, W, H, .{ .x = std.math.minInt(i32), .y = 0, .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) }, 0, 0xFFFFFFFF);
    dropShadow(&px, W, H, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32), .w = std.math.maxInt(i32), .h = 3 }, std.math.maxInt(u32), std.math.minInt(i32), 0xFF000000);
    dropShadow(&px, W, H, .{ .x = 3, .y = 3, .w = 9, .h = 9 }, std.math.maxInt(u32), std.math.maxInt(i32), 0xFF000000);
    const src: [4]u32 = @splat(0xFFABCDEF);
    blitRounded(&px, W, H, &src, 2, 2, std.math.maxInt(i32), -1, std.math.maxInt(u32));
    blitRounded(&px, W, H, &src, 2, 2, -1, -1, std.math.maxInt(u32));
}
