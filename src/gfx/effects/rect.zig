//! The rectangle type of the effects and its clipping to a buffer.

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// A buffer dimension as i32, saturating.
pub fn dim(v: u32) i32 {
    return @intCast(@min(v, std.math.maxInt(i32)));
}

/// Clip `r` to a `w`×`h` buffer; null when nothing is left.
pub fn clip(r: Rect, w: u32, h: u32) ?Rect {
    if (r.w <= 0 or r.h <= 0) return null;
    const x0 = @max(r.x, 0);
    const y0 = @max(r.y, 0);
    const x1 = @min(r.x +| r.w, dim(w));
    const y1 = @min(r.y +| r.h, dim(h));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}
