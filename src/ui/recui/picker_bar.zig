//! The record picker's bar (picker.zig): a compact Glass bar under the
//! chosen area, in logical pixels relative to the bar.
//!
//!   [ ● Record ] [ MP4 | GIF ] | 🎙 🔊 | click keys | ×
//!
//! Clicks and keystrokes are drawn by the GNOME Shell extension; without
//! it those two are greyed and say so.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const icons = @import("../icons.zig");
const glyphs = @import("glyphs.zig");
const fui = @import("../floatui.zig");
const settings_mod = @import("../../record/settings.zig");
const Rect = @import("../window.zig").Rect;

pub const Item = enum { record, mp4, gif, mic, system, clicks, keys, close };

pub const State = struct {
    set: *settings_mod.Settings,
    /// clicks and keystrokes can be shown (the GNOME integration records)
    overlays: bool,
    hover: ?Item = null,
};

const h = 44;
const btn = 32;
const items = [_]struct { item: Item, w: i32, gap: i32 = 4 }{
    .{ .item = .record, .w = 92, .gap = 8 },
    .{ .item = .mp4, .w = 44, .gap = 0 },
    .{ .item = .gif, .w = 44, .gap = 13 },
    .{ .item = .mic, .w = btn },
    .{ .item = .system, .w = btn, .gap = 13 },
    .{ .item = .clicks, .w = btn },
    .{ .item = .keys, .w = btn, .gap = 13 },
    .{ .item = .close, .w = btn, .gap = 6 },
};

pub fn size() [2]i32 {
    var w: i32 = 6;
    for (items) |it| w += it.w + it.gap;
    return .{ w, h };
}

fn rectOf(item: Item) Rect {
    var x: i32 = 6;
    for (items) |it| {
        if (it.item == item) return .{ .x = x, .y = (h - btn) / 2, .w = it.w, .h = btn };
        x += it.w + it.gap;
    }
    unreachable;
}

pub fn hit(lx: i32, ly: i32) ?Item {
    for (items) |it| {
        const r = rectOf(it.item);
        if (lx >= r.x and ly >= r.y and lx < r.x + r.w and ly < r.y + r.h) return it.item;
    }
    return null;
}

/// What an item does to the settings; true when it starts or cancels
/// (the caller handles .record and .close).
pub fn toggle(st: *State, item: Item) void {
    const s = st.set;
    switch (item) {
        .mp4 => s.format = .mp4,
        .gif => s.format = .gif,
        .mic => s.mic = !s.mic,
        .system => s.system_audio = !s.system_audio,
        .clicks => if (st.overlays) {
            s.clicks = !s.clicks;
        },
        .keys => if (st.overlays) {
            s.keys = !s.keys;
        },
        .record, .close => {},
    }
}

pub fn tooltip(st: *const State, item: Item) []const u8 {
    return switch (item) {
        .record => "Start recording (Enter)",
        .mp4 => "Video (MP4)",
        .gif => "Animated GIF",
        .mic => if (st.set.format == .gif) "Microphone (not in GIFs)" else "Microphone",
        .system => if (st.set.format == .gif) "System sound (not in GIFs)" else "System sound",
        .clicks => if (st.overlays) "Show clicks" else "Show clicks: GNOME with Shotlet's integration only",
        .keys => if (st.overlays) "Show keystrokes" else "Show keystrokes: GNOME with Shotlet's integration only",
        .close => "Cancel (Esc)",
    };
}

fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

const bg: u32 = 0xFF1F1F23;
const fg: u32 = 0xFFF5F5F7;
const dim: u32 = 0xFF6E6E76;
const hov: u32 = 0xFF34343A;
const on_bg: u32 = 0xFF3A3A42;
const accent: u32 = 0xFFFF453A;

