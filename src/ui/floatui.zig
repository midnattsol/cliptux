//! Drawing helpers for the floating windows (quick-access thumbnails,
//! pins, the history panel): see-through surfaces, cards with soft
//! shadows, small line icons and buttons.
//!
//! Transparent surfaces are drawn in straight alpha (effects.over handles
//! a see-through destination) and converted with premultiply() just
//! before presenting, as wl_shm's argb8888 wants. Canvas drawing assumes
//! an opaque destination, so content goes into opaque card buffers first
//! and the card is then placed with its rounded corners.

const std = @import("std");
const render = @import("../gfx/render.zig");
const effects = @import("../gfx/effects.zig");
const text = @import("../gfx/text.zig");

pub const Canvas = render.Canvas;
pub const Rect = effects.Rect;

/// Palette of the floating UI (dark glass, as on macOS)
pub const veil: u32 = 0x6B000000;
pub const btn_round: u32 = 0x33FFFFFF;
pub const btn_round_hover: u32 = 0x55FFFFFF;
pub const pill: u32 = 0xEBFFFFFF;
pub const pill_hover: u32 = 0xFFFFFFFF;
pub const pill_text: u32 = 0xFF1D1D1F;
pub const white: u32 = 0xFFFFFFFF;
pub const accent: u32 = 0xFF0A84FF;
pub const card_bg: u32 = 0xFF2A2E37;
pub const shadow: u32 = 0x48000000;

/// Panel colours for light and dark (history panel, pin frame)
pub const Theme = struct {
    panel: u32,
    fg: u32,
    muted: u32,
    field: u32,
    line: u32,
    hover: u32,

    pub const dark: Theme = .{ .panel = 0xFF242426, .fg = 0xFFF5F5F7, .muted = 0xFF9E9EA6, .field = 0xFF323235, .line = 0xFF3A3A3D, .hover = 0xFF2F2F33 };
    pub const light: Theme = .{ .panel = 0xFFFAFAFC, .fg = 0xFF1D1D1F, .muted = 0xFF6E6E73, .field = 0xFFEDEDF0, .line = 0xFFDCDCE0, .hover = 0xFFF0F0F3 };
};

pub fn clipRect(r: Rect, w: u32, h: u32) ?Rect {
    return effects.clip(r, w, h);
}

