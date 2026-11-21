//! JPEG decoder tests against libjpeg's output (testdata/*.rgb, written
//! by ImageMagick), and a fuzz run over damaged files.

const std = @import("std");
const jpeg = @import("jpeg.zig");

const Case = struct { jpg: []const u8, rgb: []const u8, max_err: u32, mean_err: f64 };

const cases = [_]Case{
    // libjpeg upsamples chroma smoothly, we take the nearest sample:
    // differences at colour edges, the same elsewhere
    .{ .jpg = @embedFile("testdata/rgb420.jpg"), .rgb = @embedFile("testdata/rgb420.rgb"), .max_err = 60, .mean_err = 3.0 },
    .{ .jpg = @embedFile("testdata/rgb444.jpg"), .rgb = @embedFile("testdata/rgb444.rgb"), .max_err = 3, .mean_err = 0.6 },
    .{ .jpg = @embedFile("testdata/gray.jpg"), .rgb = @embedFile("testdata/gray.rgb"), .max_err = 2, .mean_err = 0.5 },
    .{ .jpg = @embedFile("testdata/restart.jpg"), .rgb = @embedFile("testdata/restart.rgb"), .max_err = 60, .mean_err = 3.0 },
};

test "baseline files decode like libjpeg" {
    const alloc = std.testing.allocator;
    for (cases) |c| {
        var img = try jpeg.decode(alloc, c.jpg);
        defer img.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 37), img.width);
        try std.testing.expectEqual(@as(u32, 29), img.height);
        try std.testing.expectEqual(c.rgb.len, img.pixels.len * 3);
        var max: u32 = 0;
        var sum: u64 = 0;
        for (img.pixels, 0..) |p, i| {
            inline for (.{ 16, 8, 0 }, 0..) |sh, k| {
                const a: i32 = @intCast((p >> sh) & 0xFF);
                const b: i32 = c.rgb[i * 3 + k];
                const e: u32 = @abs(a - b);
                max = @max(max, e);
                sum += e;
            }
            try std.testing.expectEqual(@as(u32, 0xFF), p >> 24);
        }
        const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(c.rgb.len));
        if (max > c.max_err or mean > c.mean_err) {
            std.debug.print("jpeg: max error {d}, mean {d:.2}\n", .{ max, mean });
            return error.TestUnexpectedResult;
        }
    }
}

test "progressive files and non-JPEG data are refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.Unsupported, jpeg.decode(alloc, @embedFile("testdata/progressive.jpg")));
    try std.testing.expectError(error.NotJpeg, jpeg.decode(alloc, "\x89PNG\r\n\x1a\n"));
    try std.testing.expectError(error.NotJpeg, jpeg.decode(alloc, ""));
    try std.testing.expectError(error.Truncated, jpeg.decode(alloc, "\xFF\xD8\xFF"));
}

/// Decode `data`; any outcome but a crash or a leak is fine.
fn tryDecode(alloc: std.mem.Allocator, data: []const u8) void {
    var img = jpeg.decode(alloc, data) catch return;
    img.deinit(alloc);
}

test "damaged files fail cleanly (fuzz)" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5107_1e7);
    const rnd = prng.random();
    var buf: [4096]u8 = undefined;
    for (cases) |c| {
        for (0..400) |_| {
            const n = c.jpg.len;
            @memcpy(buf[0..n], c.jpg);
            // flip a few bytes, sometimes cut the file short
            for (0..rnd.intRangeAtMost(usize, 1, 8)) |_| buf[rnd.uintLessThan(usize, n)] = rnd.int(u8);
            const len = if (rnd.boolean()) n else rnd.uintLessThan(usize, n);
            tryDecode(alloc, buf[0..len]);
        }
        // every prefix
        var len: usize = 0;
        while (len < c.jpg.len) : (len += 7) tryDecode(alloc, c.jpg[0..len]);
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    const n = smith.sliceWithHash(&buf, 0x5107);
    tryDecode(std.testing.allocator, buf[0..n]);
}

test "fuzz entry point (zig build test --fuzz)" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{ cases[0].jpg, cases[2].jpg, cases[3].jpg } });
}
