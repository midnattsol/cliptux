//! Minimal PNG codec: enough to decode portal screenshots and other common
//! PNGs (gray/RGB/palette/gray+alpha/RGBA at 1-16 bits, tRNS,
//! non-interlaced) and encode annotated output (8-bit RGB). Pixels are
//! exchanged as 0xAARRGGBB u32 values (matching wl_shm xrgb8888 layout on
//! little-endian).
//!
//! The decoder treats its input as untrusted: chunk lengths, IHDR fields
//! and the decompressed size are all bounded before anything is allocated.
//! The encoder picks a filter per row (minimum sum of absolute
//! differences) and, for large images, deflates bands of rows on several
//! threads, joining them into one zlib stream.

const std = @import("std");
const flate = std.compress.flate;

pub const Image = struct {
    width: u32,
    height: u32,
    /// row-major, width*height entries, 0xAARRGGBB
    pixels: []u32,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Decoder limits: per side, total pixels, and decompressed bytes.
pub const max_side = 16384;
pub const max_pixels = 64 * 1024 * 1024;
const max_raw_bytes = 512 * 1024 * 1024;

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &signature)) return error.NotPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var have_ihdr = false;
    var palette: [256]u32 = @splat(0xFF000000);
    var palette_len: usize = 0;
    // tRNS for gray/RGB: the one fully transparent sample value
    var trns_key: ?[3]u16 = null;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    var pos: usize = 8;
    while (data.len - pos >= 8) { // tolerate a missing IEND
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        pos += 8;
        if (chunk_len > 0x7FFFFFFF or data.len - pos < @as(usize, chunk_len) + 4) return error.Truncated;
        const chunk = data[pos..][0..chunk_len];
        pos += chunk_len + 4; // skip crc

        if (!have_ihdr) {
            if (!std.mem.eql(u8, chunk_type, "IHDR")) return error.BadIhdr;
            if (chunk.len != 13) return error.BadIhdr;
            width = std.mem.readInt(u32, chunk[0..4], .big);
            height = std.mem.readInt(u32, chunk[4..8], .big);
            bit_depth = chunk[8];
            color_type = chunk[9];
            if (chunk[10] != 0 or chunk[11] != 0) return error.BadIhdr;
            if (chunk[12] == 1) return error.InterlacedUnsupported;
            if (chunk[12] != 0) return error.BadIhdr;
            if (width == 0 or height == 0) return error.BadIhdr;
            if (width > max_side or height > max_side) return error.TooLarge;
            if (@as(u64, width) * height > max_pixels) return error.TooLarge;
            const depth_ok = switch (color_type) {
                0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
                3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
                2, 4, 6 => bit_depth == 8 or bit_depth == 16,
                else => return error.ColorTypeUnsupported,
            };
            if (!depth_ok) return error.BitDepthUnsupported;
            have_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            palette_len = @min(palette.len, chunk.len / 3);
            for (0..palette_len) |i| {
                palette[i] = 0xFF000000 |
                    (@as(u32, chunk[i * 3]) << 16) |
                    (@as(u32, chunk[i * 3 + 1]) << 8) |
                    @as(u32, chunk[i * 3 + 2]);
            }
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            switch (color_type) {
                3 => for (chunk[0..@min(chunk.len, 256)], 0..) |a, i| {
                    palette[i] = (palette[i] & 0x00FFFFFF) | (@as(u32, a) << 24);
                },
                0 => if (chunk.len >= 2) {
                    const g = std.mem.readInt(u16, chunk[0..2], .big);
                    trns_key = .{ g, g, g };
                },
                2 => if (chunk.len >= 6) {
                    trns_key = .{
                        std.mem.readInt(u16, chunk[0..2], .big),
                        std.mem.readInt(u16, chunk[2..4], .big),
                        std.mem.readInt(u16, chunk[4..6], .big),
                    };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(alloc, chunk);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        } else if (chunk_type[0] & 0x20 == 0) {
            return error.UnknownCriticalChunk;
        }
    }
    if (!have_ihdr) return error.BadIhdr;

    const channels: u32 = switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const bits_pp: u64 = @as(u64, channels) * bit_depth;
    const line_bytes: u64 = (@as(u64, width) * bits_pp + 7) / 8;
    const stride: u64 = 1 + line_bytes; // +1 filter byte per row
    const raw_len = stride * height;
    if (raw_len > max_raw_bytes) return error.TooLarge;
    const raw = try alloc.alloc(u8, @intCast(raw_len));
    defer alloc.free(raw);

    {
        var in: std.Io.Reader = .fixed(idat.items);
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        var dec = flate.Decompress.init(&in, .zlib, window);
        dec.reader.readSliceAll(raw) catch return error.BadData;
    }

    const filter_bpp: usize = @intCast(@max(1, bits_pp / 8));
    try unfilter(raw, @intCast(stride), height, filter_bpp);

    const pixels = try alloc.alloc(u32, @as(usize, width) * height);
    errdefer alloc.free(pixels);
    convert(raw, pixels, @intCast(stride), width, height, color_type, bit_depth, &palette, trns_key);

    return .{ .width = width, .height = height, .pixels = pixels };
}

/// Reverse PNG row filters in place. Hot path: lengths were validated by the
/// caller (raw.len == stride * height, stride == 1 + line bytes).
fn unfilter(raw: []u8, stride: usize, height: u32, bpp: usize) !void {
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

/// Expand unfiltered scanlines to 0xAARRGGBB.
fn convert(raw: []const u8, pixels: []u32, stride: usize, width: u32, height: u32, color_type: u8, depth: u8, palette: *const [256]u32, trns: ?[3]u16) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * stride + 1 ..][0 .. stride - 1];
        const out = pixels[y * width ..][0..width];
        if (depth < 8) {
            // 1/2/4-bit gray or palette
            const per_byte = 8 / depth;
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            for (out, 0..) |*d, x| {
                const byte = line[x / per_byte];
                const shift: u3 = @intCast(8 - depth * (1 + x % per_byte));
                const v = (byte >> shift) & mask;
                if (color_type == 3) {
                    d.* = palette[v];
                } else {
                    const g: u32 = @as(u32, v) * 255 / mask;
                    const transparent = if (trns) |t| t[0] == v else false;
                    d.* = (if (transparent) @as(u32, 0) else 0xFF000000) | (g << 16) | (g << 8) | g;
                }
            }
            continue;
        }
        const bps: usize = depth / 8; // bytes per sample
        const S = struct {
            fn sample(l: []const u8, i: usize, b: usize) u16 {
                return if (b == 2) std.mem.readInt(u16, l[i * 2 ..][0..2], .big) else l[i];
            }
            fn hi(l: []const u8, i: usize, b: usize) u32 {
                return l[i * b]; // high byte of the sample
            }
        };
        switch (color_type) {
            0 => for (out, 0..) |*d, x| {
                const g = S.hi(line, x, bps);
                const transparent = if (trns) |t| t[0] == S.sample(line, x, bps) else false;
                d.* = (if (transparent) @as(u32, 0) else 0xFF000000) | (g << 16) | (g << 8) | g;
            },
            2 => for (out, 0..) |*d, x| {
                const r = S.hi(line, x * 3, bps);
                const g = S.hi(line, x * 3 + 1, bps);
                const b = S.hi(line, x * 3 + 2, bps);
                const transparent = if (trns) |t|
                    t[0] == S.sample(line, x * 3, bps) and t[1] == S.sample(line, x * 3 + 1, bps) and t[2] == S.sample(line, x * 3 + 2, bps)
                else
                    false;
                d.* = (if (transparent) @as(u32, 0) else 0xFF000000) | (r << 16) | (g << 8) | b;
            },
            3 => for (out, 0..) |*d, x| {
                d.* = palette[line[x]];
            },
            4 => for (out, 0..) |*d, x| {
                const g = S.hi(line, x * 2, bps);
                d.* = (S.hi(line, x * 2 + 1, bps) << 24) | (g << 16) | (g << 8) | g;
            },
            6 => for (out, 0..) |*d, x| {
                d.* = (S.hi(line, x * 4 + 3, bps) << 24) | (S.hi(line, x * 4, bps) << 16) |
                    (S.hi(line, x * 4 + 1, bps) << 8) | S.hi(line, x * 4 + 2, bps);
            },
            else => unreachable,
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
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

// --- encoder ---

pub const EncodeOptions = struct {
    /// worker threads for large images; 0 = one per CPU (capped)
    threads: u32 = 0,
    /// adaptive per-row filters; false writes filter 0 everywhere
    filter: bool = true,
};

/// Encode opaque 8-bit RGB PNG from 0xAARRGGBB pixels (alpha ignored).
/// Large images are compressed on worker threads, which allocate from
/// `alloc` concurrently: it must be thread-safe (DebugAllocator and
/// smp_allocator are; pass .threads = 1 to encodeWith otherwise).
pub fn encode(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    return encodeWith(alloc, pixels, width, height, .{});
}

const enc_bpp = 3;
/// rows are filtered with this many zero bytes in front, so the "left"
/// neighbour of the first pixel needs no special case
const pad = 32;
const V = @Vector(32, u8);
const VI = @Vector(32, i16);

/// Filter one row (RGB bytes in `cur`/`prev`, both with `pad` leading
/// zeros) into `out` (filter byte + data), choosing the filter with the
/// minimum sum of absolute differences.
fn filterRow(cur: []const u8, prev: []const u8, out: []u8, adaptive: bool) void {
    const n = cur.len - pad;
    if (!adaptive) {
        out[0] = 0;
        @memcpy(out[1..], cur[pad..]);
        return;
    }
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
    out[0] = best;
    const dst = out[1..];
    i = 0;
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

/// One band of rows compressed into a raw deflate fragment.
const Band = struct {
    pixels: []const u32,
    width: u32,
    y0: u32,
    y1: u32,
    last: bool,
    filter: bool,
    alloc: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    adler: u32 = 1,
    len: u64 = 0,
    err: ?anyerror = null,

    fn run(self: *Band) void {
        self.compress() catch |e| {
            self.err = e;
        };
    }

    fn compress(self: *Band) !void {
        const alloc = self.alloc;
        const w: usize = self.width;
        const row_len = w * enc_bpp;
        const bufs = try alloc.alloc(u8, 2 * (pad + row_len) + 1 + row_len);
        defer alloc.free(bufs);
        var cur = bufs[0 .. pad + row_len];
        var prev = bufs[pad + row_len ..][0 .. pad + row_len];
        const filtered = bufs[2 * (pad + row_len) ..];
        @memset(cur[0..pad], 0);
        @memset(prev, 0);
        if (self.y0 > 0) toRgb(self.pixels[(self.y0 - 1) * w ..][0..w], prev[pad..]);

        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        const comp = try alloc.create(flate.Compress);
        defer alloc.destroy(comp);
        const raw_len = @as(usize, self.y1 - self.y0) * (row_len + 1);
        try self.out.ensureUnusedCapacity(raw_len / 8 + 1024);
        // the probe reuses the window before the real compressor starts
        // writing, so each needs its own
        const probe_window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(probe_window);
        comp.* = try flate.Compress.init(&self.out.writer, window, .raw, .level_6);

        // probe state for choosing None vs adaptive filters per segment
        var probe: ?*flate.Compress = null;
        defer if (probe) |p| alloc.destroy(p);
        var probe_bufs: []u8 = &.{};
        defer alloc.free(probe_bufs);
        if (self.filter) {
            probe = try alloc.create(flate.Compress);
            probe_bufs = try alloc.alloc(u8, 2 * (pad + row_len) + 1 + row_len + 64);
        }

        var adler: std.hash.Adler32 = .{};
        var adaptive = self.filter;
        var y = self.y0;
        while (y < self.y1) : (y += 1) {
            if (self.filter and (y - self.y0) % segment_rows == 0) {
                adaptive = try self.probeAdaptive(probe.?, probe_window, probe_bufs, y, @min(self.y1, y + segment_rows));
            }
            toRgb(self.pixels[y * w ..][0..w], cur[pad..]);
            filterRow(cur, prev, filtered, adaptive);
            adler.update(filtered);
            try comp.writer.writeAll(filtered);
            std.mem.swap([]u8, &cur, &prev);
        }
        // a non-final band ends byte-aligned with no BFINAL block, so the
        // next band's independent deflate stream can follow it directly
        if (self.last) try comp.finish() else try comp.writer.flush();
        self.adler = adler.adler;
        self.len = raw_len;
    }

    /// Whether adaptive filtering beats filter None on rows [ys, ye): MSAD
    /// wins on photos and gradients but often loses on UI, where it breaks
    /// the exact repeats (glyphs, borders) LZ77 finds in unfiltered rows.
    /// Decided by fast-compressing a few sample rows both ways.
    fn probeAdaptive(self: *Band, probe: *flate.Compress, window: []u8, bufs: []u8, ys: u32, ye: u32) !bool {
        const w: usize = self.width;
        const row_len = w * enc_bpp;
        var cur = bufs[0 .. pad + row_len];
        var prev = bufs[pad + row_len ..][0 .. pad + row_len];
        const filtered = bufs[2 * (pad + row_len) ..][0 .. 1 + row_len];
        const sink_buf = bufs[2 * (pad + row_len) + 1 + row_len ..];
        const mid = ys + (ye - ys) / 2;
        const groups = [2][2]u32{ .{ ys, @min(ye, ys + probe_rows) }, .{ mid, @min(ye, mid + probe_rows) } };
        var sizes: [2]u64 = undefined;
        for (0..2) |mode| {
            var sink: std.Io.Writer.Discarding = .init(sink_buf);
            probe.* = try flate.Compress.init(&sink.writer, window, .raw, .level_6);
            for (groups, 0..) |g, gi| {
                if (gi == 1 and g[0] < groups[0][1]) break; // overlapping: short segment
                @memset(cur[0..pad], 0);
                @memset(prev, 0);
                if (g[0] > 0) toRgb(self.pixels[(g[0] - 1) * w ..][0..w], prev[pad..]);
                var y = g[0];
                while (y < g[1]) : (y += 1) {
                    toRgb(self.pixels[y * w ..][0..w], cur[pad..]);
                    filterRow(cur, prev, filtered, mode == 1);
                    try probe.writer.writeAll(filtered);
                    std.mem.swap([]u8, &cur, &prev);
                }
            }
            try probe.finish();
            sizes[mode] = sink.fullCount();
        }
        return sizes[1] < sizes[0];
    }
};

/// rows per filter-strategy decision, and sample rows per probe group
const segment_rows = 64;
const probe_rows = 4;

fn toRgb(src: []const u32, dst: []u8) void {
    for (src, 0..) |p, x| {
        dst[x * 3] = @truncate(p >> 16);
        dst[x * 3 + 1] = @truncate(p >> 8);
        dst[x * 3 + 2] = @truncate(p);
    }
}

/// adler32 of A ++ B from adler32(A), adler32(B) and len(B) (zlib's
/// adler32_combine).
fn adlerCombine(a1: u32, a2: u32, len2: u64) u32 {
    const base: u64 = 65521;
    const rem = len2 % base;
    var sum1: u64 = a1 & 0xFFFF;
    var sum2: u64 = (rem * sum1) % base;
    sum1 += (a2 & 0xFFFF) + base - 1;
    sum2 += (a1 >> 16) + (a2 >> 16) + base - rem;
    if (sum1 >= base) sum1 -= base;
    if (sum1 >= base) sum1 -= base;
    if (sum2 >= base * 2) sum2 -= base * 2;
    if (sum2 >= base) sum2 -= base;
    return @intCast(sum1 | (sum2 << 16));
}

pub fn encodeWith(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, opts: EncodeOptions) ![]u8 {
    if (width == 0 or height == 0 or width > 0x7FFFFFFF / 4 or height > 0x7FFFFFFF) return error.BadDimensions;
    if (pixels.len != @as(u64, width) * height) return error.BadDimensions;

    // bands of at least ~1 MB of raw data each, one per worker
    const raw_total: u64 = @as(u64, height) * (@as(u64, width) * enc_bpp + 1);
    const cpus: u32 = if (opts.threads != 0) opts.threads else @intCast(@min(16, std.Thread.getCpuCount() catch 1));
    const by_size: u32 = @intCast(@max(1, @min(64, raw_total / (256 << 10))));
    const n_bands: u32 = @max(1, @min(@min(cpus, by_size), height));
    const rows_per = (height + n_bands - 1) / n_bands;

    const bands = try alloc.alloc(Band, n_bands);
    defer alloc.free(bands);
    var n_init: usize = 0;
    defer for (bands[0..n_init]) |*b| b.out.deinit();
    for (bands, 0..) |*b, i| {
        const y0: u32 = @intCast(@min(height, i * rows_per));
        const y1: u32 = @intCast(@min(height, (i + 1) * rows_per));
        b.* = .{ .pixels = pixels, .width = width, .y0 = y0, .y1 = y1, .last = i + 1 == n_bands, .filter = opts.filter, .alloc = alloc, .out = .init(alloc) };
        n_init += 1;
    }

    var threads: [64]?std.Thread = @splat(null);
    for (bands[1..], 1..) |*b, i| {
        threads[i] = std.Thread.spawn(.{}, Band.run, .{b}) catch null;
        if (threads[i] == null) b.run(); // no thread: do it here
    }
    bands[0].run();
    for (threads[1..n_bands]) |t| if (t) |th| th.join();
    for (bands) |*b| if (b.err) |e| return e;

    var adler: u32 = bands[0].adler;
    var deflate_len: usize = 0;
    for (bands, 0..) |*b, i| {
        if (i > 0) adler = adlerCombine(adler, b.adler, b.len);
        deflate_len += b.out.written().len;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, deflate_len + 128);
    out.appendSliceAssumeCapacity(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type rgb
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // no interlace
    try writeChunk(alloc, &out, "IHDR", &ihdr);

    // IDAT: zlib header, the bands' deflate fragments, adler32
    const zlib_header = [2]u8{ 0x78, 0x5E };
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, adler, .big);
    const idat_len = 2 + deflate_len + 4;
    if (idat_len > 0x7FFFFFFF) return error.TooLarge;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(idat_len), .big);
    try out.appendSlice(alloc, &len_buf);
    var crc = std.hash.Crc32.init();
    crc.update("IDAT");
    try out.appendSlice(alloc, "IDAT");
    crc.update(&zlib_header);
    try out.appendSlice(alloc, &zlib_header);
    for (bands) |*b| {
        crc.update(b.out.written());
        try out.appendSlice(alloc, b.out.written());
    }
    crc.update(&adler_be);
    try out.appendSlice(alloc, &adler_be);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(alloc, &crc_buf);

    try writeChunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

fn writeChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try out.appendSlice(alloc, &len_buf);
    try out.appendSlice(alloc, chunk_type);
    try out.appendSlice(alloc, data);
    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try out.appendSlice(alloc, &crc_buf);
}

fn testImage(px: []u32, w: u32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (px, 0..) |*p, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        // flat areas, gradients and noise, like a screenshot
        p.* = if ((x / 7 + y / 5) % 3 == 0)
            0xFF000000 | ((x * 8 & 0xFF) << 16) | ((y * 13 & 0xFF) << 8) | @as(u32, @intCast(i % 251))
        else if (r.intRangeAtMost(u8, 0, 9) == 0)
            0xFF000000 | @as(u32, r.int(u24))
        else
            0xFF202428;
    }
}

test "png roundtrip" {
    const alloc = std.testing.allocator;
    const w = 31;
    const h = 17;
    var pixels: [w * h]u32 = undefined;
    for (&pixels, 0..) |*p, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        p.* = 0xFF000000 | (x * 8 << 16) | (y * 13 << 8) | @as(u32, @intCast(i % 251));
    }
    const encoded = try encode(alloc, &pixels, w, h);
    defer alloc.free(encoded);

    var img = try decode(alloc, encoded);
    defer img.deinit(alloc);
    try std.testing.expectEqual(@as(u32, w), img.width);
    try std.testing.expectEqual(@as(u32, h), img.height);
    for (pixels, img.pixels) |expected, got| {
        try std.testing.expectEqual(expected, got);
    }
}

