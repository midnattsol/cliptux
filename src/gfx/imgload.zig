//! Open an image file of any kind Shotlet reads: PNG and baseline JPEG
//! with its own decoders, progressive JPEG and WebP through libturbojpeg
//! and libwebp when installed. The format comes from the content, not the
//! name.

const std = @import("std");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const libs = @import("codec_libs.zig");
const sys = @import("../platform/linux/sys.zig");

pub const max_file = 256 * 1024 * 1024;

pub const Format = enum { png, jpeg, webp, unknown };

pub fn sniff(data: []const u8) Format {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (jpeg.isJpeg(data)) return .jpeg;
    if (libs.isWebp(data)) return .webp;
    return .unknown;
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !png.Image {
    return switch (sniff(data)) {
        .png => png.decode(alloc, data),
        .jpeg => jpeg.decode(alloc, data) catch |err| switch (err) {
            // progressive, CMYK...: libjpeg-turbo knows them
            error.Unsupported => libs.decodeJpegLib(alloc, data),
            else => err,
        },
        .webp => libs.decodeWebp(alloc, data),
        .unknown => error.UnknownImageFormat,
    };
}

pub fn loadFile(alloc: std.mem.Allocator, path: []const u8) !png.Image {
    const data = try sys.readFileAlloc(alloc, path, max_file);
    defer alloc.free(data);
    return decode(alloc, data);
}

/// The first local file of a text/uri-list ("file:///a%20b.png\r\n..."),
/// percent-decoded into `buf`.
pub fn firstFileUri(buf: []u8, list: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, list, "\r\n");
    while (it.next()) |line| {
        if (line[0] == '#') continue;
        const rest = if (std.mem.startsWith(u8, line, "file://")) line[7..] else continue;
        // file://host/path: only the local host
        const path = if (rest.len > 0 and rest[0] == '/') rest else if (std.mem.startsWith(u8, rest, "localhost/")) rest[9..] else continue;
        return percentDecode(buf, path);
    }
    return null;
}

fn percentDecode(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n >= buf.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[n] = s[i];
            i += 1;
        }
    }
    if (std.mem.indexOfScalar(u8, buf[0..n], 0) != null) return null;
    return buf[0..n];
}

test "formats by content" {
    try std.testing.expectEqual(Format.png, sniff("\x89PNG\r\n\x1a\n...."));
    try std.testing.expectEqual(Format.jpeg, sniff("\xFF\xD8\xFF\xE0"));
    try std.testing.expectEqual(Format.webp, sniff("RIFF\x00\x00\x00\x00WEBPVP8L"));
    try std.testing.expectEqual(Format.unknown, sniff("GIF89a"));
    try std.testing.expectError(error.UnknownImageFormat, decode(std.testing.allocator, "hello"));
    var img = try decode(std.testing.allocator, @embedFile("testdata/rgb444.jpg"));
    img.deinit(std.testing.allocator);
}

test "uri lists give a local path" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/a b.png", firstFileUri(&buf, "# comment\r\nfile:///home/u/a%20b.png\r\nfile:///x.png\r\n").?);
    try std.testing.expectEqualStrings("/tmp/x.png", firstFileUri(&buf, "file://localhost/tmp/x.png").?);
    try std.testing.expect(firstFileUri(&buf, "https://example.com/x.png\n") == null);
    try std.testing.expect(firstFileUri(&buf, "file://otherhost/x.png") == null);
    try std.testing.expect(firstFileUri(&buf, "file:///a%00b") == null);
    try std.testing.expect(firstFileUri(&buf, "file:///bad%zz") == null);
}