/// Straight to premultiplied alpha, in place, over `r`.
pub fn premultiply(px: []u32, w: u32, h: u32, r: Rect) void {
    const c = effects.clip(r, w, h) orelse return;
    var y = c.y;
    while (y < c.y + c.h) : (y += 1) {
        const row = px[@as(usize, @intCast(y)) * w + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        for (row) |*p| {
            const a = p.* >> 24;
            if (a == 255) continue;
            if (a == 0) {
                p.* = 0;
                continue;
            }
            p.* = scaleRgb(p.*, a) | (a << 24);
        }
    }
}

fn scaleRgb(p: u32, a: u32) u32 {
    const r = ((p >> 16) & 0xFF) * a / 255;
    const g = ((p >> 8) & 0xFF) * a / 255;
    const b = (p & 0xFF) * a / 255;
    return (r << 16) | (g << 8) | b;
}

/// Multiply straight-alpha pixels' alpha by `f` (0..1): fading.
pub fn fadeAlpha(px: []u32, f: f64) void {
    if (f >= 1.0) return;
    const k: u32 = @intFromFloat(std.math.clamp(f, 0, 1) * 256);
    for (px) |*p| p.* = (((p.* >> 24) * k >> 8) << 24) | (p.* & 0xFFFFFF);
}

/// `src` (straight alpha, sw x sh) over `dst` at x, y.
pub fn blitOver(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32) void {
    const c = effects.clip(.{ .x = x, .y = y, .w = @intCast(sw), .h = @intCast(sh) }, dw, dh) orelse return;
    var yy = c.y;
    while (yy < c.y + c.h) : (yy += 1) {
        const sy: usize = @intCast(yy - y);
        const sx: usize = @intCast(c.x - x);
        const drow = dst[@as(usize, @intCast(yy)) * dw + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        const srow = src[sy * sw + sx ..][0..@intCast(c.w)];
        for (drow, srow) |*d, s| d.* = effects.over(d.*, s);
    }
}

/// An opaque card (content in `card`) with rounded corners and a soft
/// shadow, onto a straight-alpha buffer.
pub fn placeCard(dst: []u32, dw: u32, dh: u32, card: []const u32, cw: u32, ch: u32, x: i32, y: i32, radius: u32, shadow_px: u32) void {
    if (shadow_px > 0) {
        effects.dropShadow(dst, dw, dh, .{ .x = x, .y = y, .w = @intCast(cw), .h = @intCast(ch) }, shadow_px, @intCast(shadow_px / 3), shadow);
    }
    effects.blitRounded(dst, dw, dh, card, cw, ch, x, y, radius);
}

/// Draw `src` scaled to cover (or, for very different shapes, to fit in)
/// the whole of `dst`, over a dark backdrop. Box filter / nearest.
pub fn drawImageFill(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32) void {
    @memset(dst, card_bg);
    if (sw == 0 or sh == 0) return;
    const ar_src = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(sh));
    const ar_dst = @as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(dh));
    const ratio = ar_src / ar_dst;
    const cover = ratio > 0.7 and ratio < 1.4;
    const s = if (cover)
        @max(@as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(sw)), @as(f64, @floatFromInt(dh)) / @as(f64, @floatFromInt(sh)))
    else
        @min(@as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(sw)), @as(f64, @floatFromInt(dh)) / @as(f64, @floatFromInt(sh)));
    const tw: f64 = @as(f64, @floatFromInt(sw)) * s;
    const th: f64 = @as(f64, @floatFromInt(sh)) * s;
    const ox = (@as(f64, @floatFromInt(dw)) - tw) / 2;
    const oy = (@as(f64, @floatFromInt(dh)) - th) / 2;
    for (0..dh) |y| {
        const fy = (@as(f64, @floatFromInt(y)) + 0.5 - oy) / s;
        if (fy < 0 or fy >= @as(f64, @floatFromInt(sh))) continue;
        const sy: usize = @intFromFloat(fy);
        for (0..dw) |x| {
            const fx = (@as(f64, @floatFromInt(x)) + 0.5 - ox) / s;
            if (fx < 0 or fx >= @as(f64, @floatFromInt(sw))) continue;
            const p = src[sy * sw + @as(usize, @intFromFloat(fx))];
            dst[y * dw + x] = effects.over(dst[y * dw + x], p);
        }
    }
}

/// Bilinear sample for smoother small thumbnails.
pub fn sampleBilinear(src: []const u32, sw: u32, sh: u32, fx: f64, fy: f64) u32 {
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(fx), 0, @as(f64, @floatFromInt(sw - 1))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(fy), 0, @as(f64, @floatFromInt(sh - 1))));
    const x1 = @min(x0 + 1, sw - 1);
    const y1 = @min(y0 + 1, sh - 1);
    const tx = std.math.clamp(fx - @as(f64, @floatFromInt(x0)), 0, 1);
    const ty = std.math.clamp(fy - @as(f64, @floatFromInt(y0)), 0, 1);
    var out: u32 = 0;
    inline for (0..4) |c| {
        const sh_: u5 = c * 8;
        const a: f64 = @floatFromInt((src[y0 * sw + x0] >> sh_) & 0xFF);
        const b: f64 = @floatFromInt((src[y0 * sw + x1] >> sh_) & 0xFF);
        const cc: f64 = @floatFromInt((src[y1 * sw + x0] >> sh_) & 0xFF);
        const d: f64 = @floatFromInt((src[y1 * sw + x1] >> sh_) & 0xFF);
        const v = (a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + d * tx) * ty;
        out |= @as(u32, @intFromFloat(@round(v))) << sh_;
    }
    return out;
}

pub const Icon = enum { close, pencil, pin, search, trash, copy, save };

