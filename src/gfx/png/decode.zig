//! PNG decoder: gray/RGB/palette/gray+alpha/RGBA at 1-16 bits, tRNS,
//! plain or Adam7 interlaced, to 0xAARRGGBB pixels.
//!
//! The input is untrusted: chunk lengths, IHDR fields and the decompressed
//! size are all bounded before anything is allocated.

const std = @import("std");
const flate = std.compress.flate;
const chunks = @import("chunks.zig");
const unfilter = @import("filters.zig").unfilter;

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

/// Decoder limits: per side, total pixels, and decompressed bytes.
pub const max_side = 16384;
pub const max_pixels = 64 * 1024 * 1024;
const max_raw_bytes = 512 * 1024 * 1024;

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &chunks.signature)) return error.NotPng;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);
    const info = try readChunks(alloc, data, &idat);
    const hdr = info.header;

    const passes: []const Pass = if (hdr.interlaced) &adam7 else &.{whole_image};
    const raw_len, const max_pass_px = rawSize(hdr, passes);
    if (raw_len > max_raw_bytes) return error.TooLarge;
    const raw = try alloc.alloc(u8, @intCast(raw_len));
    defer alloc.free(raw);
    try inflate(alloc, idat.items, raw);

    const pixels = try alloc.alloc(u32, @as(usize, hdr.width) * hdr.height);
    errdefer alloc.free(pixels);
    if (!hdr.interlaced) {
        try decodePass(&info, whole_image, raw, pixels);
    } else {
        const sub_px = try alloc.alloc(u32, @intCast(max_pass_px));
        defer alloc.free(sub_px);
        var off: usize = 0;
        for (passes) |ps| {
            const pw, const ph = ps.size(hdr.width, hdr.height);
            if (pw == 0 or ph == 0) continue;
            const part = raw[off..][0 .. hdr.stride(pw) * ph];
            off += part.len;
            const sp = sub_px[0 .. @as(usize, pw) * ph];
            try decodePass(&info, ps, part, sp);
            scatterPass(ps, pw, ph, sp, pixels, hdr.width);
        }
    }

    return .{ .width = hdr.width, .height = hdr.height, .pixels = pixels };
}

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlaced: bool,

    /// Parse and validate the IHDR payload.
    fn parse(chunk: []const u8) !Header {
        if (chunk.len != 13) return error.BadIhdr;
        const h: Header = .{
            .width = std.mem.readInt(u32, chunk[0..4], .big),
            .height = std.mem.readInt(u32, chunk[4..8], .big),
            .bit_depth = chunk[8],
            .color_type = chunk[9],
            .interlaced = chunk[12] == 1,
        };
        if (chunk[10] != 0 or chunk[11] != 0) return error.BadIhdr;
        if (chunk[12] > 1) return error.BadIhdr;
        if (h.width == 0 or h.height == 0) return error.BadIhdr;
        if (h.width > max_side or h.height > max_side) return error.TooLarge;
        if (@as(u64, h.width) * h.height > max_pixels) return error.TooLarge;
        const d = h.bit_depth;
        const depth_ok = switch (h.color_type) {
            0 => d == 1 or d == 2 or d == 4 or d == 8 or d == 16,
            3 => d == 1 or d == 2 or d == 4 or d == 8,
            2, 4, 6 => d == 8 or d == 16,
            else => return error.ColorTypeUnsupported,
        };
        if (!depth_ok) return error.BitDepthUnsupported;
        return h;
    }

    fn bitsPerPixel(h: Header) u64 {
        const channels: u32 = switch (h.color_type) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
        return @as(u64, channels) * h.bit_depth;
    }

    /// Bytes per filtered scanline of `w` pixels, filter byte included.
    fn stride(h: Header, w: u32) usize {
        return @intCast(1 + (@as(u64, w) * h.bitsPerPixel() + 7) / 8);
    }
};

