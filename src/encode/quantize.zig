//! Colour quantization for GIF frames: a palette of at most 256 colours
//! by median cut over a 5-bit-per-channel histogram, and the mapping of
//! pixels onto it (nearest colour through a lazily filled 6-bit lookup
//! table) with no dithering, ordered (Bayer 8x8: stable from frame to
//! frame, so unchanged areas stay unchanged) or Floyd-Steinberg dithering.
//!
//! Pixels are 0xAARRGGBB; alpha is ignored. Palette colours are 0xRRGGBB.

const std = @import("std");

pub const Dither = enum { none, ordered, floyd };

pub const Palette = struct {
    colors: [256]u32 = @splat(0),
    len: u16 = 0,
};

/// A rectangle inside a pixel buffer of `stride` pixels per row.
pub const View = struct {
    px: []const u32,
    stride: usize,
    x: usize = 0,
    y: usize = 0,
    w: usize,
    h: usize,

    pub fn at(self: View, x: usize, y: usize) u32 {
        return self.px[(self.y + y) * self.stride + self.x + x];
    }
};

const bins = 1 << 15;

/// Per-bin counts and channel sums of the 5-bit histogram.
pub const Histogram = struct {
    count: [bins]u32 = @splat(0),
    sum_r: [bins]u32 = @splat(0),
    sum_g: [bins]u32 = @splat(0),
    sum_b: [bins]u32 = @splat(0),

    pub fn reset(self: *Histogram) void {
        @memset(&self.count, 0);
        @memset(&self.sum_r, 0);
        @memset(&self.sum_g, 0);
        @memset(&self.sum_b, 0);
    }

    /// Count the view's pixels; large views are sampled (about 1/4 M px).
    pub fn add(self: *Histogram, v: View) void {
        const total = v.w * v.h;
        const step: usize = if (total > 1 << 18) std.math.sqrt(total >> 18) + 1 else 1;
        var y: usize = 0;
        while (y < v.h) : (y += step) {
            var x: usize = (y / step) % step;
            while (x < v.w) : (x += step) self.addPixel(v.at(x, y));
        }
    }

    fn addPixel(self: *Histogram, p: u32) void {
        const r = (p >> 16) & 0xFF;
        const g = (p >> 8) & 0xFF;
        const b = p & 0xFF;
        const i = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3);
        // sums stay below 2^32 for any view we sample (<= 2^24 samples)
        self.count[i] += 1;
        self.sum_r[i] += r;
        self.sum_g[i] += g;
        self.sum_b[i] += b;
    }
};

const Box = struct {
    /// indices into the occupied-bin list
    lo: usize,
    hi: usize,
    weight: u64,
};

fn channel(bin: u16, c: u2) u16 {
    return switch (c) {
        0 => bin >> 10,
        1 => (bin >> 5) & 31,
        else => bin & 31,
    };
}

/// Median cut: split the box with the most pixels (along its widest
/// channel, at the weighted median) until there are `max` boxes.
pub fn medianCut(h: *const Histogram, max: u16, out: *Palette) void {
    var occ: [bins]u16 = undefined;
    var n: usize = 0;
    for (h.count, 0..) |c, i| if (c > 0) {
        occ[n] = @intCast(i);
        n += 1;
    };
    out.len = 0;
    if (n == 0) {
        out.colors[0] = 0;
        out.len = 1;
        return;
    }
    var boxes: [256]Box = undefined;
    boxes[0] = .{ .lo = 0, .hi = n, .weight = weightOf(h, occ[0..n]) };
    var nb: usize = 1;
    while (nb < max) {
        const bi = heaviestSplittable(boxes[0..nb]) orelse break;
        const b = boxes[bi];
        const c = widestChannel(occ[b.lo..b.hi]);
        sortByChannel(occ[b.lo..b.hi], c);
        const mid = weightedMedian(h, occ[b.lo..b.hi]);
        boxes[bi] = .{ .lo = b.lo, .hi = b.lo + mid, .weight = weightOf(h, occ[b.lo .. b.lo + mid]) };
        boxes[nb] = .{ .lo = b.lo + mid, .hi = b.hi, .weight = weightOf(h, occ[b.lo + mid .. b.hi]) };
        nb += 1;
    }
    for (boxes[0..nb]) |b| {
        var r: u64 = 0;
        var g: u64 = 0;
        var bl: u64 = 0;
        var cnt: u64 = 0;
        for (occ[b.lo..b.hi]) |i| {
            r += h.sum_r[i];
            g += h.sum_g[i];
            bl += h.sum_b[i];
            cnt += h.count[i];
        }
        const half = cnt / 2;
        out.colors[out.len] = @intCast(((r + half) / cnt) << 16 | ((g + half) / cnt) << 8 | ((bl + half) / cnt));
        out.len += 1;
    }
}

fn weightOf(h: *const Histogram, list: []const u16) u64 {
    var w: u64 = 0;
    for (list) |i| w += h.count[i];
    return w;
}

