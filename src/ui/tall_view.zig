//! Very tall images in the editor (a scrolling capture): instead of
//! shrinking them until they fit the screen (a 20 000 px page would be a
//! sliver), they fit the screen's width (never enlarged) and the wheel
//! scrolls them; Ctrl+wheel still sets the size.

const std = @import("std");
const view_mod = @import("view.zig");
const View = view_mod.View;
const Rect = view_mod.Rect;

/// Shrinking to fit below this (and the image taller than wide) scrolls
/// instead.
const min_fit_scale = 0.6;
/// room above and below the image, buffer pixels
const margin = 24;

pub fn isTall(iw: u32, ih: u32, area: Rect) bool {
    if (ih <= iw) return false;
    return View.fit(iw, ih, area, 1.0).scale < min_fit_scale;
}

fn widthScale(iw: u32, area: Rect) f64 {
    const fw: f64 = @floatFromInt(@max(1, area.w - 2 * margin));
    return @min(1.0, fw / @as(f64, @floatFromInt(@max(1, iw))));
}

/// How far the image can scroll, buffer pixels.
pub fn maxScroll(iw: u32, ih: u32, area: Rect) i32 {
    const h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(ih)) * widthScale(iw, area)));
    return @max(0, h + 2 * margin - area.h);
}

pub fn clampScroll(iw: u32, ih: u32, area: Rect, scroll: i32) i32 {
    return std.math.clamp(scroll, 0, maxScroll(iw, ih, area));
}

/// The image at the width-fit scale, `scroll` pixels down.
pub fn view(iw: u32, ih: u32, area: Rect, scroll: i32) View {
    const s = widthScale(iw, area);
    const dw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(iw)) * s));
    return .{
        .scale = s,
        .off_x = area.x + @divTrunc(area.w - dw, 2),
        .off_y = area.y + margin - clampScroll(iw, ih, area, scroll),
    };
}

test "tall pages scroll at a readable scale" {
    const screen: Rect = .{ .x = 0, .y = 0, .w = 1600, .h = 900 };
    try std.testing.expect(isTall(800, 6000, screen));
    try std.testing.expect(!isTall(1600, 900, screen));
    try std.testing.expect(!isTall(600, 1200, screen)); // fits at 0.73
    const v = view(800, 6000, screen, 0);
    try std.testing.expectEqual(@as(f64, 1), v.scale);
    try std.testing.expectEqual(@as(i32, 400), v.off_x);
    try std.testing.expectEqual(@as(i32, 24), v.off_y);
    // scrolled to the end: the image's bottom shows above the margin
    const end = view(800, 6000, screen, 1 << 30);
    try std.testing.expectEqual(@as(i32, 900 - 24 - 6000), end.off_y);
    // wider than the screen: shrunk to its width
    try std.testing.expectApproxEqAbs(@as(f64, 1552.0 / 3000.0), view(3000, 40000, screen, 0).scale, 1e-9);
}
