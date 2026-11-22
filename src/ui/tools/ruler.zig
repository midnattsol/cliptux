//! The ruler: a measurement annotation from p0 to p1 with end ticks and a
//! label giving the length and the width × height it spans, in image
//! pixels (and logical pixels when the capture's scale is not 1).
//!
//! Shape fields it uses: p0, p1, colour, thickness (line width) and
//! `number`, the logical scale in thousandths (0 or 1000: no logical size).

const std = @import("std");
const shapes = @import("../shapes.zig");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");

const Shape = shapes.Shape;
const Rect = shapes.Rect;
const Point = shapes.Point;
const Canvas = render.Canvas;

pub const label_bg: u32 = 0xE01C1C1E;
pub const label_fg: u32 = 0xFFF5F5F7;

/// What a ruler measures.
pub const Measure = struct {
    w: u32,
    h: u32,
    len: f64,
    /// image pixels per logical pixel (1: same)
    scale: f64 = 1,

    pub fn of(s: *const Shape) Measure {
        const dx: f64 = @floatFromInt(s.p1.x - s.p0.x);
        const dy: f64 = @floatFromInt(s.p1.y - s.p0.y);
        return .{
            .w = @abs(s.p1.x - s.p0.x),
            .h = @abs(s.p1.y - s.p0.y),
            .len = @sqrt(dx * dx + dy * dy),
            .scale = if (s.number == 0) 1 else @as(f64, @floatFromInt(s.number)) / 1000.0,
        };
    }

    /// "144.2 px · 120 × 80", with " (72.1 pt)" in logical pixels when
    /// the scale is not 1.
    pub fn label(self: Measure, buf: []u8) []const u8 {
        const x = if (text_mod.available()) "\u{00D7}" else "x";
        const dot = if (text_mod.available()) "\u{00B7}" else "-";
        if (@abs(self.scale - 1) < 0.001) {
            return std.fmt.bufPrint(buf, "{d:.1} px  {s}  {d} {s} {d}", .{ self.len, dot, self.w, x, self.h }) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d:.1} px  {s}  {d} {s} {d}  ({d:.1} pt)", .{ self.len, dot, self.w, x, self.h, self.len / self.scale }) catch "?";
    }
};

fn fontPx(s: *const Shape) f64 {
    return 11.0 + @as(f64, @floatFromInt(@max(1, s.thickness))) * 1.5;
}

fn tick(s: *const Shape) f64 {
    return 5.0 + @as(f64, @floatFromInt(@max(1, s.thickness))) * 2.0;
}

/// The label's box in image pixels: centred on the ruler's middle, moved
/// off the line on the side away from it.
pub fn labelRect(s: *const Shape) Rect {
    var buf: [96]u8 = undefined;
    const fs = fontPx(s);
    const tw = text_mod.widthStyled(fs, label_style, Measure.of(s).label(&buf));
    const pad: i32 = @intFromFloat(@round(fs * 0.5));
    const w = tw + 2 * pad;
    const h = text_mod.height(fs) + pad;
    const mx = @divTrunc(s.p0.x + s.p1.x, 2);
    const my = @divTrunc(s.p0.y + s.p1.y, 2);
    // perpendicular offset: below a mostly horizontal ruler, beside a
    // mostly vertical one
    const horiz = @abs(s.p1.x - s.p0.x) >= @abs(s.p1.y - s.p0.y);
    const gap: i32 = @intFromFloat(@round(tick(s)));
    if (horiz) return .{ .x = mx - @divTrunc(w, 2), .y = my + gap, .w = w, .h = h };
    return .{ .x = mx + gap, .y = my - @divTrunc(h, 2), .w = w, .h = h };
}

pub fn bounds(s: *const Shape) Rect {
    const t: i32 = @as(i32, @intFromFloat(@ceil(tick(s)))) + s.thickness + 2;
    return Rect.unite(Rect.fromCorners(s.p0, s.p1).expand(t), labelRect(s).expand(2));
}