/// A line icon in a `size` box centred on cx, cy (24-unit design grid).
pub fn icon(c: *Canvas, kind: Icon, cx: f64, cy: f64, size: f64, color: u32) void {
    const k = size / 24.0;
    const w = @max(1.2, 2.0 * k);
    const P = struct { x: i32, y: i32 };
    const S = struct {
        fn p(kk: f64, ccx: f64, ccy: f64, x: f64, y: f64) P {
            return .{ .x = @intFromFloat(@round(ccx + (x - 12) * kk)), .y = @intFromFloat(@round(ccy + (y - 12) * kk)) };
        }
    };
    switch (kind) {
        .close => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 7, 7), S.p(k, cx, cy, 17, 17) }, w * 1.2, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 17, 7), S.p(k, cx, cy, 7, 17) }, w * 1.2, color);
        },
        .pencil => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 4, 20), S.p(k, cx, cy, 8, 19), S.p(k, cx, cy, 19, 8), S.p(k, cx, cy, 16, 5), S.p(k, cx, cy, 5, 16), S.p(k, cx, cy, 4, 20) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 14, 7), S.p(k, cx, cy, 17, 10) }, w, color);
        },
        .pin => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 12, 16), S.p(k, cx, cy, 12, 21) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 8, 3), S.p(k, cx, cy, 16, 3), S.p(k, cx, cy, 15, 9), S.p(k, cx, cy, 18, 12), S.p(k, cx, cy, 18, 16), S.p(k, cx, cy, 6, 16), S.p(k, cx, cy, 6, 12), S.p(k, cx, cy, 9, 9), S.p(k, cx, cy, 8, 3) }, w, color);
        },
        .search => {
            c.ringAA(cx + (11 - 12) * k, cy + (11 - 12) * k, 7 * k, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 16, 16), S.p(k, cx, cy, 20, 20) }, w, color);
        },
        .trash => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 4, 6), S.p(k, cx, cy, 20, 6) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 9, 6), S.p(k, cx, cy, 9, 3), S.p(k, cx, cy, 15, 3), S.p(k, cx, cy, 15, 6) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 6, 6), S.p(k, cx, cy, 7, 21), S.p(k, cx, cy, 17, 21), S.p(k, cx, cy, 18, 6) }, w, color);
        },
        .copy => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 8, 8), S.p(k, cx, cy, 20, 8), S.p(k, cx, cy, 20, 20), S.p(k, cx, cy, 8, 20), S.p(k, cx, cy, 8, 8) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 4, 16), S.p(k, cx, cy, 4, 4), S.p(k, cx, cy, 16, 4) }, w, color);
        },
        .save => {
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 12, 4), S.p(k, cx, cy, 12, 15) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 7, 10), S.p(k, cx, cy, 12, 15), S.p(k, cx, cy, 17, 10) }, w, color);
            c.strokePolylineAA(&[_]P{ S.p(k, cx, cy, 4, 17), S.p(k, cx, cy, 4, 20), S.p(k, cx, cy, 20, 20), S.p(k, cx, cy, 20, 17) }, w, color);
        },
    }
}

/// Text centred in `r` (vertically by line height).
pub fn textCentered(c: *Canvas, r: @import("shapes.zig").Rect, size: f64, color: u32, style: text.Style, s: []const u8) void {
    const tw = text.widthStyled(size, style, s);
    const th = text.heightStyled(size, style);
    text.drawStyled(c, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - th, 2), size, color, style, s);
}

/// `s` cut with "..." to fit `max_w` pixels.
pub fn ellipsize(buf: []u8, size: f64, s: []const u8, max_w: i32) []const u8 {
    if (text.width(size, s) <= max_w) return s;
    var n = s.len;
    while (n > 0) {
        n -= 1;
        while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
        const out = std.fmt.bufPrint(buf, "{s}...", .{s[0..n]}) catch return s;
        if (text.width(size, out) <= max_w) return out;
    }
    return "...";
}

test "premultiply and fades keep opaque pixels and clear transparent ones" {
    var px = [_]u32{ 0xFF102030, 0x80FF0000, 0x00FFFFFF, 0x40000000 };
    premultiply(&px, 4, 1, .{ .x = 0, .y = 0, .w = 4, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0xFF102030), px[0]);
    try std.testing.expectEqual(@as(u32, 0x80800000), px[1]);
    try std.testing.expectEqual(@as(u32, 0), px[2]);
    try std.testing.expectEqual(@as(u32, 0x40000000), px[3]);
    var f = [_]u32{ 0xFF123456, 0x80FFFFFF };
    fadeAlpha(&f, 0.5);
    try std.testing.expectEqual(@as(u32, 0x7F), f[0] >> 24);
    try std.testing.expectEqual(@as(u32, 0x123456), f[0] & 0xFFFFFF);
    try std.testing.expectEqual(@as(u32, 0x40), f[1] >> 24);
}
