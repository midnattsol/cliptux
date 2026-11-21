//! The numeric settings' steps (Settings window): seconds, captures, MiB.

const std = @import("std");

pub fn stepSeconds(v: u16, up: bool) u16 {
    const steps = [_]u16{ 3, 5, 8, 10, 15, 20, 30, 45, 60, 120, 300 };
    return stepIn(u16, &steps, v, up);
}
pub fn stepCount(v: u16, up: bool) u16 {
    const steps = [_]u16{ 5, 10, 20, 30, 50, 100, 200, 500, 1000 };
    return stepIn(u16, &steps, v, up);
}
pub fn stepMb(v: u32, up: bool) u32 {
    const steps = [_]u32{ 50, 100, 200, 500, 1000, 2000, 5000 };
    return stepIn(u32, &steps, v, up);
}

/// The next value of `steps` above (or below) v; off-list values snap in.
fn stepIn(comptime T: type, steps: []const T, v: T, up: bool) T {
    if (up) {
        for (steps) |x| if (x > v) return x;
        return steps[steps.len - 1];
    }
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        if (steps[i] < v) return steps[i];
    }
    return steps[0];
}

test "numeric settings step along their scales" {
    try std.testing.expectEqual(@as(u16, 10), stepSeconds(8, true));
    try std.testing.expectEqual(@as(u16, 5), stepSeconds(8, false));
    try std.testing.expectEqual(@as(u16, 3), stepSeconds(3, false));
    try std.testing.expectEqual(@as(u16, 300), stepSeconds(300, true));
    try std.testing.expectEqual(@as(u16, 50), stepCount(42, true));
    try std.testing.expectEqual(@as(u16, 30), stepCount(42, false));
    try std.testing.expectEqual(@as(u32, 1000), stepMb(500, true));
}
