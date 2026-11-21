//! Spotlight: a rectangle or ellipse that stays as it is while
//! everything around it is dimmed. Exported like any annotation.
//!
//! Shape fields it uses: the frame (p0, p1), `filled` (an ellipse rather
//! than a rectangle) and `number`, how much the rest is dimmed in percent.

const std = @import("std");
const shapes = @import("../shapes.zig");
const render = @import("../../gfx/render.zig");

const Shape = shapes.Shape;
const Rect = shapes.Rect;
const Point = shapes.Point;
const Canvas = render.Canvas;

/// Dimming levels offered in the popover, percent.
pub const levels = [3]u8{ 35, 55, 75 };
pub const default_dim: u8 = levels[1];

/// Everything: the dimming reaches the whole image.
pub fn bounds() Rect {
    const big: i32 = 1 << 24;
    return .{ .x = -big, .y = -big, .w = 2 * big, .h = 2 * big };
}

/// On the spotlight's edge, within `tol` (its inside is the picture,
/// left to the shapes under it).
pub fn hitTest(s: *const Shape, p: Point, tol: f64) bool {
    const f = s.frame();
    const t: i32 = @as(i32, @intFromFloat(@ceil(tol))) + 3;
    if (!f.expand(t).contains(p.x, p.y)) return false;
    const inner = f.expand(-t);
    return inner.isEmpty() or !inner.contains(p.x, p.y);
}

fn dimAlpha(s: *const Shape) u32 {
    const pct: u32 = if (s.number == 0) default_dim else @min(95, s.number);
    return (pct * 255 + 50) / 100;
}

/// How much of canvas pixel (x, y) is inside the spotlight, 0..1.
fn coverage(s: *const Shape, r: Rect, x: i32, y: i32) f64 {
    if (!s.filled) {
        return if (r.contains(x, y)) 1 else 0;
    }
    const rx = @max(0.5, @as(f64, @floatFromInt(r.w)) / 2.0);
    const ry = @max(0.5, @as(f64, @floatFromInt(r.h)) / 2.0);
    const dx = @as(f64, @floatFromInt(x)) + 0.5 - (@as(f64, @floatFromInt(r.x)) + rx);
    const dy = @as(f64, @floatFromInt(y)) + 0.5 - (@as(f64, @floatFromInt(r.y)) + ry);
    const f = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) - 1.0;
    const g = @max(1e-9, @sqrt(4.0 * dx * dx / (rx * rx * rx * rx) + 4.0 * dy * dy / (ry * ry * ry * ry)));
    return std.math.clamp(0.5 - f / g, 0.0, 1.0);
}

pub fn draw(canvas: *Canvas, s: *const Shape, xf: shapes.Xform) void {
    const r = xf.rect(s.frame());
    const a = dimAlpha(s);
    const cw: usize = @intCast(canvas.w);
    var y: i32 = 0;
    while (y < canvas.h) : (y += 1) {
        const row = canvas.px[@as(usize, @intCast(y)) * cw ..][0..cw];
        const in_rows = y >= r.y - 1 and y <= r.bottom();
        var x: i32 = 0;
        while (x < canvas.w) : (x += 1) {
            const cov = if (in_rows and x >= r.x - 1 and x <= r.right()) coverage(s, r, x, y) else 0;
            if (cov >= 1) continue;
            const k: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(a)) * (1 - cov)));
            row[@intCast(x)] = darken(row[@intCast(x)], k);
        }
    }
}

fn darken(p: u32, k: u32) u32 {
    const keep = 256 - k;
    const rb = ((p & 0x00FF00FF) * keep >> 8) & 0x00FF00FF;
    const g = ((p & 0x0000FF00) * keep >> 8) & 0x0000FF00;
    return (p & 0xFF000000) | rb | g;
}

test "everything outside is dimmed, the inside stays" {
    var px: [20 * 20]u32 = @splat(0xFFFFFFFF);
    var c = Canvas.init(&px, 20, 20);
    const s = Shape{ .tool = .spotlight, .color = 0, .thickness = 1, .p0 = .{ .x = 5, .y = 5 }, .p1 = .{ .x = 15, .y = 15 }, .number = 50 };
    draw(&c, &s, .{});
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 20 + 10]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[5 * 20 + 5]);
    const out = px[0] & 0xFF;
    try std.testing.expect(out > 110 and out < 140);
    try std.testing.expectEqual(px[0], px[19 * 20 + 19]);
}

test "an ellipse spotlight dims its corners" {
    var px: [20 * 20]u32 = @splat(0xFFFFFFFF);
    var c = Canvas.init(&px, 20, 20);
    const s = Shape{ .tool = .spotlight, .color = 0, .thickness = 1, .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 20, .y = 20 }, .filled = true };
    draw(&c, &s, .{});
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 20 + 10]);
    try std.testing.expect(px[0] & 0xFF < 200);
}

test "only the edge is hit" {
    const s = Shape{ .tool = .spotlight, .color = 0, .thickness = 1, .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 100, .y = 100 } };
    try std.testing.expect(hitTest(&s, .{ .x = 1, .y = 50 }, 2));
    try std.testing.expect(!hitTest(&s, .{ .x = 50, .y = 50 }, 2));
    try std.testing.expect(!hitTest(&s, .{ .x = 150, .y = 50 }, 2));
}
