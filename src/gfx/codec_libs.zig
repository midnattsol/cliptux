//! Image decoders loaded at run time, so Shotlet keeps zero build
//! dependencies: libwebp for WebP, libturbojpeg for the JPEGs our own
//! decoder refuses (progressive, CMYK). Missing libraries just mean those
//! files cannot be opened.

const std = @import("std");
const png = @import("png.zig");
const libs = @import("../platform/api.zig").libs;

const WebP = struct {
    WebPDecodeBGRA: *const fn ([*]const u8, usize, *c_int, *c_int) callconv(.c) ?[*]u8,
    WebPGetInfo: *const fn ([*]const u8, usize, *c_int, *c_int) callconv(.c) c_int,
    WebPFree: *const fn (?*anyopaque) callconv(.c) void,
};

const TurboJpeg = struct {
    tjInitDecompress: *const fn () callconv(.c) ?*anyopaque,
    tjDecompressHeader3: *const fn (?*anyopaque, [*]const u8, c_ulong, *c_int, *c_int, *c_int, *c_int) callconv(.c) c_int,
    tjDecompress2: *const fn (?*anyopaque, [*]const u8, c_ulong, [*]u8, c_int, c_int, c_int, c_int, c_int) callconv(.c) c_int,
    tjDestroy: *const fn (?*anyopaque) callconv(.c) c_int,
};

/// TJPF_BGRA: B, G, R, A bytes, which is 0xAARRGGBB on little-endian
const tjpf_bgra = 8;

fn Lib(comptime Api: type, comptime base: []const u8, comptime versions: []const []const u8) type {
    return struct {
        var api: ?Api = null;
        var tried = false;
        var lib: ?libs.Lib = null;

        fn get() ?Api {
            if (tried) return api;
            tried = true;
            lib = libs.open(base, versions);
            var l = &(lib orelse return null);
            var a: Api = undefined;
            const info = @typeInfo(Api).@"struct";
            inline for (info.field_names, info.field_types) |name, T| {
                @field(a, name) = l.lookup(T, name) orelse return null;
            }
            api = a;
            return api;
        }
    };
}

const webp_lib = Lib(WebP, "webp", &.{ "7", "6", "" });
const tj_lib = Lib(TurboJpeg, "turbojpeg", &.{ "0", "" });

pub fn isWebp(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

fn checkSize(w: c_int, h: c_int) !void {
    if (w <= 0 or h <= 0 or w > png.max_side or h > png.max_side) return error.TooBig;
    if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) > png.max_pixels) return error.TooBig;
}

pub fn decodeWebp(alloc: std.mem.Allocator, data: []const u8) !png.Image {
    const a = webp_lib.get() orelse return error.NoWebpLibrary;
    var w: c_int = 0;
    var h: c_int = 0;
    if (a.WebPGetInfo(data.ptr, data.len, &w, &h) == 0) return error.Corrupt;
    try checkSize(w, h);
    const px = a.WebPDecodeBGRA(data.ptr, data.len, &w, &h) orelse return error.Corrupt;
    defer a.WebPFree(px);
    try checkSize(w, h);
    return copyBgra(alloc, px, @intCast(w), @intCast(h));
}

pub fn decodeJpegLib(alloc: std.mem.Allocator, data: []const u8) !png.Image {
    const a = tj_lib.get() orelse return error.NoJpegLibrary;
    const h_ = a.tjInitDecompress() orelse return error.NoJpegLibrary;
    defer _ = a.tjDestroy(h_);
    var w: c_int = 0;
    var h: c_int = 0;
    var sub: c_int = 0;
    var cs: c_int = 0;
    if (a.tjDecompressHeader3(h_, data.ptr, std.math.cast(c_ulong, data.len) orelse return error.TooBig, &w, &h, &sub, &cs) != 0) return error.Corrupt;
    try checkSize(w, h);
    const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    const out = try alloc.alloc(u32, n);
    errdefer alloc.free(out);
    const bytes: [*]u8 = @ptrCast(out.ptr);
    if (a.tjDecompress2(h_, data.ptr, @intCast(data.len), bytes, w, w * 4, h, tjpf_bgra, 0) != 0) return error.Corrupt;
    for (out) |*p| p.* |= 0xFF000000;
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = out };
}

fn copyBgra(alloc: std.mem.Allocator, px: [*]const u8, w: u32, h: u32) !png.Image {
    const n = @as(usize, w) * h;
    const out = try alloc.alloc(u32, n);
    for (out, 0..) |*p, i| p.* = std.mem.readInt(u32, px[i * 4 ..][0..4], .little);
    return .{ .width = w, .height = h, .pixels = out };
}

test "webp files are recognised by their header" {
    try std.testing.expect(isWebp("RIFF\x10\x00\x00\x00WEBPVP8 "));
    try std.testing.expect(!isWebp("RIFF\x10\x00\x00\x00WAVEfmt "));
    try std.testing.expect(!isWebp("RIFF"));
}

test "webp through libwebp, when installed" {
    const alloc = std.testing.allocator;
    var img = decodeWebp(alloc, @embedFile("testdata/small.webp")) catch |err| switch (err) {
        error.NoWebpLibrary => return error.SkipZigTest,
        else => return err,
    };
    defer img.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 37), img.width);
    try std.testing.expectEqual(@as(u32, 29), img.height);
    try std.testing.expectEqual(@as(u32, 0xFF), img.pixels[0] >> 24);
}
