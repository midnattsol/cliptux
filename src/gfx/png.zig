//! Minimal PNG codec: enough to decode portal screenshots and other common
//! PNGs (gray/RGB/palette/gray+alpha/RGBA at 1-16 bits, tRNS,
//! non-interlaced) and encode annotated output (8-bit RGB). Pixels are
//! exchanged as 0xAARRGGBB u32 values (matching wl_shm xrgb8888 layout on
//! little-endian).
//!
//! The decoder treats its input as untrusted: chunk lengths, IHDR fields
//! and the decompressed size are all bounded before anything is allocated.

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
