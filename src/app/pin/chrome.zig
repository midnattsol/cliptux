//! What a pin draws over its picture: on hover the ⋯ (menu) and close
//! buttons and, away from 100%, the zoom; while locked the badge that
//! unlocks it; while young on a plain GNOME window, the Keep on Top hint.
//! Positions in buffer pixels from the picture's top-left unless said.

const std = @import("std");
const text = @import("../../gfx/text.zig");
const icons = @import("../../ui/icons.zig");
const fui = @import("../../ui/floatui.zig");
const Rect = @import("../../ui/shapes.zig").Rect;
const Hover = @import("state.zig").Hover;

/// the round buttons' radius and their distance from the corner, logical
pub const radius = 11;
const inset = 8;
const gap = 6;

/// The centre of the close button, or of the ⋯ button left of it.
pub fn centre(b: enum { close, more }, pw: u32, k: f64) [2]f64 {
    const r = radius * k;
    const cx = @as(f64, @floatFromInt(pw)) - inset * k - r;
    const cy = inset * k + r;
    return switch (b) {
        .close => .{ cx, cy },
        .more => .{ cx - 2 * r - gap * k, cy },
    };
}

/// The locked pin's badge (where the close button is) in logical pixels
/// on the surface, for `pic`, the picture's place there.
pub fn badgeRect(pic: Rect) Rect {
    return .{ .x = pic.x + pic.w - inset - 2 * radius, .y = pic.y + inset, .w = 2 * radius, .h = 2 * radius };
}

/// What is under x, y on a `pw` wide picture.
pub fn under(pw: u32, k: f64, x: f64, y: f64, locked: bool) Hover {
    const r2 = radius * k * radius * k * 1.4;
    const c = centre(.close, pw, k);
    const on_close = (x - c[0]) * (x - c[0]) + (y - c[1]) * (y - c[1]) <= r2;
    if (locked) return if (on_close) .badge else .none;
    if (on_close) return .close;
    const m = centre(.more, pw, k);
    if ((x - m[0]) * (x - m[0]) + (y - m[1]) * (y - m[1]) <= r2) return .more;
    return .picture;
}

pub const Look = struct {
    hover: Hover,
    locked: bool,
    zoom: f64,
    hint: bool,
};

/// The chrome `look` asks for, on the picture's card.
pub fn draw(cv: *fui.Canvas, k: f64, pw: u32, ph: u32, look: Look) void {
    if (look.locked) drawBadge(cv, k, pw, look.hover == .badge);
    if (!look.locked and look.hover != .none) {
        button(cv, k, centre(.close, pw, k), look.hover == .close, .close);
        button(cv, k, centre(.more, pw, k), look.hover == .more or look.hover == .menu, .more);
        if (look.zoom != 1) drawZoom(cv, k, ph, look.zoom);
    }
    if (look.hint) drawHint(cv, k, pw, ph);
}

fn button(cv: *fui.Canvas, k: f64, c: [2]f64, hot: bool, icon: icons.Icon) void {
    cv.fillCircleAA(c[0], c[1], radius * k, if (hot) fui.btn_round_hover else fui.btn_round);
    const s: i32 = @intFromFloat(@round(14 * k));
    icons.drawStroke(cv, icon, @intFromFloat(@round(c[0] - @as(f64, @floatFromInt(s)) / 2)), @intFromFloat(@round(c[1] - @as(f64, @floatFromInt(s)) / 2)), s, if (icon == .close) 2.4 else 3, fui.white);
}

/// The lock badge; hovered, it says what a click does.
fn drawBadge(cv: *fui.Canvas, k: f64, pw: u32, hot: bool) void {
    const c = centre(.close, pw, k);
    button(cv, k, c, hot, .lock);
    if (!hot) return;
    const msg = "Click to unlock";
    const fs = 11 * k;
    const tw = text.width(fs, msg) + @as(i32, @intFromFloat(16 * k));
    const th: i32 = @intFromFloat(22 * k);
    const x = @as(i32, @intFromFloat(c[0] - radius * k - gap * k)) - tw;
    const y = @as(i32, @intFromFloat(c[1])) - @divTrunc(th, 2);
    cv.fillRoundRectAA(x, y, tw, th, 11 * k, 0xCC000000);
    fui.textCentered(cv, .{ .x = x, .y = y, .w = tw, .h = th }, fs, fui.white, .regular, msg);
}

fn drawZoom(cv: *fui.Canvas, k: f64, ph: u32, zoom: f64) void {
    var zb: [16]u8 = undefined;
    const zs = std.fmt.bufPrint(&zb, "{d}%", .{@as(u32, @intFromFloat(@round(zoom * 100)))}) catch "";
    const tw = text.widthStyled(11 * k, text.Style.regular.num(), zs) + @as(i32, @intFromFloat(12 * k));
    const th: i32 = @intFromFloat(20 * k);
    const r: Rect = .{ .x = @intFromFloat(inset * k), .y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(inset * k)), .w = tw, .h = th };
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 10 * k, 0x99000000);
    fui.textCentered(cv, r, 11 * k, fui.white, text.Style.regular.num(), zs);
}

fn drawHint(cv: *fui.Canvas, k: f64, pw: u32, ph: u32) void {
    const msg = "Right-click: Keep on Top";
    const tw = text.width(11 * k, msg) + @as(i32, @intFromFloat(16 * k));
    const th: i32 = @intFromFloat(22 * k);
    const x = @divTrunc(@as(i32, @intCast(pw)) - tw, 2);
    const y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(10 * k));
    cv.fillRoundRectAA(x, y, tw, th, 11 * k, 0xCC000000);
    fui.textCentered(cv, .{ .x = x, .y = y, .w = tw, .h = th }, 11 * k, fui.white, .regular, msg);
}

test "the buttons sit in the top-right corner, ⋯ left of close" {
    const c = centre(.close, 300, 1);
    const m = centre(.more, 300, 1);
    try std.testing.expectEqual(@as(f64, 300 - 8 - 11), c[0]);
    try std.testing.expect(m[0] < c[0] - 20);
    try std.testing.expectEqual(Hover.close, under(300, 1, c[0], c[1], false));
    try std.testing.expectEqual(Hover.more, under(300, 1, m[0], m[1], false));
    try std.testing.expectEqual(Hover.picture, under(300, 1, 20, 100, false));
    // locked: only the badge, where close was
    try std.testing.expectEqual(Hover.badge, under(300, 1, c[0], c[1], true));
    try std.testing.expectEqual(Hover.none, under(300, 1, m[0], m[1], true));
    const b = badgeRect(.{ .x = 14, .y = 14, .w = 300, .h = 200 });
    try std.testing.expect(b.contains(14 + @as(i32, @intFromFloat(c[0])), 14 + @as(i32, @intFromFloat(c[1]))));
}