fn heaviestSplittable(boxes: []const Box) ?usize {
    var best: ?usize = null;
    for (boxes, 0..) |b, i| {
        if (b.hi - b.lo < 2) continue;
        if (best == null or b.weight > boxes[best.?].weight) best = i;
    }
    return best;
}

fn widestChannel(list: []const u16) u2 {
    var lo: [3]u16 = @splat(31);
    var hi: [3]u16 = @splat(0);
    for (list) |bin| for (0..3) |c| {
        const v = channel(bin, @intCast(c));
        lo[c] = @min(lo[c], v);
        hi[c] = @max(hi[c], v);
    };
    // green weighs most to the eye, blue least
    const r = (hi[0] - lo[0]) * 3;
    const g = (hi[1] - lo[1]) * 4;
    const b = (hi[2] - lo[2]) * 2;
    if (g >= r and g >= b) return 1;
    return if (r >= b) 0 else 2;
}

fn sortByChannel(list: []u16, c: u2) void {
    const Ctx = struct {
        c: u2,
        fn less(self: @This(), a: u16, b: u16) bool {
            const va = channel(a, self.c);
            const vb = channel(b, self.c);
            return if (va != vb) va < vb else a < b;
        }
    };
    std.mem.sort(u16, list, Ctx{ .c = c }, Ctx.less);
}

/// Index splitting `list` into two halves of about equal weight, never
/// leaving either empty.
fn weightedMedian(h: *const Histogram, list: []const u16) usize {
    const total = weightOf(h, list);
    var acc: u64 = 0;
    for (list, 0..) |i, k| {
        acc += h.count[i];
        if (acc * 2 >= total) return std.math.clamp(k + 1, 1, list.len - 1);
    }
    return list.len / 2;
}

/// Nearest palette colour for any pixel, through a 6-bit-per-channel
/// lookup table filled on first use.
pub const Mapper = struct {
    pal: *const Palette,
    lut: []u16,

    const empty: u16 = 0xFFFF;
    pub const lut_len = 1 << 18;

    pub fn init(pal: *const Palette, lut: []u16) Mapper {
        std.debug.assert(lut.len == lut_len);
        @memset(lut, empty);
        return .{ .pal = pal, .lut = lut };
    }

    pub fn index(self: *Mapper, r: i32, g: i32, b: i32) u8 {
        const cr: u32 = @intCast(std.math.clamp(r, 0, 255));
        const cg: u32 = @intCast(std.math.clamp(g, 0, 255));
        const cb: u32 = @intCast(std.math.clamp(b, 0, 255));
        const key = (cr >> 2) << 12 | (cg >> 2) << 6 | (cb >> 2);
        if (self.lut[key] == empty) self.lut[key] = self.nearest((cr & 0xFC) | 2, (cg & 0xFC) | 2, (cb & 0xFC) | 2);
        return @intCast(self.lut[key]);
    }

    fn nearest(self: *const Mapper, r: u32, g: u32, b: u32) u8 {
        var best: u8 = 0;
        var best_d: u32 = std.math.maxInt(u32);
        for (self.pal.colors[0..self.pal.len], 0..) |c, i| {
            const dr = @as(i32, @intCast((c >> 16) & 0xFF)) - @as(i32, @intCast(r));
            const dg = @as(i32, @intCast((c >> 8) & 0xFF)) - @as(i32, @intCast(g));
            const db = @as(i32, @intCast(c & 0xFF)) - @as(i32, @intCast(b));
            const d: u32 = @intCast(2 * dr * dr + 4 * dg * dg + 3 * db * db);
            if (d < best_d) {
                best_d = d;
                best = @intCast(i);
            }
        }
        return best;
    }
};

/// Bayer 8x8 thresholds, 0..63.
const bayer8 = blk: {
    var m: [64]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        var v: u8 = 0;
        var xx = x;
        var yy = y ^ x;
        for (0..3) |_| {
            v = (v << 2) | @as(u8, @intCast(((yy & 1) << 1) | (xx & 1)));
            xx >>= 1;
            yy >>= 1;
        }
        m[y * 8 + x] = v;
    };
    break :blk m;
};

/// Map the view to palette indices (`out`: w*h, row-major). `spread` is
/// the ordered dither's amplitude (about the palette's step between
/// neighbouring colours). Floyd-Steinberg needs `err` of (w+2)*6 i16s.
pub fn mapView(m: *Mapper, v: View, dither: Dither, out: []u8, err: []i16) void {
    switch (dither) {
        .none => for (0..v.h) |y| for (0..v.w) |x| {
            const p = v.at(x, y);
            out[y * v.w + x] = m.index(@intCast((p >> 16) & 0xFF), @intCast((p >> 8) & 0xFF), @intCast(p & 0xFF));
        },
        .ordered => mapOrdered(m, v, out),
        .floyd => mapFloyd(m, v, out, err),
    }
}

/// The dither amplitude for a palette of `n` colours.
pub fn spreadFor(n: usize) i32 {
    return if (n >= 200) 20 else if (n >= 64) 28 else 40;
}