/// IHDR plus the colour information from PLTE and tRNS.
const Info = struct {
    header: Header,
    palette: [256]u32 = @splat(0xFF000000),
    /// tRNS for gray/RGB: the one fully transparent sample value
    trns_key: ?[3]u16 = null,

    fn setPalette(self: *Info, chunk: []const u8) void {
        const palette_len = @min(self.palette.len, chunk.len / 3);
        for (0..palette_len) |i| {
            self.palette[i] = 0xFF000000 |
                (@as(u32, chunk[i * 3]) << 16) |
                (@as(u32, chunk[i * 3 + 1]) << 8) |
                @as(u32, chunk[i * 3 + 2]);
        }
    }

    fn setTransparency(self: *Info, chunk: []const u8) void {
        switch (self.header.color_type) {
            3 => for (chunk[0..@min(chunk.len, 256)], 0..) |a, i| {
                self.palette[i] = (self.palette[i] & 0x00FFFFFF) | (@as(u32, a) << 24);
            },
            0 => if (chunk.len >= 2) {
                const g = std.mem.readInt(u16, chunk[0..2], .big);
                self.trns_key = .{ g, g, g };
            },
            2 => if (chunk.len >= 6) {
                self.trns_key = .{
                    std.mem.readInt(u16, chunk[0..2], .big),
                    std.mem.readInt(u16, chunk[2..4], .big),
                    std.mem.readInt(u16, chunk[4..6], .big),
                };
            },
            else => {},
        }
    }
};

/// Read IHDR (which must come first), PLTE and tRNS, and collect the
/// IDAT payloads into `idat`.
fn readChunks(alloc: std.mem.Allocator, data: []const u8, idat: *std.ArrayList(u8)) !Info {
    var reader: chunks.Reader = .{ .data = data };
    const first = (try reader.next()) orelse return error.BadIhdr;
    if (!std.mem.eql(u8, first.type, "IHDR")) return error.BadIhdr;
    var info: Info = .{ .header = try Header.parse(first.data) };
    while (try reader.next()) |chunk| {
        const t = chunk.type;
        if (std.mem.eql(u8, t, "PLTE")) {
            info.setPalette(chunk.data);
        } else if (std.mem.eql(u8, t, "tRNS")) {
            info.setTransparency(chunk.data);
        } else if (std.mem.eql(u8, t, "IDAT")) {
            try idat.appendSlice(alloc, chunk.data);
        } else if (std.mem.eql(u8, t, "IEND")) {
            break;
        } else if (t[0] & 0x20 == 0) {
            return error.UnknownCriticalChunk;
        }
    }
    return info;
}

/// Total filtered bytes of all passes, and the pixel count of the largest
/// pass. Every pass is an independent filtered sub-image, stored one after
/// the other (a pass with no columns or rows stores nothing).
fn rawSize(hdr: Header, passes: []const Pass) struct { u64, u64 } {
    const bits_pp = hdr.bitsPerPixel();
    var raw_len: u64 = 0;
    var max_pass_px: u64 = 0;
    for (passes) |ps| {
        const pw, const ph = ps.size(hdr.width, hdr.height);
        if (pw == 0 or ph == 0) continue;
        raw_len += (1 + (@as(u64, pw) * bits_pp + 7) / 8) * ph;
        max_pass_px = @max(max_pass_px, @as(u64, pw) * ph);
    }
    return .{ raw_len, max_pass_px };
}

/// Decompress the zlib stream into exactly `raw.len` bytes.
fn inflate(alloc: std.mem.Allocator, zdata: []const u8, raw: []u8) !void {
    var in: std.Io.Reader = .fixed(zdata);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var dec = flate.Decompress.init(&in, .zlib, window);
    dec.reader.readSliceAll(raw) catch return error.BadData;
}

/// Unfilter one pass's scanlines in `raw` and convert them into `out`
/// (pw*ph pixels).
fn decodePass(info: *const Info, ps: Pass, raw: []u8, out: []u32) !void {
    const hdr = info.header;
    const pw, const ph = ps.size(hdr.width, hdr.height);
    const stride = hdr.stride(pw);
    const filter_bpp: usize = @intCast(@max(1, hdr.bitsPerPixel() / 8));
    try unfilter(raw, stride, ph, filter_bpp);
    convert(raw, out, stride, pw, ph, hdr.color_type, hdr.bit_depth, &info.palette, info.trns_key);
}

/// Copy a pass's pixels to their places in the full image.
fn scatterPass(ps: Pass, pw: u32, ph: u32, sp: []const u32, pixels: []u32, width: u32) void {
    for (0..ph) |j| {
        const y = ps.y0 + j * ps.dy;
        for (0..pw) |i| pixels[y * width + ps.x0 + i * ps.dx] = sp[j * pw + i];
    }
}

