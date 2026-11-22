//! Image effects used by redaction and the "beautify" frame. Pixels are
//! 0xAARRGGBB, row-major, `w` pixels per row. Every function clips the
//! rectangle to the buffer, so callers may pass rectangles partly (or
//! entirely) outside, with any coordinates.
//!
//! Facade over effects/{rect, blur, composite}.zig.

const std = @import("std");
const rect = @import("effects/rect.zig");
const blur_ = @import("effects/blur.zig");
const composite = @import("effects/composite.zig");

pub const Rect = rect.Rect;
pub const clip = rect.clip;
pub const blur = blur_.blur;
pub const softBlur = blur_.softBlur;
pub const redact = composite.redact;
pub const gradient = composite.gradient;
pub const dropShadow = composite.dropShadow;
pub const blitRounded = composite.blitRounded;
pub const mixRows = composite.mixRows;
pub const over = composite.over;

const boxBlur = blur_.boxBlur;

// keep the moved tests reachable from the test root
comptime {
    _ = @import("effects/reference_test.zig");
}

test "effects clip to the buffer and leave the outside alone" {
    const alloc = std.testing.allocator;
    var px: [16]u32 = @splat(0xFF000000);
    px[5] = 0xFFFFFFFF;
    redact(&px, 4, 4, .{ .x = -2, .y = -2, .w = 3, .h = 3 }, 0x123456);
    try std.testing.expectEqual(@as(u32, 0xFF123456), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[2]);
    try blur(alloc, &px, 4, 4, .{ .x = 2, .y = 2, .w = 10, .h = 10 }, 2);
    try std.testing.expectEqual(@as(u32, 0xFF123456), px[0]);
    gradient(&px, 4, 4, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, 0xFF000000, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[15]);
    dropShadow(&px, 4, 4, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, 1, 0, 0x80000000);
    const src: [4]u32 = @splat(0xFFABCDEF);
    blitRounded(&px, 4, 4, &src, 2, 2, 3, 3, 0);
    try std.testing.expectEqual(@as(u32, 0xFFABCDEF), px[15]);
}

test "blur hides detail and noise stays faint" {
    const alloc = std.testing.allocator;
    const W = 120;
    const H = 40;
    var px: [W * H]u32 = undefined;
    // "text": one-pixel black strokes on white
    for (&px, 0..) |*p, i| p.* = if ((i % W) % 4 == 0) 0xFF000000 else 0xFFFFFFFF;
    var plain = px;
    const area: Rect = .{ .x = 0, .y = 0, .w = W, .h = H };
    try blur(alloc, &px, W, H, area, 12);
    try boxBlur(alloc, &plain, W, H, clip(area, W, H).?, 12);
    var lo: u32 = 255;
    var hi: u32 = 0;
    for (px, plain, 0..) |p, q, i| {
        const x = i % W;
        const inside = x >= 40 and x < 80;
        if (inside) {
            lo = @min(lo, (p >> 8) & 0xFF);
            hi = @max(hi, (p >> 8) & 0xFF);
        }
        const d = @as(i32, @intCast(p & 0xFF)) - @as(i32, @intCast(q & 0xFF));
        try std.testing.expect(@abs(d) <= 3);
    }
    // stroke contrast (255 originally) is gone
    std.testing.expect(hi - lo <= 12) catch |e| {
        std.debug.print("lo={d} hi={d}\n", .{ lo, hi });
        return e;
    };
    // extreme inputs: nothing to do or clipped, never a crash
    try blur(alloc, &px, W, H, .{ .x = std.math.maxInt(i32), .y = 0, .w = std.math.maxInt(i32), .h = 5 }, 5);
    try blur(alloc, &px, W, H, .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) }, std.math.maxInt(u32));
    gradient(&px, W, H, .{ .x = std.math.minInt(i32), .y = 0, .w = std.math.maxInt(i32), .h = std.math.maxInt(i32) }, 0, 0xFFFFFFFF);
    dropShadow(&px, W, H, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32), .w = std.math.maxInt(i32), .h = 3 }, std.math.maxInt(u32), std.math.minInt(i32), 0xFF000000);
    dropShadow(&px, W, H, .{ .x = 3, .y = 3, .w = 9, .h = 9 }, std.math.maxInt(u32), std.math.maxInt(i32), 0xFF000000);
    const src: [4]u32 = @splat(0xFFABCDEF);
    blitRounded(&px, W, H, &src, 2, 2, std.math.maxInt(i32), -1, std.math.maxInt(u32));
    blitRounded(&px, W, H, &src, 2, 2, -1, -1, std.math.maxInt(u32));
}
