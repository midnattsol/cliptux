//! Minimal PNG codec: enough to decode portal screenshots (8-bit RGB/RGBA/
//! gray/palette, non-interlaced) and encode annotated output (8-bit RGB).
//! Pixels are exchanged as 0xAARRGGBB u32 values (matching wl_shm xrgb8888
//! layout on little-endian).

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

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &signature)) return error.NotPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var palette: [256]u32 = undefined;
    var palette_len: usize = 0;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    var pos: usize = 8;
    while (pos + 8 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        pos += 8;
        if (pos + chunk_len + 4 > data.len) return error.Truncated;
        const chunk = data[pos..][0..chunk_len];
        pos += chunk_len + 4; // skip crc

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk.len < 13) return error.BadIhdr;
            width = std.mem.readInt(u32, chunk[0..4], .big);
            height = std.mem.readInt(u32, chunk[4..8], .big);
            bit_depth = chunk[8];
            color_type = chunk[9];
            if (chunk[12] != 0) return error.InterlacedUnsupported;
            if (bit_depth != 8) return error.BitDepthUnsupported;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            palette_len = chunk.len / 3;
            for (0..palette_len) |i| {
                palette[i] = 0xFF000000 |
                    (@as(u32, chunk[i * 3]) << 16) |
                    (@as(u32, chunk[i * 3 + 1]) << 8) |
                    @as(u32, chunk[i * 3 + 2]);
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(alloc, chunk);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }
    if (width == 0 or height == 0) return error.BadIhdr;
    if (width > 16384 or height > 16384) return error.TooLarge;
    if (@as(u64, width) * height > 64 * 1024 * 1024) return error.TooLarge;

    const channels: u32 = switch (color_type) {
        0 => 1, // gray
        2 => 3, // rgb
        3 => 1, // palette
        4 => 2, // gray+alpha
        6 => 4, // rgba
        else => return error.ColorTypeUnsupported,
    };

    const stride = 1 + width * channels; // +1 filter byte per row
    const raw = try alloc.alloc(u8, stride * height);
    defer alloc.free(raw);

    {
        var in: std.Io.Reader = .fixed(idat.items);
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        var dec = flate.Decompress.init(&in, .zlib, window);
        try dec.reader.readSliceAll(raw);
    }

    try unfilter(raw, stride, height, channels);

    const pixels = try alloc.alloc(u32, width * height);
    errdefer alloc.free(pixels);
    convert(raw, pixels, stride, width, height, channels, color_type, palette[0..palette_len]);

    return .{ .width = width, .height = height, .pixels = pixels };
}

/// Reverse PNG row filters in place. Hot path: lengths were validated by the
/// caller (raw.len == stride * height, stride == 1 + width * channels).
fn unfilter(raw: []u8, stride: usize, height: u32, channels: u32) !void {
    @setRuntimeSafety(false);
    const bpp: usize = channels;
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
                    while (i < bpp) : (i += 1) line[i] +%= @intCast(@as(u16, p[1 + i]) / 2);
                    i = bpp;
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
                    while (i < bpp) : (i += 1) line[i] +%= p[1 + i]; // a=c=0 -> paeth=b
                    i = bpp;
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

/// Expand unfiltered scanlines to 0xAARRGGBB. Per-type loops keep the inner
/// loop branch-free; bounds were validated by the caller.
fn convert(raw: []const u8, pixels: []u32, stride: usize, width: u32, height: u32, channels: u32, color_type: u8, palette: []const u32) void {
    @setRuntimeSafety(false);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * stride + 1 ..][0 .. width * channels];
        const out = pixels[y * width ..][0..width];
        switch (color_type) {
            0 => for (out, 0..) |*d, x| {
                const g: u32 = line[x];
                d.* = 0xFF000000 | (g << 16) | (g << 8) | g;
            },
            2 => for (out, 0..) |*d, x| {
                const p = line[x * 3 ..];
                d.* = 0xFF000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
            },
            3 => for (out, 0..) |*d, x| {
                const idx = line[x];
                d.* = if (idx < palette.len) palette[idx] else 0xFF000000;
            },
            4 => for (out, 0..) |*d, x| {
                const p = line[x * 2 ..];
                const g: u32 = p[0];
                d.* = (@as(u32, p[1]) << 24) | (g << 16) | (g << 8) | g;
            },
            6 => for (out, 0..) |*d, x| {
                const p = line[x * 4 ..];
                d.* = (@as(u32, p[3]) << 24) | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
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

/// Encode opaque 8-bit RGB PNG from 0xAARRGGBB pixels (alpha ignored).
pub fn encode(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &signature);

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type rgb
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // no interlace
    try writeChunk(alloc, &out, "IHDR", &ihdr);

    // IDAT: zlib-compressed scanlines, filter 0
    var compressed: std.Io.Writer.Allocating = .init(alloc);
    defer compressed.deinit();
    try compressed.ensureUnusedCapacity(1024);
    {
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        var comp = try flate.Compress.init(&compressed.writer, window, .zlib, .default);

        const row_buf = try alloc.alloc(u8, 1 + width * 3);
        defer alloc.free(row_buf);
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            row_buf[0] = 0; // filter: none
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const px = pixels[y * width + x];
                row_buf[1 + x * 3] = @truncate(px >> 16);
                row_buf[1 + x * 3 + 1] = @truncate(px >> 8);
                row_buf[1 + x * 3 + 2] = @truncate(px);
            }
            try comp.writer.writeAll(row_buf);
        }
        try comp.finish();
    }
    try writeChunk(alloc, &out, "IDAT", compressed.written());

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
