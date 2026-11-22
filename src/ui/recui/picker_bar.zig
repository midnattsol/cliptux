//! The record picker's bar (picker.zig), in the editor toolbar's look
//! (ui/barkit.zig, the theme's metrics and colours): Glass over the
//! blurred desktop, in logical pixels relative to the bar.
//!
//!   [ MP4 GIF ] | 🎙 🔊 | click keys | × [ ● Record ]
//!
//! Clicks and keystrokes are drawn by the GNOME Shell extension; without
//! it those two are greyed and say so.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const effects = @import("../../gfx/effects.zig");
const text = @import("../../gfx/text.zig");
const icons = @import("../icons.zig");
const glyphs = @import("glyphs.zig");
const theme = @import("../theme.zig");
const barkit = @import("../barkit.zig");
const shapes = @import("../shapes.zig");
const settings_mod = @import("../../record/settings.zig");
const Rect = shapes.Rect;

pub const Item = enum { mp4, gif, mic, system, clicks, keys, close, record };

pub const State = struct {
    set: *settings_mod.Settings,
    /// clicks and keystrokes can be shown (the GNOME integration records)
    overlays: bool,
    th: theme.Theme,
    hover: ?Item = null,
};

const pad: i32 = @intFromFloat(theme.bar_pad);
const gap: i32 = @intFromFloat(theme.bar_gap);
const btn: i32 = @intFromFloat(theme.button);
const sep_w: i32 = 1 + 2 * @as(i32, @intFromFloat(theme.sep_margin));
const h = 2 * pad + btn;
const hf: f64 = @floatFromInt(h);

/// Items in order, by group (a separator between groups).
const order = [_]struct { item: Item, group: u8 }{
    .{ .item = .mp4, .group = 0 },
    .{ .item = .gif, .group = 0 },
    .{ .item = .mic, .group = 1 },
    .{ .item = .system, .group = 1 },
    .{ .item = .clicks, .group = 2 },
    .{ .item = .keys, .group = 2 },
    .{ .item = .close, .group = 3 },
    .{ .item = .record, .group = 3 },
};

const Layout = struct {
    x: [order.len]i32 = undefined,
    w: [order.len]i32 = undefined,
    seps: [3]i32 = undefined,
    width: i32 = 0,
};

fn itemWidth(item: Item) i32 {
    return switch (item) {
        .mp4, .gif => text.width(theme.font_label, formatLabel(item)) + 20,
        .record => barkit.primaryWidth(1, "Record"),
        else => btn,
    };
}

fn layout() Layout {
    var l: Layout = .{};
    var x = pad;
    var n_seps: usize = 0;
    for (order, 0..) |o, i| {
        if (i > 0) {
            if (o.group != order[i - 1].group) {
                l.seps[n_seps] = x + gap + @as(i32, @intFromFloat(theme.sep_margin));
                n_seps += 1;
                x += gap + sep_w + gap;
            } else x += gap;
        }
        l.x[i] = x;
        l.w[i] = itemWidth(o.item);
        x += l.w[i];
    }
    l.width = x + pad;
    return l;
}

pub fn size() [2]i32 {
    return .{ layout().width, h };
}

fn rectOf(l: *const Layout, item: Item) Rect {
    for (order, 0..) |o, i| if (o.item == item) return .{ .x = l.x[i], .y = pad, .w = l.w[i], .h = btn };
    unreachable;
}

pub fn hit(lx: i32, ly: i32) ?Item {
    const l = layout();
    for (order) |o| {
        const r = rectOf(&l, o.item);
        if (lx >= r.x and ly >= r.y and lx < r.x + r.w and ly < r.y + r.h) return o.item;
    }
    return null;
}

/// What an item does to the settings (the caller handles .record and
/// .close).
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

fn formatLabel(item: Item) []const u8 {
    return if (item == .mp4) "MP4" else "GIF";
}

fn isOn(st: *const State, item: Item) bool {
    const s = st.set;
    return switch (item) {
        .mp4 => s.format == .mp4,
        .gif => s.format == .gif,
        .mic => s.mic,
        .system => s.system_audio,
        .clicks => s.clicks and st.overlays,
        .keys => s.keys and st.overlays,
        else => false,
    };
}

fn isDisabled(st: *const State, item: Item) bool {
    return switch (item) {
        .clicks, .keys => !st.overlays,
        .mic, .system => st.set.format == .gif,
        else => false,
    };
}

fn sc(v: f64, k: f64) i32 {
    return @intFromFloat(@round(v * k));
}

fn scr(r: Rect, k: f64) Rect {
    const f = struct {
        fn f(v: i32) f64 {
            return @floatFromInt(v);
        }
    }.f;
    return .{ .x = sc(f(r.x), k), .y = sc(f(r.y), k), .w = sc(f(r.w), k), .h = sc(f(r.h), k) };
}

