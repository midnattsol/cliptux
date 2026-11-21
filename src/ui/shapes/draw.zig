//! The shape painter: draws one shape through an `Xform` (image ->
//! canvas), so the same code renders the native-resolution export layer
//! and the scaled on-screen preview.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const geometry = @import("geometry.zig");
const model = @import("model.zig");
const raster = @import("raster.zig");
const draw_text = @import("draw_text.zig");
const ruler = @import("../tools/ruler.zig");
const spotlight = @import("../tools/spotlight.zig");

const Canvas = render.Canvas;
const Point = geometry.Point;
const Xform = geometry.Xform;
const Shape = model.Shape;
const TextCursor = draw_text.TextCursor;

/// Paint `s` through `xf`. `alloc` is scratch for transformed polylines
/// and blur; `cursor` marks the caret and selection of a text shape being
/// edited.
pub fn drawShape(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform, cursor: ?TextCursor) void {
    const tf = @max(1.0, s.th() * xf.scale);
    switch (s.tool) {
        .pen, .highlight => drawStroke(canvas, alloc, s, xf, tf),
        .line => {
            const seg = [_]Point{ xf.pt(s.p0), xf.pt(s.p1) };
            canvas.strokePolylineAA(seg[0..], tf, s.color);
        },
        .arrow => drawArrow(canvas, xf.fx(s.p0.x), xf.fy(s.p0.y), xf.fx(s.p1.x), xf.fy(s.p1.y), tf, s.arrowHead() * xf.scale, s.color),
        .rect => drawRect(canvas, s, xf, tf),
        .ellipse => {
            const r = xf.rect(s.frame());
            if (s.filled) raster.fillEllipseAA(canvas, r, s.color) else canvas.ellipseRingAA(r.x, r.y, r.w, r.h, tf, s.color);
        },
        .blur, .pixelate, .redact => drawRedaction(canvas, alloc, s, xf),
        .counter => drawCounter(canvas, s, xf),
        .text => draw_text.drawText(canvas, alloc, s, xf, cursor),
        .ruler => ruler.draw(canvas, s, xf),
        .spotlight => spotlight.draw(canvas, s, xf),
        .select => {},
    }
}

/// A pen stroke, or a translucent highlighter three times as wide.
fn drawStroke(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform, tf: f64) void {
    const pts = alloc.alloc(Point, s.points.items.len) catch return;
    defer alloc.free(pts);
    for (pts, s.points.items) |*d, p| d.* = xf.pt(p);
    if (s.tool == .pen) {
        canvas.strokePolylineAA(pts, tf, s.color);
    } else {
        canvas.strokePolylineAA(pts, tf * 3.0, (s.color & 0x00FFFFFF) | 0x66000000);
    }
}

fn drawRect(canvas: *Canvas, s: *const Shape, xf: Xform, tf: f64) void {
    const r = xf.rect(s.frame());
    const rad = if (s.rounded) s.cornerRadius() * xf.scale else 0;
    if (s.filled) {
        if (rad > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, s.color) else canvas.fillRect(r.x, r.y, r.w, r.h, s.color);
    } else if (rad > 0) {
        raster.roundRectRing(canvas, r, rad, tf, s.color);
    } else {
        canvas.rectOutline(r.x, r.y, r.w, r.h, @intFromFloat(@round(tf)), s.color);
    }
}

/// Blur, pixelate or redact the pixels under the shape's frame.
fn drawRedaction(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform) void {
    const r = xf.rect(s.frame());
    const area: effects.Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    switch (s.tool) {
        .blur => {
            const rad: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(s.blurRadius())) * xf.scale))));
            effects.blur(alloc, canvas.px, @intCast(canvas.w), @intCast(canvas.h), area, rad) catch {};
        },
        .pixelate => {
            const blk: i32 = @max(2, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(s.pixelBlock())) * xf.scale))));
            raster.pixelateAligned(canvas, r, blk);
        },
        else => effects.redact(canvas.px, @intCast(canvas.w), @intCast(canvas.h), area, s.color),
    }
}

/// A numbered badge: a filled circle with a white ring and its number.
fn drawCounter(canvas: *Canvas, s: *const Shape, xf: Xform) void {
    const r = s.counterRadius() * xf.scale;
    const cx = xf.fx(s.p0.x);
    const cy = xf.fy(s.p0.y);
    canvas.fillCircleAA(cx, cy, r, s.color);
    canvas.ringAA(cx, cy, r, @max(1.0, r * 0.12), 0xFFFFFFFF);
    var buf: [12]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}", .{s.number}) catch "?";
    const fs = r * (if (s.number >= 10) @as(f64, 0.95) else 1.15);
    text_mod.draw(
        canvas,
        @as(i32, @intFromFloat(@round(cx))) - @divTrunc(text_mod.width(fs, label), 2),
        @as(i32, @intFromFloat(@round(cy))) - @divTrunc(text_mod.height(fs), 2),
        fs,
        raster.contrastColor(s.color),
        label,
    );
}

/// Arrow with a filled head whose tip lands exactly on (x1, y1).
pub fn drawArrow(canvas: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, width: f64, head_len: f64, color: u32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    const head = @min(head_len, len);
    const ux = dx / len;
    const uy = dy / len;
    const seg = [_]Point{
        .{ .x = @intFromFloat(@round(x0)), .y = @intFromFloat(@round(y0)) },
        .{ .x = @intFromFloat(@round(x1 - ux * head * 0.7)), .y = @intFromFloat(@round(y1 - uy * head * 0.7)) },
    };
    canvas.strokePolylineAA(seg[0..], width, color);
    const px = -uy;
    const py = ux;
    const hw = @max(head * 0.45, width);
    canvas.fillTriangleAA(x1, y1, x1 - ux * head + px * hw, y1 - uy * head + py * hw, x1 - ux * head - px * hw, y1 - uy * head - py * hw, color);
}

test "drawing through a transform scales shapes" {
    const alloc = std.testing.allocator;
    var px: [40 * 40]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 40, 40);
    const s = Shape{ .tool = .redact, .color = 0xFFFFFFFF, .thickness = 2, .p0 = .{ .x = 10, .y = 10 }, .p1 = .{ .x = 30, .y = 30 } };
    drawShape(&c, alloc, &s, .{ .scale = 0.5, .ox = 5, .oy = 5 }, null);
    // image (10..30) -> canvas (10..20)
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 40 + 10]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[19 * 40 + 19]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[20 * 40 + 20]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[9 * 40 + 9]);
}
