//! Test-only helpers: synthetic images, a reference PNG writer for every
//! colour type, and a mutation fuzzer for the decoder.

const std = @import("std");
const flate = std.compress.flate;
const sys = @import("../../platform/api.zig").sys;
const chunks = @import("chunks.zig");
const dec = @import("decode.zig");
const paeth = @import("filters.zig").paeth;
const Pass = dec.Pass;

pub fn testImage(px: []u32, w: u32, seed: u64) void {
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

/// A sample file of the system, whole (up to 4 MiB); error when absent.
pub fn readTestFile(alloc: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    return sys.readFileAlloc(alloc, path, 4 * 1024 * 1024);
}

/// Decode must fail cleanly (never panic or over-allocate) on mutated input.
pub fn fuzzDecode(alloc: std.mem.Allocator, seed_png: []const u8, iterations: usize, rng_seed: u64) !void {
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
            mutate(r, buf, &len);
        }
        if (dec.decode(alloc, buf[0..len])) |img| {
            var m = img;
            m.deinit(alloc);
        } else |_| {}
    }
}

/// Apply one random mutation to buf[0..len.*] (len.* > 0).
fn mutate(r: std.Random, buf: []u8, len: *usize) void {
    switch (r.intRangeAtMost(u8, 0, 4)) {
        0 => buf[r.uintLessThan(usize, len.*)] = r.int(u8),
        1 => buf[r.uintLessThan(usize, len.*)] ^= @as(u8, 1) << r.int(u3),
        2 => len.* = r.intRangeAtMost(usize, 0, len.*), // truncate
        3 => { // overwrite a 32-bit field with an extreme value
            if (len.* >= 4) {
                const at = r.uintLessThan(usize, len.* - 3);
                const vals = [_]u32{ 0, 1, 0x7FFFFFFF, 0xFFFFFFFF, 0x10000, 16385 };
                std.mem.writeInt(u32, buf[at..][0..4], vals[r.uintLessThan(usize, vals.len)], .big);
            }
        },
        else => if (len.* < buf.len) { // insert a byte
            const at = r.uintLessThan(usize, len.* + 1);
            std.mem.copyBackwards(u8, buf[at + 1 .. len.* + 1], buf[at..len.*]);
            buf[at] = r.int(u8);
            len.* += 1;
        },
    }
}

/// Test-only PNG writer for any colour type, bit depth and interlace,
/// cycling through all five row filters. `sample(x, y, ch)` gives each
/// channel value (< 2^depth).
pub fn buildTestPng(alloc: std.mem.Allocator, w: u32, h: u32, ct: u8, depth: u8, interlace: bool, plte: []const u8, comptime sample: fn (u32, u32, u32) u16) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    const fmt: Format = .{ .channels = channelCount(ct), .depth = depth };
    const passes: []const Pass = if (interlace) &dec.adam7 else &.{dec.whole_image};
    var row_no: usize = 0;
    for (passes) |ps| {
        const pw, const ph = ps.size(w, h);
        if (pw == 0 or ph == 0) continue;
        try appendPass(alloc, &raw, fmt, ps, pw, ph, &row_no, sample);
    }
    var z: std.Io.Writer.Allocating = .init(alloc);
    defer z.deinit();
    try zlibCompress(alloc, &z, raw.items);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &chunks.signature);
    const ihdr = chunks.ihdr(w, h, depth, ct, interlace);
    try chunks.writeChunk(alloc, &out, "IHDR", &ihdr);
    if (plte.len > 0) try chunks.writeChunk(alloc, &out, "PLTE", plte);
    try chunks.writeChunk(alloc, &out, "IDAT", z.written());
    try chunks.writeChunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

const Format = struct {
    channels: u32,
    depth: u8,

    fn bits(f: Format) u32 {
        return f.channels * f.depth;
    }
};

fn channelCount(ct: u8) u32 {
    return switch (ct) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        else => 4,
    };
}

/// Append one pass's filtered scanlines; the filter type cycles with the
/// running row number `row_no`.
fn appendPass(alloc: std.mem.Allocator, raw: *std.ArrayList(u8), fmt: Format, ps: Pass, pw: u32, ph: u32, row_no: *usize, comptime sample: fn (u32, u32, u32) u16) !void {
    const lb = (pw * fmt.bits() + 7) / 8;
    const prev = try alloc.alloc(u8, lb);
    defer alloc.free(prev);
    @memset(prev, 0);
    const cur = try alloc.alloc(u8, lb);
    defer alloc.free(cur);
    for (0..ph) |j| {
        const y: u32 = @intCast(ps.y0 + j * ps.dy);
        packRow(cur, fmt, ps, pw, y, sample);
        const filter: u8 = @intCast(row_no.* % 5);
        row_no.* += 1;
        try appendFiltered(alloc, raw, filter, cur, prev, @max(1, fmt.bits() / 8));
        @memcpy(prev, cur);
    }
}

/// Pack the samples of pass row `y` into `cur` (big-endian, MSB first).
fn packRow(cur: []u8, fmt: Format, ps: Pass, pw: u32, y: u32, comptime sample: fn (u32, u32, u32) u16) void {
    const depth = fmt.depth;
    @memset(cur, 0);
    var bit: usize = 0;
    for (0..pw) |i| {
        const x: u32 = @intCast(ps.x0 + i * ps.dx);
        for (0..fmt.channels) |chn| {
            const v = sample(x, y, @intCast(chn));
            if (depth == 16) {
                cur[bit / 8] = @intCast(v >> 8);
                cur[bit / 8 + 1] = @truncate(v);
            } else if (depth == 8) {
                cur[bit / 8] = @intCast(v);
            } else {
                const shift: u3 = @intCast(8 - depth - bit % 8);
                cur[bit / 8] |= @as(u8, @intCast(v)) << shift;
            }
            bit += depth;
        }
    }
}

/// Append the filter byte and `cur` filtered against `prev`.
fn appendFiltered(alloc: std.mem.Allocator, raw: *std.ArrayList(u8), filter: u8, cur: []const u8, prev: []const u8, bpp: usize) !void {
    try raw.append(alloc, filter);
    for (cur, 0..) |x, k| {
        const a: u8 = if (k >= bpp) cur[k - bpp] else 0;
        const b = prev[k];
        const c: u8 = if (k >= bpp) prev[k - bpp] else 0;
        try raw.append(alloc, switch (filter) {
            0 => x,
            1 => x -% a,
            2 => x -% b,
            3 => x -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
            else => x -% paeth(a, b, c),
        });
    }
}

fn zlibCompress(alloc: std.mem.Allocator, z: *std.Io.Writer.Allocating, data: []const u8) !void {
    try z.ensureUnusedCapacity(64);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var comp = try flate.Compress.init(&z.writer, window, .zlib, .default);
    try comp.writer.writeAll(data);
    try comp.finish();
}

pub fn testSample(comptime depth: u8) fn (u32, u32, u32) u16 {
    return struct {
        fn f(x: u32, y: u32, ch: u32) u16 {
            const v = (x *% 2654435761 ^ y *% 40503 ^ ch *% 97) >> 7;
            const max: u32 = (@as(u32, 1) << depth) - 1;
            return @intCast(v & max);
        }
    }.f;
}