/// Paint the bar at buffer x, y (scale k) onto an opaque canvas.
pub fn paint(gpa: std.mem.Allocator, canvas: *render.Canvas, x: i32, y: i32, k: f64, st: *const State) void {
    const l = layout();
    const th = st.th;
    const cw: u32 = @intCast(sc(@floatFromInt(l.width), k));
    const ch: u32 = @intCast(sc(hf, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    glass(gpa, canvas, x, y, card, cw, ch, k, th);
    var cv = render.Canvas.init(card, cw, ch);
    const sep_y = sc((hf - theme.sep_h) / 2, k);
    for (l.seps) |sx| barkit.separator(&cv, sc(@floatFromInt(sx), k), sep_y, sc(theme.sep_h, k), th);
    for (order) |o| paintItem(&cv, k, st, o.item, scr(rectOf(&l, o.item), k));
    const rad = theme.bar_radius * k;
    shapes.roundRectRing(&cv, .{ .x = 0, .y = 0, .w = @intCast(cw), .h = @intCast(ch) }, rad, 1, th.hairline);
    // the editor's bar shadow, a little tighter (a plain drop shadow)
    const sh = th.bar_shadow;
    const r: effects.Rect = .{ .x = x, .y = y, .w = @intCast(cw), .h = @intCast(ch) };
    effects.dropShadow(canvas.px, @intCast(canvas.w), @intCast(canvas.h), r, @intCast(sc(sh.blur * 0.6, k)), sc(sh.dy * 0.6, k), sh.color);
    effects.blitRounded(canvas.px, @intCast(canvas.w), @intCast(canvas.h), card, cw, ch, x, y, @intFromFloat(@round(rad)));
    if (st.hover) |hv| paintTip(canvas, x, y + @as(i32, @intCast(ch)) + sc(8, k), k, th, tooltip(st, hv));
}

/// The bar's material: what lies behind it, blurred and tinted.
fn glass(gpa: std.mem.Allocator, canvas: *const render.Canvas, x: i32, y: i32, card: []u32, cw: u32, ch: u32, k: f64, th: theme.Theme) void {
    for (0..ch) |yy| for (0..cw) |xx| {
        const sx = x + @as(i32, @intCast(xx));
        const sy = y + @as(i32, @intCast(yy));
        const inside = sx >= 0 and sy >= 0 and sx < canvas.w and sy < canvas.h;
        card[yy * cw + xx] = if (inside) canvas.px[@as(usize, @intCast(sy)) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(sx))] else th.material_solid;
    };
    const rad: u32 = @intCast(@max(2, sc(theme.backdrop_blur / 2, k)));
    effects.softBlur(gpa, card, cw, ch, .{ .x = 0, .y = 0, .w = @intCast(cw), .h = @intCast(ch) }, rad) catch {};
    for (card) |*p| p.* = render.Canvas.blendPixel(p.*, th.material) | 0xFF000000;
}

fn paintItem(cv: *render.Canvas, k: f64, st: *const State, item: Item, r: Rect) void {
    const th = st.th;
    const hover: f64 = if (st.hover == item) 1 else 0;
    if (item == .record) {
        const red = theme.mix(theme.destructive_fill, theme.destructive_fill_hover, hover);
        barkit.primary(cv, r, k, red, th.on_accent, .dot, "Record");
        return;
    }
    const disabled = isDisabled(st, item);
    const look: barkit.Look = if (isOn(st, item)) .toggled else .plain;
    barkit.fill(cv, r, k, th, look, if (disabled) 0 else hover);
    const col = barkit.ink(th, look, disabled);
    const cx = r.x + @divTrunc(r.w, 2);
    const cy = r.y + @divTrunc(r.h, 2);
    const is = sc(theme.icon, k);
    switch (item) {
        .mp4, .gif => {
            const fs = theme.font_label * k;
            const label = formatLabel(item);
            text.draw(cv, cx - @divTrunc(text.width(fs, label), 2), cy - @divTrunc(text.height(fs), 2), fs, col, label);
        },
        .mic => glyphs.drawCentered(cv, .mic, cx, cy, is, col),
        .system => glyphs.drawCentered(cv, .speaker, cx, cy, is, col),
        .clicks => glyphs.drawCentered(cv, .click, cx, cy, is, col),
        .keys => icons.drawCentered(cv, .keyboard, cx, cy, is, col),
        .close => icons.drawCentered(cv, .close, cx, cy, is, col),
        .record => {},
    }
}

/// A tooltip as the editor draws them.
fn paintTip(canvas: *render.Canvas, x: i32, y: i32, k: f64, th: theme.Theme, s: []const u8) void {
    const fs = theme.font_small * k;
    const w = text.width(fs, s) + sc(20, k);
    const tip_h = text.height(fs) + sc(8, k);
    canvas.fillRoundRectAA(x, y + sc(2, k), w, tip_h, 7 * k, 0x1F000000);
    canvas.fillRoundRectAA(x, y, w, tip_h, 7 * k, th.pill_bg);
    text.draw(canvas, x + sc(10, k), y + sc(4, k), fs, th.pill_fg, s);
}

test "bar items do not overlap and hit back" {
    const l = layout();
    for (order, 0..) |o, i| {
        const r = rectOf(&l, o.item);
        try std.testing.expectEqual(@as(?Item, o.item), hit(r.x + 2, r.y + 2));
        if (i > 0) try std.testing.expect(r.x >= l.x[i - 1] + l.w[i - 1]);
    }
    try std.testing.expect(hit(0, 0) == null);
    try std.testing.expectEqual(@as(i32, 46), size()[1]);
    var s: settings_mod.Settings = .{};
    var st: State = .{ .set = &s, .overlays = false, .th = theme.Theme.get(true, null) };
    toggle(&st, .gif);
    toggle(&st, .clicks);
    try std.testing.expect(s.format == .gif and !s.clicks);
    try std.testing.expect(isDisabled(&st, .mic));
    st.overlays = true;
    toggle(&st, .clicks);
    try std.testing.expect(s.clicks);
}