fn mapOrdered(m: *Mapper, v: View, out: []u8) void {
    const spread = spreadFor(m.pal.len);
    for (0..v.h) |y| for (0..v.w) |x| {
        const p = v.at(x, y);
        const t = @as(i32, bayer8[((v.y + y) & 7) * 8 + ((v.x + x) & 7)]);
        const d = @divTrunc((t * 2 - 63) * spread, 128);
        out[y * v.w + x] = m.index(@as(i32, @intCast((p >> 16) & 0xFF)) + d, @as(i32, @intCast((p >> 8) & 0xFF)) + d, @as(i32, @intCast(p & 0xFF)) + d);
    };
}

fn mapFloyd(m: *Mapper, v: View, out: []u8, err: []i16) void {
    const row = (v.w + 2) * 3;
    std.debug.assert(err.len >= 2 * row);
    @memset(err[0 .. 2 * row], 0);
    var cur = err[0..row];
    var next = err[row .. 2 * row];
    for (0..v.h) |y| {
        @memset(next, 0);
        for (0..v.w) |x| {
            const p = v.at(x, y);
            const e = cur[(x + 1) * 3 ..][0..3];
            const want = [3]i32{
                @as(i32, @intCast((p >> 16) & 0xFF)) + @divTrunc(e[0], 16),
                @as(i32, @intCast((p >> 8) & 0xFF)) + @divTrunc(e[1], 16),
                @as(i32, @intCast(p & 0xFF)) + @divTrunc(e[2], 16),
            };
            const idx = m.index(want[0], want[1], want[2]);
            out[y * v.w + x] = idx;
            const c = m.pal.colors[idx];
            const got = [3]i32{ @intCast((c >> 16) & 0xFF), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF) };
            for (0..3) |k| {
                const q = std.math.clamp(want[k], 0, 255) - got[k];
                cur[(x + 2) * 3 + k] +|= @intCast(q * 7);
                next[x * 3 + k] +|= @intCast(q * 3);
                next[(x + 1) * 3 + k] +|= @intCast(q * 5);
                next[(x + 2) * 3 + k] +|= @intCast(q);
            }
        }
        const t = cur;
        cur = next;
        next = t;
    }
}

// --- tests

fn testHistogram(px: []const u32, w: usize, h: usize) !*Histogram {
    const hist = try std.testing.allocator.create(Histogram);
    hist.reset();
    hist.add(.{ .px = px, .stride = w, .w = w, .h = h });
    return hist;
}

test "few colours come back exactly" {
    const gpa = std.testing.allocator;
    const cols = [_]u32{ 0xFF102030, 0xFFF0E0D0, 0xFF00FF00, 0xFF808080 };
    var px: [64 * 16]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = cols[(i / 7) % cols.len];
    const hist = try testHistogram(&px, 64, 16);
    defer gpa.destroy(hist);
    var pal: Palette = .{};
    medianCut(hist, 256, &pal);
    try std.testing.expectEqual(@as(u16, 4), pal.len);
    for (cols) |c| {
        const found = for (pal.colors[0..pal.len]) |q| {
            if (q == c & 0xFFFFFF) break true;
        } else false;
        try std.testing.expect(found);
    }
}

test "a gradient maps closely with every dither" {
    const gpa = std.testing.allocator;
    const w = 128;
    const h = 32;
    var px: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const r: u32 = @intCast(x * 2);
        const g: u32 = @intCast(255 - x * 2);
        const b: u32 = @intCast(y * 8);
        px[y * w + x] = 0xFF000000 | r << 16 | g << 8 | b;
    };
    const hist = try testHistogram(&px, w, h);
    defer gpa.destroy(hist);
    var pal: Palette = .{};
    medianCut(hist, 64, &pal);
    try std.testing.expectEqual(@as(u16, 64), pal.len);
    const lut = try gpa.alloc(u16, Mapper.lut_len);
    defer gpa.free(lut);
    var out: [w * h]u8 = undefined;
    var err: [(w + 2) * 6]i16 = undefined;
    for ([_]Dither{ .none, .ordered, .floyd }) |d| {
        var m = Mapper.init(&pal, lut);
        mapView(&m, .{ .px = &px, .stride = w, .w = w, .h = h }, d, &out, &err);
        // the mean over 8x8 blocks stays near the source
        var by: usize = 0;
        while (by < h) : (by += 8) {
            var bx: usize = 0;
            while (bx < w) : (bx += 8) {
                var src: i64 = 0;
                var got: i64 = 0;
                for (0..8) |yy| for (0..8) |xx| {
                    src += @intCast((px[(by + yy) * w + bx + xx] >> 8) & 0xFF);
                    got += @intCast((pal.colors[out[(by + yy) * w + bx + xx]] >> 8) & 0xFF);
                };
                try std.testing.expect(@abs(src - got) <= 64 * 12);
            }
        }
    }
}

test "bayer matrix is a permutation of 0..63" {
    var seen: [64]bool = @splat(false);
    for (bayer8) |v| seen[v] = true;
    for (seen) |s| try std.testing.expect(s);
}
