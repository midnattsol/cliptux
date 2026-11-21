//! PNG row filters: reversing them when decoding, and choosing and applying
//! them (SIMD, 32 bytes at a time) when encoding.

const std = @import("std");

/// Reverse PNG row filters in place. Hot path: lengths were validated by the
/// caller (raw.len == stride * height, stride == 1 + line bytes).
pub fn unfilter(raw: []u8, stride: usize, height: u32, bpp: usize) !void {
    @setRuntimeSafety(false);
    std.debug.assert(raw.len == stride * height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * stride ..][0..stride];
        const prev: ?[]u8 = if (y > 0) raw[(y - 1) * stride ..][0..stride] else null;
        const filter = row[0];
        const line = row[1..];
        switch (filter) {
            0 => {},
            1 => { // sub
                var i: usize = bpp;
                while (i < line.len) : (i += 1) line[i] +%= line[i - bpp];
            },
            2 => { // up
                if (prev) |p| {
                    for (line, 0..) |*b, i| b.* +%= p[1 + i];
                }
            },
            3 => { // average
                if (prev) |p| {
                    var i: usize = 0;
                    while (i < bpp and i < line.len) : (i += 1) line[i] +%= p[1 + i] / 2;
                    while (i < line.len) : (i += 1) {
                        line[i] +%= @intCast((@as(u16, line[i - bpp]) + p[1 + i]) / 2);
                    }
                } else {
                    var i: usize = bpp;
                    while (i < line.len) : (i += 1) line[i] +%= line[i - bpp] / 2;
                }
            },
            4 => { // paeth
                if (prev) |p| {
                    var i: usize = 0;
                    while (i < bpp and i < line.len) : (i += 1) line[i] +%= p[1 + i]; // a=c=0 -> paeth=b
                    while (i < line.len) : (i += 1) {
                        line[i] +%= paeth(line[i - bpp], p[1 + i], p[1 + i - bpp]);
                    }
                } else {
                    var i: usize = bpp;
                    while (i < line.len) : (i += 1) line[i] +%= line[i - bpp]; // b=c=0 -> paeth=a
                }
            },
            else => return error.BadFilter,
        }
    }
}

pub fn paeth(a: u8, b: u8, c: u8) u8 {
    const ai: i32 = a;
    const bi: i32 = b;
    const ci: i32 = c;
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// rows are filtered with this many zero bytes in front, so the "left"
/// neighbour of the first pixel needs no special case
pub const pad = 32;
const V = @Vector(32, u8);
const VI = @Vector(32, i16);

/// Filter one row (RGB or RGBA bytes in `cur`/`prev`, both with `pad`
/// leading zeros) into `out` (filter byte + data). Adaptive picks the
/// filter with the minimum sum of absolute differences; otherwise None.
pub fn filterRow(bpp: u8, cur: []const u8, prev: []const u8, out: []u8, adaptive: bool) void {
    if (bpp == 4) filterRowN(4, cur, prev, out, adaptive) else filterRowN(3, cur, prev, out, adaptive);
}

fn filterRowN(comptime enc_bpp: usize, cur: []const u8, prev: []const u8, out: []u8, adaptive: bool) void {
    if (!adaptive) {
        out[0] = 0;
        @memcpy(out[1..], cur[pad..]);
        return;
    }
    const best = bestFilter(enc_bpp, cur, prev);
    out[0] = best;
    applyFilter(enc_bpp, best, cur, prev, out[1..]);
}

/// The filter type (0-4) with the minimum sum of absolute differences.
inline fn bestFilter(comptime enc_bpp: usize, cur: []const u8, prev: []const u8) u8 {
    const n = cur.len - pad;
    var sums: [5]u64 = @splat(0);
    var i: usize = 0;
    while (i + 32 <= n) : (i += 32) {
        const x: V = cur[pad + i ..][0..32].*;
        const a: V = cur[pad + i - enc_bpp ..][0..32].*;
        const b: V = prev[pad + i ..][0..32].*;
        const c: V = prev[pad + i - enc_bpp ..][0..32].*;
        const f = predict(x, a, b, c);
        inline for (0..5) |k| {
            const s: @Vector(32, i8) = @bitCast(f[k]);
            sums[k] += @reduce(.Add, @as(@Vector(32, u16), @abs(s)));
        }
    }
    while (i < n) : (i += 1) {
        const x = cur[pad + i];
        const a = cur[pad + i - enc_bpp];
        const b = prev[pad + i];
        const c = prev[pad + i - enc_bpp];
        const f = [5]u8{ x, x -% a, x -% b, x -% avg(a, b), x -% paeth(a, b, c) };
        for (f, 0..) |v, k| sums[k] += @abs(@as(i8, @bitCast(v)));
    }
    var best: u8 = 0;
    for (sums, 0..) |sum, k| {
        if (sum < sums[best]) best = @intCast(k);
    }
    return best;
}

/// Write the row filtered with `best` into `dst`.
inline fn applyFilter(comptime enc_bpp: usize, best: u8, cur: []const u8, prev: []const u8, dst: []u8) void {
    const n = cur.len - pad;
    var i: usize = 0;
    while (i + 32 <= n) : (i += 32) {
        const x: V = cur[pad + i ..][0..32].*;
        const a: V = cur[pad + i - enc_bpp ..][0..32].*;
        const b: V = prev[pad + i ..][0..32].*;
        const c: V = prev[pad + i - enc_bpp ..][0..32].*;
        dst[i..][0..32].* = predict(x, a, b, c)[best];
    }
    while (i < n) : (i += 1) {
        const x = cur[pad + i];
        const a = cur[pad + i - enc_bpp];
        const b = prev[pad + i];
        const c = prev[pad + i - enc_bpp];
        dst[i] = switch (best) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% avg(a, b),
            else => x -% paeth(a, b, c),
        };
    }
}

fn avg(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + b) / 2);
}

/// All five filtered versions of 32 bytes.
inline fn predict(x: V, a: V, b: V, c: V) [5]V {
    const ai: VI = a;
    const bi: VI = b;
    const ci: VI = c;
    const av: V = @intCast((ai + bi) >> @splat(1));
    const pa = @abs(bi - ci);
    const pb = @abs(ai - ci);
    const pc = @abs(ai + bi - ci - ci);
    const use_a = (pa <= pb) & (pa <= pc);
    const use_b = pb <= pc;
    const pred: V = @select(u8, use_a, a, @select(u8, use_b, b, c));
    return .{ x, x -% a, x -% b, x -% av, x -% pred };
}