/// Paint the bar at buffer x, y (scale k) onto an opaque canvas.
pub fn paint(gpa: std.mem.Allocator, canvas: *render.Canvas, x: i32, y: i32, k: f64, st: *const State) void {
    const sz = size();
    const cw: u32 = @intCast(sc(sz[0], k));
    const ch: u32 = @intCast(sc(sz[1], k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    @memset(card, bg);
    var cv = render.Canvas.init(card, cw, ch);
    for (items) |it| paintItem(&cv, k, st, it.item);
    fui.placeCard(canvas.px, @intCast(canvas.w), @intCast(canvas.h), card, cw, ch, x, y, @intCast(sc(14, k)), @intCast(sc(10, k)));
    if (st.hover) |hv| paintTip(canvas, x, y + @as(i32, @intCast(ch)) + sc(6, k), k, tooltip(st, hv));
}

fn paintItem(cv: *render.Canvas, k: f64, st: *const State, item: Item) void {
    const r0 = rectOf(item);
    const r: Rect = .{ .x = sc(r0.x, k), .y = sc(r0.y, k), .w = sc(r0.w, k), .h = sc(r0.h, k) };
    const s = st.set;
    const on = switch (item) {
        .mp4 => s.format == .mp4,
        .gif => s.format == .gif,
        .mic => s.mic,
        .system => s.system_audio,
        .clicks => s.clicks and st.overlays,
        .keys => s.keys and st.overlays,
        else => false,
    };
    const disabled = switch (item) {
        .clicks, .keys => !st.overlays,
        .mic, .system => s.format == .gif,
        else => false,
    };
    if (item == .record) {
        cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 9 * k, if (st.hover == .record) 0xFFFF6259 else accent);
        cv.fillCircleAA(@as(f64, @floatFromInt(r.x)) + 16 * k, @as(f64, @floatFromInt(r.y + @divTrunc(r.h, 2))), 5 * k, fg);
        const fs = 13 * k;
        text.drawStyled(cv, r.x + sc(28, k), r.y + @divTrunc(r.h - text.heightStyled(fs, .bold), 2), fs, fg, .bold, "Record");
        return;
    }
    if (on) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 9 * k, on_bg) else if (st.hover == item) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 9 * k, hov);
    const col = if (disabled) dim else fg;
    const cx = r.x + @divTrunc(r.w, 2);
    const cy = r.y + @divTrunc(r.h, 2);
    const is = sc(18, k);
    switch (item) {
        .mp4, .gif => {
            const fs = 12 * k;
            const label = if (item == .mp4) "MP4" else "GIF";
            const tw = text.widthStyled(fs, .bold, label);
            text.drawStyled(cv, cx - @divTrunc(tw, 2), cy - @divTrunc(text.heightStyled(fs, .bold), 2), fs, if (on) fg else 0xFFA1A1AA, .bold, label);
        },
        .mic => glyphs.drawCentered(cv, .mic, cx, cy, is, col),
        .system => glyphs.drawCentered(cv, .speaker, cx, cy, is, col),
        .clicks => glyphs.drawCentered(cv, .click, cx, cy, is, col),
        .keys => icons.drawCentered(cv, .keyboard, cx, cy, is, col),
        .close => icons.drawCentered(cv, .close, cx, cy, sc(16, k), col),
        .record => {},
    }
}

fn paintTip(canvas: *render.Canvas, x: i32, y: i32, k: f64, s: []const u8) void {
    const fs = 12 * k;
    const w = text.width(fs, s) + sc(16, k);
    const th = text.height(fs) + sc(10, k);
    canvas.fillRoundRectAA(x, y, w, th, 7 * k, 0xF01F1F23);
    text.draw(canvas, x + sc(8, k), y + sc(5, k), fs, fg, s);
}

test "bar items do not overlap and hit back" {
    for (items) |it| {
        const r = rectOf(it.item);
        try std.testing.expectEqual(@as(?Item, it.item), hit(r.x + 2, r.y + 2));
    }
    try std.testing.expect(hit(0, 0) == null);
    var s: settings_mod.Settings = .{};
    var st: State = .{ .set = &s, .overlays = false };
    toggle(&st, .gif);
    toggle(&st, .clicks);
    try std.testing.expect(s.format == .gif and !s.clicks);
    st.overlays = true;
    toggle(&st, .clicks);
    try std.testing.expect(s.clicks);
}
