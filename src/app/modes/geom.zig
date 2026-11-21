//! Where things are: the compositor's logical layout (what the GNOME
//! extension, KWin and sway report: window frames, the pointer) against
//! the capture's image pixels (capture.Monitor: each monitor's pixel
//! rectangle in the stitched image, at its own scale).

const std = @import("std");
const capture = @import("../capture.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }

    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn array(self: Rect) [4]i32 {
        return .{ self.x, self.y, self.w, self.h };
    }
};

fn logicalOf(m: capture.Monitor) ?Rect {
    const l = m.logical orelse return null;
    return .{ .x = l.x, .y = l.y, .w = @intCast(l.w), .h = @intCast(l.h) };
}

pub fn pixelRect(m: capture.Monitor) Rect {
    return .{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) };
}

/// The monitor holding the logical point; with an unknown layout, the
/// first monitor.
pub fn monitorAt(mons: []const capture.Monitor, p: ?[2]i32) usize {
    const pt = p orelse return 0;
    for (mons, 0..) |m, i| if (logicalOf(m)) |l| if (l.contains(pt[0], pt[1])) return i;
    return 0;
}

fn scaleOf(m: capture.Monitor, l: Rect) f64 {
    return @as(f64, @floatFromInt(m.w)) / @as(f64, @floatFromInt(@max(1, l.w)));
}

fn round(v: f64) i32 {
    return @intFromFloat(@round(v));
}

/// A logical rectangle (a window's frame) in image pixels, through the
/// monitor holding its centre, clipped to that monitor.
pub fn logicalToImage(mons: []const capture.Monitor, r: Rect) ?Rect {
    const c = [2]i32{ r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2) };
    for (mons) |m| {
        const l = logicalOf(m) orelse continue;
        if (!l.contains(c[0], c[1])) continue;
        const s = scaleOf(m, l);
        const x0 = round(@as(f64, @floatFromInt(r.x - l.x)) * s);
        const y0 = round(@as(f64, @floatFromInt(r.y - l.y)) * s);
        const x1 = round(@as(f64, @floatFromInt(r.x + r.w - l.x)) * s);
        const y1 = round(@as(f64, @floatFromInt(r.y + r.h - l.y)) * s);
        const px: Rect = .{ .x = @as(i32, @intCast(m.x)) + x0, .y = @as(i32, @intCast(m.y)) + y0, .w = x1 - x0, .h = y1 - y0 };
        return Rect.intersect(px, pixelRect(m));
    }
    return null;
}

/// An image rectangle (a selection) in logical coordinates, through the
/// monitor holding its centre, and that monitor's scale.
pub fn imageToLogical(mons: []const capture.Monitor, r: Rect) ?struct { rect: Rect, scale: f64 } {
    const c = [2]i32{ r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2) };
    for (mons) |m| {
        const l = logicalOf(m) orelse continue;
        const px = pixelRect(m);
        if (!px.contains(c[0], c[1])) continue;
        const clipped = Rect.intersect(r, px) orelse return null;
        const s = scaleOf(m, l);
        const x0 = round(@as(f64, @floatFromInt(clipped.x - px.x)) / s);
        const y0 = round(@as(f64, @floatFromInt(clipped.y - px.y)) / s);
        const x1 = round(@as(f64, @floatFromInt(clipped.x + clipped.w - px.x)) / s);
        const y1 = round(@as(f64, @floatFromInt(clipped.y + clipped.h - px.y)) / s);
        return .{ .rect = .{ .x = l.x + x0, .y = l.y + y0, .w = x1 - x0, .h = y1 - y0 }, .scale = s };
    }
    return null;
}

const testing = std.testing;

// 1280x720 logical at 2 (2560x1440 px) left of 1280x720 at 1
const mixed = [_]capture.Monitor{
    .{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 } },
    .{ .x = 2560, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 } },
};

test "window frames map to image pixels at each monitor's scale" {
    // on the 2x monitor
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 800, .h = 600 }, logicalToImage(&mixed, .{ .x = 100, .y = 50, .w = 400, .h = 300 }).?);
    // on the 1x monitor, upscaled to the capture's 2x
    try testing.expectEqual(Rect{ .x = 2760, .y = 100, .w = 800, .h = 600 }, logicalToImage(&mixed, .{ .x = 1380, .y = 50, .w = 400, .h = 300 }).?);
    // hanging off the left edge: clipped to the monitor
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, logicalToImage(&mixed, .{ .x = -50, .y = -10, .w = 100, .h = 60 }).?);
    try testing.expectEqual(@as(?Rect, null), logicalToImage(&mixed, .{ .x = 5000, .y = 0, .w = 10, .h = 10 }));
}

test "fractional scale rounds to whole pixels" {
    const frac = [_]capture.Monitor{.{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1707, .h = 960 } }};
    const r = logicalToImage(&frac, .{ .x = 10, .y = 10, .w = 300, .h = 200 }).?;
    try testing.expectEqual(@as(i32, 15), r.x);
    try testing.expectEqual(@as(i32, 450), r.w);
    const back = imageToLogical(&frac, r).?;
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 300, .h = 200 }, back.rect);
    try testing.expectApproxEqAbs(@as(f64, 1.4997), back.scale, 1e-3);
}

test "selections map back to logical coordinates" {
    const l = imageToLogical(&mixed, .{ .x = 2760, .y = 100, .w = 800, .h = 600 }).?;
    try testing.expectEqual(Rect{ .x = 1380, .y = 50, .w = 400, .h = 300 }, l.rect);
    try testing.expectEqual(@as(f64, 2), l.scale);
    try testing.expectEqual(@as(usize, 1), monitorAt(&mixed, .{ 1300, 10 }));
    try testing.expectEqual(@as(usize, 0), monitorAt(&mixed, null));
}
