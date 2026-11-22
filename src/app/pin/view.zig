//! How a pin shows its picture: the zoom (scroll, - = 0) and the opacity
//! (the menu, or 1-4).

const std = @import("std");

pub const zoom_min = 0.1;
pub const zoom_max = 8.0;

/// Next zoom level for `steps` wheel notches (positive = zoom out).
pub fn zoomStep(z: f64, steps: i32) f64 {
    const nz = z * std.math.pow(f64, 1.1, @floatFromInt(-steps));
    // snap to 100% when crossing it
    if ((z < 1 and nz > 1) or (z > 1 and nz < 1)) return 1;
    return std.math.clamp(nz, zoom_min, zoom_max);
}

/// The picture's size on screen: `n` image pixels at `zoom`.
pub fn zoomedSize(n: u32, zoom: f64) u32 {
    return @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * zoom))));
}

/// The opacities a pin offers, in the menu's order (keys 1 to 4).
pub const Opacity = enum(u2) {
    full,
    three_quarters,
    half,
    quarter,

    pub const all = [_]Opacity{ .full, .three_quarters, .half, .quarter };

    pub fn alpha(o: Opacity) f64 {
        return switch (o) {
            .full => 1,
            .three_quarters => 0.75,
            .half => 0.5,
            .quarter => 0.25,
        };
    }

    pub fn label(o: Opacity) []const u8 {
        return switch (o) {
            .full => "100%",
            .three_quarters => "75%",
            .half => "50%",
            .quarter => "25%",
        };
    }

    /// The opacity digit `d` ('1'..'4') picks.
    pub fn fromDigit(d: u8) ?Opacity {
        if (d < '1' or d > '4') return null;
        return @fromBackingInt(@intCast(d - '1'));
    }
};

test "zoom steps snap to 100% and stay in range" {
    try std.testing.expectEqual(@as(f64, 1), zoomStep(0.95, -1));
    try std.testing.expectEqual(@as(f64, 1), zoomStep(1.05, 1));
    try std.testing.expect(zoomStep(1, -1) > 1.09);
    try std.testing.expectEqual(@as(f64, zoom_max), zoomStep(7.9, -10));
    try std.testing.expectEqual(@as(f64, zoom_min), zoomStep(0.11, 10));
}

test "opacity keys go from opaque to a quarter" {
    try std.testing.expectEqual(Opacity.full, Opacity.fromDigit('1').?);
    try std.testing.expectEqual(Opacity.quarter, Opacity.fromDigit('4').?);
    try std.testing.expect(Opacity.fromDigit('5') == null and Opacity.fromDigit('0') == null);
    try std.testing.expectEqual(@as(f64, 0.5), Opacity.half.alpha());
}
