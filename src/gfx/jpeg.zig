//! Baseline JPEG decoder (ITU T.81: sequential DCT, Huffman, 8-bit; one
//! or three components, any sampling factors, restart intervals,
//! interleaved or not). Progressive and arithmetic-coded files are
//! refused with error.Unsupported; imgload.zig hands them to libturbojpeg
//! when it is installed.
//!
//! The input is untrusted: sizes are bounded before allocating, every
//! read is checked, and bad data is an error, never a crash.

const std = @import("std");
const png = @import("png.zig");
const huff = @import("jpeg_huff.zig");
const idct_mod = @import("jpeg_idct.zig");

pub const Error = error{ NotJpeg, Truncated, Corrupt, Unsupported, TooBig, OutOfMemory };

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    td: u8 = 0,
    ta: u8 = 0,
    pred: i32 = 0,
    /// samples, `bw * 8` wide and `bh * 8` tall (whole MCUs)
    plane: []u8 = &.{},
    bw: usize = 0,
    bh: usize = 0,
};

const Decoder = struct {
    alloc: std.mem.Allocator,
    data: []const u8,
    pos: usize = 0,
    qt: [4][64]u16 = @splat(@splat(0)),
    dc: [4]huff.Table = @splat(.{}),
    ac: [4]huff.Table = @splat(.{}),
    comps: [3]Component = undefined,
    ncomp: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: usize = 0,
    mcuy: usize = 0,
    restart: u16 = 0,
    /// Adobe APP14 says the three components are RGB, not YCbCr
    rgb: bool = false,

    fn deinit(d: *Decoder) void {
        for (d.comps[0..d.ncomp]) |c| d.alloc.free(c.plane);
    }

    fn byte(d: *Decoder) Error!u8 {
        if (d.pos >= d.data.len) return error.Truncated;
        d.pos += 1;
        return d.data[d.pos - 1];
    }

    fn u16be(d: *Decoder) Error!u16 {
        return @as(u16, try d.byte()) << 8 | try d.byte();
    }

    /// The payload of the marker segment at `pos` (after its length).
    fn segment(d: *Decoder) Error![]const u8 {
        const len = try d.u16be();
        if (len < 2 or d.pos + len - 2 > d.data.len) return error.Truncated;
        defer d.pos += len - 2;
        return d.data[d.pos..][0 .. len - 2];
    }

    fn nextMarker(d: *Decoder) Error!u8 {
        // fill bytes (0xFF) may precede a marker
        while (true) {
            if (try d.byte() != 0xFF) return error.Corrupt;
            var m = try d.byte();
            while (m == 0xFF) m = try d.byte();
            if (m != 0) return m;
        }
    }

    fn run(d: *Decoder) Error!void {
        if (d.data.len < 3 or d.data[0] != 0xFF or d.data[1] != 0xD8) return error.NotJpeg;
        d.pos = 2;
        var frame = false;
        var scans: usize = 0;
        while (true) {
            const m = try d.nextMarker();
            switch (m) {
                0xD9 => break,
                0xC0, 0xC1 => {
                    if (frame) return error.Corrupt;
                    try d.readFrame(try d.segment());
                    frame = true;
                },
                0xC2, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
                0xC4 => try d.readHuffman(try d.segment()),
                0xDB => try d.readQuant(try d.segment()),
                0xDD => {
                    const s = try d.segment();
                    if (s.len < 2) return error.Corrupt;
                    d.restart = @as(u16, s[0]) << 8 | s[1];
                },
                0xDA => {
                    if (!frame) return error.Corrupt;
                    try d.readScan(try d.segment());
                    scans += 1;
                },
                0xEE => d.readAdobe(try d.segment()),
                0xD0...0xD7 => {}, // a stray restart marker
                else => _ = try d.segment(), // APPn, COM, DNL...
            }
        }
        if (!frame or scans == 0) return error.Truncated;
    }

    fn readAdobe(d: *Decoder, s: []const u8) void {
        if (s.len >= 12 and std.mem.eql(u8, s[0..5], "Adobe")) d.rgb = s[11] == 0;
    }

    fn readQuant(d: *Decoder, s_in: []const u8) Error!void {
        var s = s_in;
        while (s.len > 0) {
            const pq = s[0] >> 4;
            const tq = s[0] & 15;
            if (tq > 3 or pq > 1) return error.Corrupt;
            const n: usize = if (pq == 0) 64 else 128;
            if (s.len < 1 + n) return error.Corrupt;
            for (0..64) |k| {
                const v: u16 = if (pq == 0) s[1 + k] else @as(u16, s[1 + 2 * k]) << 8 | s[2 + 2 * k];
                d.qt[tq][idct_mod.zigzag[k]] = v;
            }
            s = s[1 + n ..];
        }
    }

    fn readHuffman(d: *Decoder, s_in: []const u8) Error!void {
        var s = s_in;
        while (s.len > 0) {
            if (s.len < 17) return error.Corrupt;
            const tc = s[0] >> 4;
            const th = s[0] & 15;
            if (tc > 1 or th > 3) return error.Corrupt;
            var counts: [16]u8 = undefined;
            @memcpy(&counts, s[1..17]);
            var total: usize = 0;
            for (counts) |c| total += c;
            if (s.len < 17 + total) return error.Corrupt;
            const t = try huff.Table.build(counts, s[17..][0..total]);
            if (tc == 0) d.dc[th] = t else d.ac[th] = t;
            s = s[17 + total ..];
        }
    }

    fn readFrame(d: *Decoder, s: []const u8) Error!void {
        if (s.len < 6) return error.Corrupt;
        if (s[0] != 8) return error.Unsupported;
        d.height = @as(u32, s[1]) << 8 | s[2];
        d.width = @as(u32, s[3]) << 8 | s[4];
        const n = s[5];
        if (d.width == 0 or d.height == 0) return error.Unsupported; // DNL
        if (d.width > png.max_side or d.height > png.max_side or @as(u64, d.width) * d.height > png.max_pixels) return error.TooBig;
        if (n != 1 and n != 3) return error.Unsupported;
        if (s.len < 6 + 3 * @as(usize, n)) return error.Corrupt;
        for (0..n) |i| {
            const c = s[6 + 3 * i ..][0..3];
            const h = c[1] >> 4;
            const v = c[1] & 15;
            if (h < 1 or h > 4 or v < 1 or v > 4 or c[2] > 3) return error.Corrupt;
            d.comps[i] = .{ .id = c[0], .h = h, .v = v, .tq = c[2] };
            d.hmax = @max(d.hmax, h);
            d.vmax = @max(d.vmax, v);
        }
        d.ncomp = n;
        d.mcux = (d.width + 8 * @as(usize, d.hmax) - 1) / (8 * @as(usize, d.hmax));
        d.mcuy = (d.height + 8 * @as(usize, d.vmax) - 1) / (8 * @as(usize, d.vmax));
        for (d.comps[0..n]) |*c| {
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.plane = try d.alloc.alloc(u8, c.bw * 8 * c.bh * 8);
            @memset(c.plane, 128);
        }
    }

    fn readScan(d: *Decoder, s: []const u8) Error!void {
        if (s.len < 1) return error.Corrupt;
        const ns = s[0];
        if (ns < 1 or ns > d.ncomp or s.len < 1 + 2 * @as(usize, ns) + 3) return error.Corrupt;
        var list: [3]*Component = undefined;
        for (0..ns) |i| {
            const id = s[1 + 2 * i];
            const sel = s[2 + 2 * i];
            const c = for (d.comps[0..d.ncomp]) |*c| {
                if (c.id == id) break c;
            } else return error.Corrupt;
            c.td = sel >> 4;
            c.ta = sel & 15;
            if (c.td > 3 or c.ta > 3) return error.Corrupt;
            c.pred = 0;
            list[i] = c;
        }
        var br: huff.BitReader = .{ .data = d.data, .pos = d.pos };
        if (ns == 1) try d.scanSingle(&br, list[0]) else try d.scanInterleaved(&br, list[0..ns]);
        d.pos = br.pos;
        // to the next marker
        while (d.pos + 1 < d.data.len and !(d.data[d.pos] == 0xFF and d.data[d.pos + 1] != 0 and (d.data[d.pos + 1] < 0xD0 or d.data[d.pos + 1] > 0xD7))) d.pos += 1;
    }

    fn atRestart(d: *Decoder, br: *huff.BitReader, done: usize, list: []const *Component) void {
        if (d.restart == 0 or done == 0 or done % d.restart != 0) return;
        br.restart();
        for (list) |c| c.pred = 0;
    }

    fn scanInterleaved(d: *Decoder, br: *huff.BitReader, list: []const *Component) Error!void {
        var done: usize = 0;
        for (0..d.mcuy) |my| for (0..d.mcux) |mx| {
            d.atRestart(br, done, list);
            for (list) |c| {
                for (0..c.v) |by| for (0..c.h) |bx| {
                    try d.block(br, c, mx * c.h + bx, my * c.v + by);
                };
            }
            done += 1;
        };
    }

    /// One component alone: its blocks in raster order, only those that
    /// cover the picture.
    fn scanSingle(d: *Decoder, br: *huff.BitReader, c: *Component) Error!void {
        const cw = (@as(usize, d.width) * c.h + d.hmax - 1) / d.hmax;
        const ch = (@as(usize, d.height) * c.v + d.vmax - 1) / d.vmax;
        var done: usize = 0;
        for (0..(ch + 7) / 8) |by| for (0..(cw + 7) / 8) |bx| {
            d.atRestart(br, done, &.{c});
            try d.block(br, c, bx, by);
            done += 1;
        };
    }

    fn block(d: *Decoder, br: *huff.BitReader, c: *Component, bx: usize, by: usize) Error!void {
        var coef: [64]i32 = @splat(0);
        const q = &d.qt[c.tq];
        const t = try br.decode(&d.dc[c.td]);
        c.pred +%= try br.receiveExtend(t);
        coef[0] = c.pred *% q[0];
        var k: usize = 1;
        while (k < 64) {
            const rs = try br.decode(&d.ac[c.ta]);
            const r = rs >> 4;
            const sz = rs & 15;
            if (sz == 0) {
                if (r != 15) break;
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.Corrupt;
            const z = idct_mod.zigzag[k];
            coef[z] = (try br.receiveExtend(sz)) *% q[z];
            k += 1;
        }
        const stride = c.bw * 8;
        idct_mod.idct(&coef, c.plane[by * 8 * stride + bx * 8 ..], stride);
    }

    /// The planes, upsampled where subsampled, as 0xAARRGGBB.
    fn pixels(d: *Decoder) Error!png.Image {
        const w = d.width;
        const h = d.height;
        const out = try d.alloc.alloc(u32, @as(usize, w) * h);
        for (0..h) |y| for (0..w) |x| {
            var s: [3]u8 = undefined;
            for (d.comps[0..d.ncomp], 0..) |c, i| {
                const sx = x * c.h / d.hmax;
                const sy = y * c.v / d.vmax;
                s[i] = c.plane[sy * c.bw * 8 + sx];
            }
            out[y * w + x] = if (d.ncomp == 1)
                0xFF000000 | @as(u32, s[0]) * 0x010101
            else if (d.rgb)
                0xFF000000 | @as(u32, s[0]) << 16 | @as(u32, s[1]) << 8 | s[2]
            else
                idct_mod.ycc(s[0], s[1], s[2]);
        };
        return .{ .width = w, .height = h, .pixels = out };
    }
};

pub fn isJpeg(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF;
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) Error!png.Image {
    var d: Decoder = .{ .alloc = alloc, .data = data };
    defer d.deinit();
    try d.run();
    return d.pixels();
}

test {
    _ = huff;
    _ = idct_mod;
    _ = @import("jpeg_test.zig");
}
