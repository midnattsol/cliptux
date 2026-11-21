//! Raster helpers shared by shapes and chrome: rounded-rect rings, filled
//! ellipses, aligned pixelation and a contrasting label colour.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const Rect = @import("geometry.zig").Rect;

const Canvas = render.Canvas;

/// Anti-aliased rounded rectangle outline drawn inside `r`; touches only
/// the border band, so big rectangles stay cheap.
pub fn roundRectRing(canvas: *Canvas, r: Rect, radius: f64, width: f64, color: u32) void {
    if (r.w <= 0 or r.h <= 0) return;
    const fx0: f64 = @floatFromInt(r.x);
    const fy0: f64 = @floatFromInt(r.y);
    const fx1: f64 = @floatFromInt(r.right());
    const fy1: f64 = @floatFromInt(r.bottom());
    const ro = @min(radius, @min(@as(f64, @floatFromInt(r.w)), @as(f64, @floatFromInt(r.h))) / 2.0);
    const ri = @max(0.0, ro - width);
    const band: i32 = @as(i32, @intFromFloat(@ceil(@max(ro, width)))) + 2;
    var y: i32 = @max(r.y - 1, 0);
    const y_end = @min(r.bottom() + 1, canvas.h);
    while (y < y_end) : (y += 1) {
        const near_edge = y < r.y + band or y >= r.bottom() - band;
        var x: i32 = @max(r.x - 1, 0);
        const x_end = @min(r.right() + 1, canvas.w);
        while (x < x_end) : (x += 1) {
            if (!near_edge and x >= r.x + band and x < r.right() - band) {
                x = r.right() - band - 1;
                continue;
            }
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const d_o = rrDist(px, py, fx0, fy0, fx1, fy1, ro);
            const d_i = rrDist(px, py, fx0 + width, fy0 + width, fx1 - width, fy1 - width, ri);
            const cov = std.math.clamp(0.5 - d_o, 0.0, 1.0) - std.math.clamp(0.5 - d_i, 0.0, 1.0);
            canvas.blendCov(x, y, color, cov);
        }
    }
}

fn rrDist(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r: f64) f64 {
    if (x1 <= x0 or y1 <= y0) return 1e9;
    const rr = @min(r, @min(x1 - x0, y1 - y0) / 2.0);
    const qx = @max(x0 + rr - px, px - (x1 - rr));
    const qy = @max(y0 + rr - py, py - (y1 - rr));
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - rr;
}

pub fn fillEllipseAA(canvas: *Canvas, r: Rect, color: u32) void {
    if (r.w < 1 or r.h < 1) return;
    const rx = @as(f64, @floatFromInt(r.w)) / 2.0;
    const ry = @as(f64, @floatFromInt(r.h)) / 2.0;
    const cx = @as(f64, @floatFromInt(r.x)) + rx;
    const cy = @as(f64, @floatFromInt(r.y)) + ry;
    var y: i32 = @max(r.y - 1, 0);
    while (y < @min(r.bottom() + 1, canvas.h)) : (y += 1) {
        var x: i32 = @max(r.x - 1, 0);
        while (x < @min(r.right() + 1, canvas.w)) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const f = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) - 1.0;
            const gx = 2.0 * dx / (rx * rx);
            const gy = 2.0 * dy / (ry * ry);
            const g = @max(1e-9, @sqrt(gx * gx + gy * gy));
            canvas.blendCov(x, y, color, std.math.clamp(0.5 - f / g, 0.0, 1.0));
        }
    }
}

/// Mosaic `r` with `blk`-sized cells aligned to the rectangle's own
/// corner, so a clipped redraw produces the same cells as a full one.
pub fn pixelateAligned(canvas: *Canvas, r: Rect, blk: i32) void {
    const clip = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    var by = r.y + @divFloor(clip.y - r.y, blk) * blk;
    while (by < clip.bottom()) : (by += blk) {
        var bx = r.x + @divFloor(clip.x - r.x, blk) * blk;
        while (bx < clip.right()) : (bx += blk) {
            const cell = Rect.intersect(.{ .x = bx, .y = by, .w = blk, .h = blk }, clip) orelse continue;
            var acc: [3]u64 = .{ 0, 0, 0 };
            var y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                for (canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)]) |p| {
                    acc[0] += (p >> 16) & 0xFF;
                    acc[1] += (p >> 8) & 0xFF;
                    acc[2] += p & 0xFF;
                }
            }
            const n: u64 = @intCast(cell.w * cell.h);
            const avg: u32 = 0xFF000000 | @as(u32, @intCast(acc[0] / n)) << 16 | @as(u32, @intCast(acc[1] / n)) << 8 | @as(u32, @intCast(acc[2] / n));
            y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                @memset(canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)], avg);
            }
        }
    }
}

pub fn contrastColor(c: u32) u32 {
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    const lum = (r * 299 + g * 587 + b * 114) / 1000;
    return if (lum > 140) 0xFF1A1A1A else 0xFFFFFFFF;
}

test "pixelate cells stay aligned when clipped" {
    // a full render and a render through an offset canvas give the same cells
    var full: [32 * 8]u32 = undefined;
    for (&full, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast((i * 2654435761) % 0xFFFFFF));
    var part: [16 * 8]u32 = undefined;
    for (0..8) |y| @memcpy(part[y * 16 ..][0..16], full[y * 32 + 16 ..][0..16]);
    var cf = Canvas.init(&full, 32, 8);
    pixelateAligned(&cf, .{ .x = 2, .y = 0, .w = 28, .h = 8 }, 4);
    var cp = Canvas.init(&part, 16, 8);
    pixelateAligned(&cp, .{ .x = 2 - 16, .y = 0, .w = 28, .h = 8 }, 4);
    // cells fully inside the partial canvas match
    for (0..8) |y| {
        for (2..14) |x| try std.testing.expectEqual(full[y * 32 + 16 + x], part[y * 16 + x]);
    }
}