test "png parallel bands roundtrip, every filter, odd sizes" {
    const alloc = std.testing.allocator;
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 300 }, .{ 300, 1 }, .{ 11, 7 }, .{ 640, 480 }, .{ 1023, 517 } };
    for (sizes, 0..) |sz, k| {
        const w = sz[0];
        const h = sz[1];
        const px = try alloc.alloc(u32, w * h);
        defer alloc.free(px);
        testImage(px, w, k);
        for ([_]u32{ 1, 3, 8 }) |threads| {
            for ([_]bool{ true, false }) |filter| {
                const enc = try encodeWith(alloc, px, w, h, .{ .threads = threads, .filter = filter });
                defer alloc.free(enc);
                var img = try decode(alloc, enc);
                defer img.deinit(alloc);
                try std.testing.expectEqualSlices(u32, px, img.pixels);
            }
        }
    }
    try std.testing.expectError(error.BadDimensions, encode(alloc, &.{}, 0, 0));
    try std.testing.expectError(error.BadDimensions, encode(alloc, &.{0}, 2, 1));
}

test "adler32 combine" {
    const a = "hello, ";
    const b = "world and more bytes";
    const whole = std.hash.Adler32.hash(a ++ b);
    try std.testing.expectEqual(whole, adlerCombine(std.hash.Adler32.hash(a), std.hash.Adler32.hash(b), b.len));
}