pub fn draw(canvas: *Canvas, s: *const Shape, xf: shapes.Xform) void {
    const w = @max(1.0, @as(f64, @floatFromInt(@max(1, s.thickness))) * xf.scale);
    const a = [2]f64{ xf.fx(s.p0.x), xf.fy(s.p0.y) };
    const b = [2]f64{ xf.fx(s.p1.x), xf.fy(s.p1.y) };
    const seg = [_]Point{ xf.pt(s.p0), xf.pt(s.p1) };
    canvas.strokePolylineAA(seg[0..], w, s.color);
    // perpendicular end ticks
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @max(1e-9, @sqrt(dx * dx + dy * dy));
    const half = tick(s) * xf.scale;
    const nx = -dy / len * half;
    const ny = dx / len * half;
    for ([2][2]f64{ a, b }) |p| {
        const t = [_]Point{
            .{ .x = @intFromFloat(@round(p[0] + nx)), .y = @intFromFloat(@round(p[1] + ny)) },
            .{ .x = @intFromFloat(@round(p[0] - nx)), .y = @intFromFloat(@round(p[1] - ny)) },
        };
        canvas.strokePolylineAA(t[0..], w, s.color);
    }
    drawLabel(canvas, s, xf);
}

/// The measurement: figures that do not jiggle while it is dragged.
const label_style = text_mod.Style.regular.num();

fn drawLabel(canvas: *Canvas, s: *const Shape, xf: shapes.Xform) void {
    var buf: [96]u8 = undefined;
    const label = Measure.of(s).label(&buf);
    const r = xf.rect(labelRect(s));
    const fs = fontPx(s) * xf.scale;
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, @as(f64, @floatFromInt(r.h)) / 2.0, label_bg);
    const tx = r.x + @divTrunc(r.w - text_mod.widthStyled(fs, label_style, label), 2);
    const ty = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    text_mod.drawStyled(canvas, tx, ty, fs, label_fg, label_style, label);
}

/// The ruler's end under the pointer: Shift keeps it on the axis it is
/// mostly along; `snap` moves it to the nearest colour edge (Alt: off).
pub fn endPoint(anchor: Point, p: Point, shift: bool) Point {
    if (!shift) return p;
    if (@abs(p.x - anchor.x) >= @abs(p.y - anchor.y)) return .{ .x = p.x, .y = anchor.y };
    return .{ .x = anchor.x, .y = p.y };
}

test "measure and label" {
    var s = Shape{ .tool = .ruler, .color = 0xFFFF0000, .thickness = 2, .p0 = .{ .x = 10, .y = 10 }, .p1 = .{ .x = 130, .y = 100 } };
    const m = Measure.of(&s);
    try std.testing.expectEqual(@as(u32, 120), m.w);
    try std.testing.expectEqual(@as(u32, 90), m.h);
    try std.testing.expectApproxEqAbs(@as(f64, 150), m.len, 1e-9);
    var buf: [96]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, m.label(&buf), "150.0 px"));
    s.number = 2000;
    try std.testing.expect(std.mem.endsWith(u8, Measure.of(&s).label(&buf), "(75.0 pt)"));
}

test "shift keeps the ruler on an axis" {
    const a = Point{ .x = 100, .y = 100 };
    try std.testing.expectEqual(Point{ .x = 180, .y = 100 }, endPoint(a, .{ .x = 180, .y = 120 }, true));
    try std.testing.expectEqual(Point{ .x = 100, .y = 20 }, endPoint(a, .{ .x = 90, .y = 20 }, true));
    try std.testing.expectEqual(Point{ .x = 90, .y = 20 }, endPoint(a, .{ .x = 90, .y = 20 }, false));
}

test "bounds cover the line, ticks and label" {
    const s = Shape{ .tool = .ruler, .color = 0xFFFF0000, .thickness = 2, .p0 = .{ .x = 50, .y = 50 }, .p1 = .{ .x = 250, .y = 50 } };
    const b = bounds(&s);
    const l = labelRect(&s);
    try std.testing.expect(b.x <= 50 and b.right() >= 250);
    try std.testing.expect(b.bottom() >= l.bottom() and l.y > 50);
}
