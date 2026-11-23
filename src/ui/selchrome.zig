//! How a selection over a frozen capture looks, wherever one is drawn
//! (the editor's capture, the record picker, the scrolling capture's
//! picker): a two-tone edge, round white handles at the corners (and
//! mid-edge where the pointer is near), and the size in a pill above it.
//! The dim around it is ui/dim.zig. Sizes are logical times the scale `f`.
//!
//! Stable API:
//!   edge(canvas, s, th)                       the two-tone edge around s
//!   handle_radius, handle(canvas, x, y, r, f, th)   one handle
//!   handleShown(s, i, mouse, grab)            whether handle i shows
//!   handleCursor(i)                           the pointer over handle i
//!   handles(canvas, s, mouse, grab, f, th)    the handles that show
//!   pill(canvas, r, radius, th)               a label pill on the capture
//!   size_style, sizeLabel(buf, w, h), sizePillRect(label, frame, bounds_w, f)
//!   sizePill(canvas, r, f, th, label)

const std = @import("std");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const shapes = @import("shapes.zig");
const theme = @import("theme.zig");
const Cursor = @import("../platform/api.zig").window.Cursor;

const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;
const Theme = theme.Theme;

/// a selection handle's radius, logical px
pub const handle_radius: f64 = 5;
/// the size pill's text: medium weight, figures that do not jiggle
pub const size_style = text.Style.medium.num();

fn px(v: f64, f: f64) i32 {
    return @intFromFloat(@round(v * f));
}

/// Two tones: the light line shows on dark captures, the dark one around
/// it on light ones.
pub fn edge(cv: *Canvas, s: Rect, th: Theme) void {
    cv.rectOutline(s.x - 2, s.y - 2, s.w + 4, s.h + 4, 1, th.sel_edge_outer);
    cv.rectOutline(s.x - 1, s.y - 1, s.w + 2, s.h + 2, 1, th.sel_edge);
}

/// A white handle with a soft shadow.
pub fn handle(cv: *Canvas, x: f64, y: f64, r: f64, f: f64, th: Theme) void {
    cv.fillCircleAA(x, y + 1.0 * f, r + 1.5 * f, 0x1F000000);
    cv.fillCircleAA(x, y + 1.0 * f, r + 0.5 * f, 0x40000000);
    cv.fillCircleAA(x, y, r, th.handle);
}

/// Which handles show (shapes.handlePoints order): the corners always, an
/// edge's middle only while `mouse` is within twice `grab` of it (and the
/// selection is big enough to grab it apart from the corners).
pub fn handleShown(s: Rect, i: usize, mouse: ?Point, grab: i32) bool {
    if (i % 2 == 0) return true;
    const m = mouse orelse return false;
    if (s.w < 4 * grab or s.h < 4 * grab) return false;
    const p = shapes.handlePoints(s)[i];
    return @abs(m.x - p.x) <= 2 * grab and @abs(m.y - p.y) <= 2 * grab;
}

/// The resize cursor over handle `i` (shapes.handlePoints order).
pub fn handleCursor(i: u3) Cursor {
    return switch (i) {
        0, 4 => .resize_nwse,
        2, 6 => .resize_nesw,
        1, 5 => .resize_ns,
        3, 7 => .resize_ew,
    };
}

/// The handles of `s` that show, for a pointer at `mouse` (null: not over
/// this surface).
pub fn handles(cv: *Canvas, s: Rect, mouse: ?Point, grab: i32, f: f64, th: Theme) void {
    for (shapes.handlePoints(s), 0..) |p, i| {
        if (!handleShown(s, i, mouse, grab)) continue;
        handle(cv, @floatFromInt(p.x), @floatFromInt(p.y), handle_radius * f, f, th);
    }
}

/// A label pill over the capture (the size, tooltips, readouts), see
/// theme.Theme.pill_bg.
pub fn pill(cv: *Canvas, r: Rect, radius: f64, th: Theme) void {
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, th.pill_bg);
    shapes.roundRectRing(cv, r, radius, 1, th.pill_line);
}

/// "w × h" (an x without a font that has the sign).
pub fn sizeLabel(buf: []u8, w: i32, h: i32) []const u8 {
    const x = if (text.available()) "\u{00D7}" else "x";
    return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ w, x, h }) catch "?";
}

/// The size pill for `label`: above `frame`'s top-left corner, inside it
/// when there is no room above, within a surface `bounds_w` wide.
pub fn sizePillRect(label: []const u8, frame: Rect, bounds_w: i32, f: f64) Rect {
    const fs = theme.font_small * f;
    const ph = text.height(fs) + px(8, f);
    const pw = text.widthStyled(fs, size_style, label) + px(20, f);
    var lx = frame.x;
    var ly = frame.y - ph - px(10, f);
    if (ly < 6) ly = frame.y + px(10, f);
    if (lx + pw > bounds_w - 6) lx = bounds_w - pw - 6;
    if (lx < 6) lx = 6;
    return .{ .x = lx, .y = ly, .w = pw, .h = ph };
}

pub fn sizePill(cv: *Canvas, r: Rect, f: f64, th: Theme, label: []const u8) void {
    pill(cv, r, 7.0 * f, th);
    text.drawStyled(cv, r.x + px(10, f), r.y + px(4, f), theme.font_small * f, th.pill_fg, size_style, label);
}

test "the mid-edge handles show only near the pointer" {
    const s: Rect = .{ .x = 100, .y = 100, .w = 200, .h = 100 };
    try std.testing.expect(handleShown(s, 0, null, 10));
    try std.testing.expect(!handleShown(s, 1, null, 10));
    try std.testing.expect(handleShown(s, 3, .{ .x = 305, .y = 150 }, 10));
    try std.testing.expect(!handleShown(s, 1, .{ .x = 305, .y = 150 }, 10));
    // too small to grab an edge apart from its corners
    try std.testing.expect(!handleShown(.{ .x = 0, .y = 0, .w = 30, .h = 30 }, 3, .{ .x = 30, .y = 15 }, 10));
}

test "a handle's cursor points the way it resizes" {
    try std.testing.expectEqual(Cursor.resize_nwse, handleCursor(0));
    try std.testing.expectEqual(Cursor.resize_ns, handleCursor(1));
    try std.testing.expectEqual(Cursor.resize_nesw, handleCursor(2));
    try std.testing.expectEqual(Cursor.resize_ew, handleCursor(3));
    try std.testing.expectEqual(Cursor.resize_nwse, handleCursor(4));
    try std.testing.expectEqual(Cursor.resize_ew, handleCursor(7));
}

test "the size pill sits above the selection, or inside it at the top" {
    const above = sizePillRect("400 x 300", .{ .x = 100, .y = 100, .w = 400, .h = 300 }, 1600, 1);
    try std.testing.expect(above.y + above.h < 100);
    try std.testing.expectEqual(@as(i32, 100), above.x);
    const inside = sizePillRect("400 x 300", .{ .x = 100, .y = 4, .w = 400, .h = 300 }, 1600, 1);
    try std.testing.expect(inside.y > 4);
}