fn readTestFile(alloc: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const linux = std.os.linux;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [16384]u8 = undefined;
    while (list.items.len < 4 * 1024 * 1024) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// Decode must fail cleanly (never panic or over-allocate) on mutated input.
fn fuzzDecode(alloc: std.mem.Allocator, seed_png: []const u8, iterations: usize, rng_seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(rng_seed);
    const r = prng.random();
    const buf = try alloc.alloc(u8, seed_png.len + 64);
    defer alloc.free(buf);
    for (0..iterations) |_| {
        var len = seed_png.len;
        @memcpy(buf[0..len], seed_png);
        const n_mut = r.intRangeAtMost(u8, 1, 8);
        for (0..n_mut) |_| {
            if (len == 0) break;
            switch (r.intRangeAtMost(u8, 0, 4)) {
                0 => buf[r.uintLessThan(usize, len)] = r.int(u8),
                1 => buf[r.uintLessThan(usize, len)] ^= @as(u8, 1) << r.int(u3),
                2 => len = r.intRangeAtMost(usize, 0, len), // truncate
                3 => { // overwrite a 32-bit field with an extreme value
                    if (len >= 4) {
                        const at = r.uintLessThan(usize, len - 3);
                        const vals = [_]u32{ 0, 1, 0x7FFFFFFF, 0xFFFFFFFF, 0x10000, 16385 };
                        std.mem.writeInt(u32, buf[at..][0..4], vals[r.uintLessThan(usize, vals.len)], .big);
                    }
                },
                else => if (len < buf.len) { // insert a byte
                    const at = r.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = r.int(u8);
                    len += 1;
                },
            }
        }
        if (decode(alloc, buf[0..len])) |img| {
            var m = img;
            m.deinit(alloc);
        } else |_| {}
    }
}

test "png decoder survives mutated input" {
    const alloc = std.testing.allocator;
    // embedded seed: a small encoded image
    var px: [24 * 16]u32 = undefined;
    testImage(&px, 24, 7);
    const seed = try encode(alloc, &px, 24, 16);
    defer alloc.free(seed);
    try fuzzDecode(alloc, seed, 3000, 1);

    // real-world seeds when present (palette, gray, alpha, 16-bit...)
    const files = [_][:0]const u8{
        "/usr/share/iso-flags-png-320x240/in.png",
        "/usr/share/themes/Adwaita/gtk-2.0/assets/entry-background.png", // 1-bit gray
        "/usr/share/javascript/jquery-ui/themes/base/images/ui-bg_flat_0_aaaaaa_40x100.png", // 1-bit palette
        "/usr/share/gimp/3.0/help/sv/images/filters/examples/decor-add-bevel20.png", // 2-bit palette
        "/usr/share/themes/Adwaita-dark/gtk-2.0/assets/notebook-entry-insensitive.png", // 4-bit palette
        "/usr/share/lyx/examples/Presentations/beamer-knight4-mask.png", // gray
        "/usr/share/lyx/examples/Books/koma-book-80x15.png", // rgb
        "/usr/share/lyx/examples/Curricula_Vitae/CV-image.png", // palette
        "/usr/share/themes/Blue-Submarine/gtk-2.0/assets/null.png", // gray+alpha
        "/usr/share/lyx/images/oxygen/iconsize.png", // rgba
        "/usr/share/lyx/images/classic/buffer-reload.png", // 16-bit rgba
    };
    for (files, 0..) |path, i| {
        const data = readTestFile(alloc, path) catch continue;
        defer alloc.free(data);
        // the unmodified file must decode
        var img = try decode(alloc, data);
        img.deinit(alloc);
        try fuzzDecode(alloc, data, 400, 100 + i);
    }
}

test "png decoder rejects hostile headers before allocating" {
    const alloc = std.testing.allocator;
    var px: [4]u32 = @splat(0xFF336699);
    const good = try encode(alloc, &px, 2, 2);
    defer alloc.free(good);
    const bad = try alloc.dupe(u8, good);
    defer alloc.free(bad);
    // IHDR width = 0x7FFFFFFF
    std.mem.writeInt(u32, bad[16..20], 0x7FFFFFFF, .big);
    try std.testing.expectError(error.TooLarge, decode(alloc, bad));
    std.mem.writeInt(u32, bad[16..20], 16384, .big);
    std.mem.writeInt(u32, bad[20..24], 16384, .big);
    try std.testing.expectError(error.TooLarge, decode(alloc, bad));
    // chunk length past the end
    @memcpy(bad, good);
    std.mem.writeInt(u32, bad[8..12], 0xFFFFFFF0, .big);
    try std.testing.expectError(error.Truncated, decode(alloc, bad));
    try std.testing.expectError(error.NotPng, decode(alloc, good[0..4]));
    try std.testing.expectError(error.Truncated, decode(alloc, good[0 .. good.len - 20]));
}
