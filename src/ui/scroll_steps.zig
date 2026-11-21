//! Mouse wheel and touchpad scrolling into size steps.

const std = @import("std");

/// Thickness steps for a scroll of `value` surface units: one per wheel
/// notch (15 units; v120 wheels report 120 per notch as 15). Touchpads
/// send many small values, which accumulate in `acc` instead of each
/// stepping. Scrolling up (negative) makes strokes thicker.
pub fn scrollSteps(acc: *f64, value: f64) i32 {
    const notch = 15.0;
    if (value == 0) return 0;
    if ((value > 0) != (acc.* > 0) and acc.* != 0) acc.* = 0;
    acc.* += value;
    var steps: i32 = 0;
    while (acc.* >= notch) : (acc.* -= notch) steps -= 1;
    while (acc.* <= -notch) : (acc.* += notch) steps += 1;
    return steps;
}

test "scroll accumulates touchpad deltas and steps once per notch" {
    var acc: f64 = 0;
    try std.testing.expectEqual(@as(i32, -1), scrollSteps(&acc, 15));
    try std.testing.expectEqual(@as(i32, 2), scrollSteps(&acc, -30));
    var small: i32 = 0;
    for (0..30) |_| small += scrollSteps(&acc, 1.0);
    try std.testing.expectEqual(@as(i32, -2), small);
    // a direction change drops the leftover
    _ = scrollSteps(&acc, 14);
    try std.testing.expectEqual(@as(i32, 0), scrollSteps(&acc, -14));
    try std.testing.expectEqual(@as(i32, 1), scrollSteps(&acc, -1));
}
