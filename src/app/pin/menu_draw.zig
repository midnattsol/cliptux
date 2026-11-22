//! Drawing the pin's menu as the editor draws its menus (ui/theme.zig's
//! menu metrics and colours): the material (opaque: a client cannot
//! blur what lies behind it), a hairline edge and a soft shadow, rows
//! with an icon, a label and their shortcut, the accent under the hot
//! row, and the opacity as a segmented control. It fades and grows in
//! from 96% from its corner at the pointer, and fades out when closed.

const std = @import("std");
const text = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const theme = @import("../../ui/theme.zig");
const icons = @import("../../ui/icons.zig");
const fui = @import("../../ui/floatui.zig");
const Rect = @import("../../ui/shapes.zig").Rect;
const menu = @import("menu.zig");
const view = @import("view.zig");
const state = @import("state.zig");

const Theme = theme.Theme;

/// What the rows show beside the layout.
pub const Marks = struct { locked: bool, opacity: view.Opacity };

/// The menu `st` onto the straight-alpha surface `px` (bw x bh) at scale k.
pub fn draw(gpa: std.mem.Allocator, px: []u32, bw: u32, bh: u32, k: f64, th: Theme, st: *const menu.State, marks: Marks, now: i64) !void {
    const a = st.shown.at(now);
    if (a <= 0.001) return;
    const f = k * (0.96 + 0.04 * a);
    const sz = st.lay.size();
    const mw: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(sz[0])) * f));
    const mh: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(sz[1])) * f));
    const card = try gpa.alloc(u32, @as(usize, mw) * mh);
    defer gpa.free(card);
    var cv = fui.Canvas.init(card, mw, mh);
    const rad = theme.menu_radius * f;
    @memset(card, effects.over(th.material_solid, th.hairline));
    cv.fillRoundRectAA(1, 1, @as(i32, @intCast(mw)) - 2, @as(i32, @intCast(mh)) - 2, rad - 1, th.material_solid);
    drawRows(&cv, f, th, st, marks);
    // the card and its shadow on a layer of their own, faded as one
    const m: u32 = @intFromFloat(@round(state.menu_room * k));
    const lw = mw + 2 * m;
    const lh = mh + 2 * m;
    const layer = try gpa.alloc(u32, @as(usize, lw) * lh);
    defer gpa.free(layer);
    @memset(layer, 0);
    fui.placeCard(layer, lw, lh, card, mw, mh, @intCast(m), @intCast(m), @intFromFloat(rad), @intFromFloat(@round(state.menu_shadow * k)));
    fui.fadeAlpha(layer, a);
    const x: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(st.at[0])) * k));
    const y: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(st.at[1])) * k));
    fui.blitOver(px, bw, bh, layer, lw, lh, x - @as(i32, @intCast(m)), y - @as(i32, @intCast(m)));
}

fn sc(v: i32, f: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * f));
}

fn scaled(r: Rect, f: f64) Rect {
    return .{ .x = sc(r.x, f), .y = sc(r.y, f), .w = sc(r.right(), f) - sc(r.x, f), .h = sc(r.bottom(), f) - sc(r.y, f) };
}

fn drawRows(cv: *fui.Canvas, f: f64, th: Theme, st: *const menu.State, marks: Marks) void {
    const l = &st.lay;
    for (l.seps[0..l.n_seps]) |y| cv.fillRect(sc(menu.pad + 10, f), sc(y, f), sc(menu.width - 2 * menu.pad - 20, f), 1, th.hairline);
    for (l.items[0..l.n], l.rows[0..l.n], 0..) |it, r, i| {
        const hot = st.hot != null and st.hot.? == i;
        if (it == .opacity) {
            drawOpacity(cv, f, th, r, hot, st.hot_seg, marks.opacity);
        } else drawRow(cv, f, th, scaled(r, f), it, hot, marks.locked);
    }
}

/// An item's row: icon, label, shortcut; the accent under it when hot.
fn drawRow(cv: *fui.Canvas, f: f64, th: Theme, r: Rect, it: menu.Item, hot: bool, locked: bool) void {
    if (hot) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 7 * f, th.accent_fill);
    const fg = if (hot) th.on_accent else th.fg;
    const sub = if (hot) theme.withAlpha(th.on_accent, 0xBF) else th.muted;
    const is = sc(16, f);
    icons.draw(cv, it.icon(), r.x + sc(10, f), r.y + @divTrunc(r.h - is, 2), is, fg);
    const fs = theme.font_label * f;
    text.draw(cv, r.x + sc(36, f), r.y + @divTrunc(r.h - text.height(fs), 2), fs, fg, it.label(locked));
    const ks = theme.font_small * f;
    const key = it.key();
    if (key.len > 0) text.draw(cv, r.right() - sc(10, f) - text.width(ks, key), r.y + @divTrunc(r.h - text.height(ks), 2), ks, sub, key);
}

/// "Opacity 1-4" over four segments, the current one raised.
fn drawOpacity(cv: *fui.Canvas, f: f64, th: Theme, row: Rect, hot: bool, hot_seg: ?u2, cur: view.Opacity) void {
    const r = scaled(row, f);
    if (hot and hot_seg == null) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 7 * f, th.hover);
    const ks = theme.font_small * f;
    const head_h = sc(menu.heading_h, f);
    const hy = r.y + @divTrunc(head_h - text.height(ks), 2);
    text.draw(cv, r.x + sc(10, f), hy, ks, th.muted, menu.Item.opacity.label(false));
    text.draw(cv, r.right() - sc(10, f) - text.width(ks, menu.Item.opacity.key()), hy, ks, th.muted, menu.Item.opacity.key());
    const trough = scaled(.{ .x = row.x, .y = row.y + menu.heading_h, .w = row.w, .h = menu.seg_h }, f);
    cv.fillRoundRectAA(trough.x, trough.y, trough.w, trough.h, 9 * f, th.track);
    for (view.Opacity.all, 0..) |o, i| {
        const s = scaled(menu.segment(row, i), f);
        const on = o == cur;
        const under = hot and hot_seg != null and hot_seg.? == i;
        if (on) {
            cv.fillRoundRectAA(s.x, s.y + sc(1, f), s.w, s.h, 7 * f, 0x26000000);
            cv.fillRoundRectAA(s.x, s.y, s.w, s.h, 7 * f, th.seg_on);
        } else if (under) cv.fillRoundRectAA(s.x, s.y, s.w, s.h, 7 * f, th.hover);
        if (under and on) cv.fillRoundRectAA(s.x, s.y, s.w, s.h, 7 * f, th.hover);
        const l = o.label();
        text.draw(cv, s.x + @divTrunc(s.w - text.width(ks, l), 2), s.y + @divTrunc(s.h - text.height(ks), 2), ks, if (on or under) th.fg else th.muted, l);
    }
}
