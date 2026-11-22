//! The video thumbnail card (record/quickvid.zig): the first picture,
//! the duration (and "GIF") in a badge; on hover the filmstrip plays and
//! Copy / Save as… / trim / close show, as on the screenshot thumbnail.

const std = @import("std");
const fui = @import("../floatui.zig");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const glyphs = @import("glyphs.zig");
const control_draw = @import("control_draw.zig");
const Rect = @import("../shapes.zig").Rect;

pub const card_w = 240;
pub const card_h = 150;
pub const pad = 28;

pub const Control = enum { body, close, trim, copy, save_as };

pub const View = struct {
    /// the picture shown (first frame, or a strip picture on hover)
    pic: []const u32,
    pic_w: u32,
    pic_h: u32,
    duration_ms: i64,
    gif: bool,
    hover: ?Control = null,
    hovered: bool = false,
    notice: []const u8 = "",
    alpha: f64 = 1,
};

pub fn windowSize() [2]u32 {
    return .{ card_w + 2 * pad, card_h + 2 * pad };
}

pub fn controlRect(c: Control) Rect {
    const pw = (card_w - 16 - 6) / 2;
    return switch (c) {
        .close => .{ .x = 8, .y = 8, .w = 26, .h = 26 },
        .trim => .{ .x = card_w - 8 - 26, .y = 8, .w = 26, .h = 26 },
        .copy => .{ .x = 8, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .save_as => .{ .x = 8 + pw + 6, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .body => .{ .x = 0, .y = 0, .w = card_w, .h = card_h },
    };
}

/// What is under a logical point of the window.
pub fn hit(x: i32, y: i32) ?Control {
    const lx = x - pad;
    const ly = y - pad;
    if (lx < 0 or ly < 0 or lx >= card_w or ly >= card_h) return null;
    for ([_]Control{ .close, .trim, .copy, .save_as }) |c| {
        const r = controlRect(c);
        if (lx >= r.x and ly >= r.y and lx < r.x + r.w and ly < r.y + r.h) return c;
    }
    return .body;
}

fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

/// Paint the card onto the window buffer (straight alpha).
pub fn paint(gpa: std.mem.Allocator, px: []u32, bw: u32, bh: u32, k: f64, v: *const View) void {
    const cw: u32 = @intCast(sc(card_w, k));
    const ch: u32 = @intCast(sc(card_h, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    @memset(card, fui.card_bg);
    fui.drawImageFill(gpa, card, cw, ch, v.pic, v.pic_w, v.pic_h);
    var cv = render.Canvas.init(card, cw, ch);
    badge(&cv, k, v);
    if (v.hovered) controls(&cv, k, v);
    if (v.notice.len > 0) notice(&cv, k, v.notice);
    const sp = sc(pad, k);
    const lw: u32 = cw + @as(u32, @intCast(2 * sp));
    const lh: u32 = ch + @as(u32, @intCast(2 * sp));
    const layer = gpa.alloc(u32, @as(usize, lw) * lh) catch return;
    defer gpa.free(layer);
    @memset(layer, 0);
    fui.placeCard(layer, lw, lh, card, cw, ch, sp, sp, @intCast(sc(12, k)), @intCast(sc(20, k)));
    fui.fadeAlpha(layer, v.alpha);
    fui.blitOver(px, bw, bh, layer, lw, lh, 0, 0);
}

fn badge(cv: *render.Canvas, k: f64, v: *const View) void {
    var buf: [40]u8 = undefined;
    var tb: [32]u8 = undefined;
    const t = control_draw.formatTime(&tb, v.duration_ms + 500);
    const s = if (v.gif) std.fmt.bufPrint(&buf, "GIF \u{00B7} {s}", .{t}) catch t else t;
    const fs = 11.5 * k;
    const w = text.widthStyled(fs, .bold, s) + sc(14, k) + sc(14, k);
    const h = sc(22, k);
    const x = cv.w - w - sc(8, k);
    const y = if (v.hovered) sc(8 + 26 + 6, k) else cv.h - h - sc(8, k);
    cv.fillRoundRectAA(x, y, w, h, 11 * k, 0xCC000000);
    glyphs.draw(cv, .play, x + sc(5, k), y + @divTrunc(h - sc(12, k), 2), sc(12, k), 0xFFFFFFFF);
    text.drawStyled(cv, x + sc(19, k), y + @divTrunc(h - text.heightStyled(fs, .bold), 2), fs, 0xFFFFFFFF, .bold, s);
}

fn controls(cv: *render.Canvas, k: f64, v: *const View) void {
    cv.fillRect(0, 0, cv.w, cv.h, 0x40000000);
    for ([_]Control{ .close, .trim }) |c| {
        const r = controlRect(c);
        const cx = (@as(f64, @floatFromInt(r.x)) + 13) * k;
        const cy = (@as(f64, @floatFromInt(r.y)) + 13) * k;
        cv.fillCircleAA(cx, cy, 13 * k, if (v.hover == c) fui.btn_round_hover else fui.btn_round);
        if (c == .close) fui.icon(cv, .close, cx, cy, 14 * k, fui.white) else glyphs.drawCentered(cv, .scissors, @intFromFloat(cx), @intFromFloat(cy), sc(15, k), fui.white);
    }
    for ([_]Control{ .copy, .save_as }) |c| {
        const r = controlRect(c);
        const rr: Rect = .{ .x = sc(r.x, k), .y = sc(r.y, k), .w = sc(r.w, k), .h = sc(r.h, k) };
        cv.fillRoundRectAA(rr.x, rr.y, rr.w, rr.h, 8 * k, if (v.hover == c) fui.pill_hover else fui.pill);
        fui.textCentered(cv, rr, 13 * k, fui.pill_text, .bold, if (c == .copy) "Copy" else "Save as\u{2026}");
    }
}

fn notice(cv: *render.Canvas, k: f64, s: []const u8) void {
    const tw = text.widthStyled(13 * k, .bold, s) + sc(28, k);
    const nh = sc(30, k);
    const nr: Rect = .{ .x = @divTrunc(cv.w - tw, 2), .y = @divTrunc(cv.h - nh, 2), .w = tw, .h = nh };
    cv.fillRoundRectAA(nr.x, nr.y, nr.w, nr.h, 15 * k, 0xE6000000);
    fui.textCentered(cv, nr, 13 * k, fui.white, .bold, s);
}

test "card controls hit" {
    try std.testing.expectEqual(@as(?Control, .close), hit(pad + 10, pad + 10));
    try std.testing.expectEqual(@as(?Control, .trim), hit(pad + card_w - 20, pad + 10));
    try std.testing.expectEqual(@as(?Control, .copy), hit(pad + 20, pad + card_h - 20));
    try std.testing.expectEqual(@as(?Control, .body), hit(pad + 120, pad + 70));
    try std.testing.expect(hit(2, 2) == null);
}