pub const Pass = struct {
    x0: u32,
    y0: u32,
    dx: u32,
    dy: u32,

    /// Columns and rows of this pass in a w x h image.
    pub fn size(p: Pass, w: u32, h: u32) struct { u32, u32 } {
        const pw = if (w > p.x0) (w - p.x0 + p.dx - 1) / p.dx else 0;
        const ph = if (h > p.y0) (h - p.y0 + p.dy - 1) / p.dy else 0;
        return .{ pw, ph };
    }
};

/// The single "pass" of a non-interlaced image.
pub const whole_image: Pass = .{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 };

pub const adam7 = [7]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};

/// Expand unfiltered scanlines to 0xAARRGGBB.
fn convert(raw: []const u8, pixels: []u32, stride: usize, width: u32, height: u32, color_type: u8, depth: u8, palette: *const [256]u32, trns: ?[3]u16) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const line = raw[y * stride + 1 ..][0 .. stride - 1];
        const out = pixels[y * width ..][0..width];
        if (depth < 8) {
            convertPackedRow(line, out, color_type, depth, palette, trns);
        } else {
            convertRow(line, out, color_type, depth / 8, palette, trns);
        }
    }
}

/// One row of 1/2/4-bit gray or palette samples.
inline fn convertPackedRow(line: []const u8, out: []u32, color_type: u8, depth: u8, palette: *const [256]u32, trns: ?[3]u16) void {
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
}

/// One row of 8- or 16-bit samples (`bps` bytes per sample); 16-bit
/// samples keep their high byte.
inline fn convertRow(line: []const u8, out: []u32, color_type: u8, bps: usize, palette: *const [256]u32, trns: ?[3]u16) void {
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

const encode = @import("encode.zig").encode;
const helpers = @import("testing.zig");
const testImage = helpers.testImage;
const fuzzDecode = helpers.fuzzDecode;
const readTestFile = helpers.readTestFile;
const buildTestPng = helpers.buildTestPng;
const testSample = helpers.testSample;

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

test "adam7 interlaced decode matches the same image non-interlaced" {
    const alloc = std.testing.allocator;
    var plte: [3 * 256]u8 = undefined;
    for (&plte, 0..) |*b, i| b.* = @truncate(i * 7);
    const Case = struct { ct: u8, depth: u8 };
    const cases = [_]Case{
        .{ .ct = 0, .depth = 1 },  .{ .ct = 0, .depth = 2 },  .{ .ct = 0, .depth = 4 },
        .{ .ct = 0, .depth = 8 },  .{ .ct = 0, .depth = 16 }, .{ .ct = 2, .depth = 8 },
        .{ .ct = 2, .depth = 16 }, .{ .ct = 3, .depth = 1 },  .{ .ct = 3, .depth = 4 },
        .{ .ct = 3, .depth = 8 },  .{ .ct = 4, .depth = 8 },  .{ .ct = 4, .depth = 16 },
        .{ .ct = 6, .depth = 8 },  .{ .ct = 6, .depth = 16 },
    };
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 2, 3 }, .{ 5, 1 }, .{ 1, 9 }, .{ 8, 8 }, .{ 13, 11 }, .{ 33, 17 } };
    inline for (cases) |cs| {
        for (sizes) |sz| {
            const pl: []const u8 = if (cs.ct == 3) &plte else &.{};
            const flat = try buildTestPng(alloc, sz[0], sz[1], cs.ct, cs.depth, false, pl, testSample(cs.depth));
            defer alloc.free(flat);
            const inter = try buildTestPng(alloc, sz[0], sz[1], cs.ct, cs.depth, true, pl, testSample(cs.depth));
            defer alloc.free(inter);
            var a = try decode(alloc, flat);
            defer a.deinit(alloc);
            var b = try decode(alloc, inter);
            defer b.deinit(alloc);
            try std.testing.expectEqualSlices(u32, a.pixels, b.pixels);
        }
    }
    // fuzz the interlaced path too
    const seed = try buildTestPng(alloc, 19, 13, 6, 8, true, &.{}, testSample(8));
    defer alloc.free(seed);
    try fuzzDecode(alloc, seed, 1500, 5);
    const seed2 = try buildTestPng(alloc, 21, 9, 3, 2, true, plte[0..12], testSample(2));
    defer alloc.free(seed2);
    try fuzzDecode(alloc, seed2, 1500, 6);
}
