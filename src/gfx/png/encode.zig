//! PNG encoder: 8-bit RGB or RGBA, a filter per row (minimum sum of
//! absolute differences), and for large images bands of rows deflated on
//! several threads, joined into one zlib stream.

const std = @import("std");
const chunks = @import("chunks.zig");
const bands_mod = @import("bands.zig");
const Band = bands_mod.Band;

pub const EncodeOptions = struct {
    /// worker threads for large images; 0 = one per CPU (capped)
    threads: u32 = 0,
    /// adaptive per-row filters; false writes filter 0 everywhere
    filter: bool = true,
    /// write RGBA (colour type 6) instead of RGB: never (default, alpha
    /// ignored), always, or auto (only when some pixel is not opaque)
    alpha: Alpha = .never,

    pub const Alpha = enum { never, always, auto };
};

/// Encode opaque 8-bit RGB PNG from 0xAARRGGBB pixels (alpha ignored;
/// encodeWith(.., .{ .alpha = .always/.auto }) writes RGBA).
/// Large images are compressed on worker threads, which allocate from
/// `alloc` concurrently: it must be thread-safe (DebugAllocator and
/// smp_allocator are; pass .threads = 1 to encodeWith otherwise).
pub fn encode(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    return encodeWith(alloc, pixels, width, height, .{});
}

pub fn encodeWith(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, opts: EncodeOptions) ![]u8 {
    if (width == 0 or height == 0 or width > 0x7FFFFFFF / 4 or height > 0x7FFFFFFF) return error.BadDimensions;
    if (pixels.len != @as(u64, width) * height) return error.BadDimensions;

    const with_alpha = wantsAlpha(opts.alpha, pixels);
    const bpp: u8 = if (with_alpha) 4 else 3;
    const n_bands = bandCount(width, height, bpp, opts.threads);

    const bands = try alloc.alloc(Band, n_bands);
    defer alloc.free(bands);
    initBands(bands, alloc, pixels, width, height, bpp, opts.filter);
    defer for (bands) |*b| b.out.deinit();
    try bands_mod.compressAll(bands);

    return assemble(alloc, bands, width, height, with_alpha);
}

fn wantsAlpha(mode: EncodeOptions.Alpha, pixels: []const u32) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .auto => for (pixels) |p| {
            if (p >> 24 != 0xFF) break true;
        } else false,
    };
}

/// One band per worker, each of at least ~256 KB of raw data.
fn bandCount(width: u32, height: u32, bpp: u8, threads: u32) u32 {
    const raw_total: u64 = @as(u64, height) * (@as(u64, width) * bpp + 1);
    const cpus: u32 = if (threads != 0) threads else @intCast(@min(16, std.Thread.getCpuCount() catch 1));
    const by_size: u32 = @intCast(@max(1, @min(64, raw_total / (256 << 10))));
    return @max(1, @min(@min(cpus, by_size), height));
}

/// Split the rows evenly over `bands`.
fn initBands(bands: []Band, alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, bpp: u8, filter: bool) void {
    const n_bands: u32 = @intCast(bands.len);
    const rows_per = (height + n_bands - 1) / n_bands;
    for (bands, 0..) |*b, i| {
        const y0: u32 = @intCast(@min(height, i * rows_per));
        const y1: u32 = @intCast(@min(height, (i + 1) * rows_per));
        b.* = .{ .pixels = pixels, .width = width, .y0 = y0, .y1 = y1, .last = i + 1 == n_bands, .filter = filter, .bpp = bpp, .alloc = alloc, .out = .init(alloc) };
    }
}

/// The PNG file: signature, IHDR, one IDAT holding the bands, IEND.
fn assemble(alloc: std.mem.Allocator, bands: []Band, width: u32, height: u32, with_alpha: bool) ![]u8 {
    var deflate_len: usize = 0;
    for (bands) |*b| deflate_len += b.out.written().len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, deflate_len + 128);
    out.appendSliceAssumeCapacity(&chunks.signature);
    const color_type: u8 = if (with_alpha) 6 else 2; // rgba / rgb
    const ihdr = chunks.ihdr(width, height, 8, color_type, false);
    try chunks.writeChunk(alloc, &out, "IHDR", &ihdr);
    try writeIdat(alloc, &out, bands, deflate_len);
    try chunks.writeChunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

/// IDAT: zlib header, the bands' deflate fragments, adler32.
fn writeIdat(alloc: std.mem.Allocator, out: *std.ArrayList(u8), bands: []Band, deflate_len: usize) !void {
    const zlib_header = [2]u8{ 0x78, 0x5E };
    var adler_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_be, bands_mod.combinedAdler(bands), .big);
    const idat_len = 2 + deflate_len + 4;
    if (idat_len > 0x7FFFFFFF) return error.TooLarge;
    var idat: chunks.Writer = try .begin(alloc, out, "IDAT", @intCast(idat_len));
    try idat.append(alloc, out, &zlib_header);
    for (bands) |*b| try idat.append(alloc, out, b.out.written());
    try idat.append(alloc, out, &adler_be);
    try idat.end(alloc, out);
}

const decode = @import("decode.zig").decode;
const testImage = @import("testing.zig").testImage;

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

test "png rgba: transparent pixels round-trip, rgb stays the default" {
    const alloc = std.testing.allocator;
    const w = 300;
    const h = 200;
    const px = try alloc.alloc(u32, w * h);
    defer alloc.free(px);
    testImage(px, w, 9);
    for (px, 0..) |*p, i| p.* = (p.* & 0x00FFFFFF) | (@as(u32, @intCast((i * 7) % 256)) << 24);
    for ([_]u32{ 1, 4 }) |threads| {
        for ([_]EncodeOptions.Alpha{ .always, .auto }) |mode| {
            const enc = try encodeWith(alloc, px, w, h, .{ .threads = threads, .alpha = mode });
            defer alloc.free(enc);
            try std.testing.expectEqual(@as(u8, 6), enc[25]);
            var img = try decode(alloc, enc);
            defer img.deinit(alloc);
            try std.testing.expectEqualSlices(u32, px, img.pixels);
        }
    }
    // default and .auto on an opaque image: RGB, alpha dropped
    const plain = try encode(alloc, px, w, h);
    defer alloc.free(plain);
    try std.testing.expectEqual(@as(u8, 2), plain[25]);
    var img = try decode(alloc, plain);
    defer img.deinit(alloc);
    for (px, img.pixels) |a, b| try std.testing.expectEqual(a | 0xFF000000, b);
    for (px) |*p| p.* |= 0xFF000000;
    const auto = try encodeWith(alloc, px, w, h, .{ .alpha = .auto });
    defer alloc.free(auto);
    try std.testing.expectEqual(@as(u8, 2), auto[25]);
    try std.testing.expectEqualSlices(u8, plain, auto);
}
