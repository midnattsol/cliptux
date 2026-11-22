//! The Settings window's drawing kit: boxed-list cards and their rows,
//! switches, chip buttons, steppers, swatches and key caps. Each control
//! records its region so clicks and keyboard focus can find it.

const std = @import("std");
const window = @import("../../platform/api.zig").window;
const render = @import("../../gfx/render.zig");
const config = @import("../../app/config.zig");
const text = @import("../../gfx/text.zig");
const theme_mod = @import("../theme.zig");
const icons = @import("../icons.zig");
const shapes = @import("../shapes.zig");
const model = @import("model.zig");

const Canvas = render.Canvas;
const Window = window.Window;
const Theme = theme_mod.Theme;
const Hit = model.Hit;
const Region = model.Region;

pub const Ui = struct {
    win: *Window,
    c: Canvas,
    f: f64, // display scale
    th: Theme,
    regions: *std.ArrayList(Region),
    alloc: std.mem.Allocator,
    mx: i32,
    my: i32,

    pub fn sc(self: *const Ui, v: f64) i32 {
        return @intFromFloat(@round(v * self.f));
    }
    pub fn fs(self: *const Ui, v: f64) f64 {
        return v * self.f; // font size in px
    }
    pub fn hovered(self: *const Ui, x: i32, y: i32, w: i32, h: i32) bool {
        return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h;
    }
    pub fn add(self: *Ui, r: Region) !void {
        try self.regions.append(self.alloc, r);
    }
    /// Text vertically centred in [y, y + h).
    pub fn label(self: *Ui, x: i32, y: i32, h: i32, size: f64, color: u32, style: text.Style, s: []const u8) void {
        const px = self.fs(size);
        text.drawStyled(&self.c, x, y + @divTrunc(h - text.heightStyled(px, style), 2), px, color, style, s);
    }
    pub fn width(self: *const Ui, size: f64, style: text.Style, s: []const u8) i32 {
        return text.widthStyled(self.fs(size), style, s);
    }
};

/// Layout of a boxed list: rows stacked inside one card.
pub const Card = struct {
    x: i32,
    y: i32,
    w: i32,
    n: usize = 0,
    h: i32 = 0,
};

pub const Row = struct { x: i32, y: i32, w: i32, h: i32 };

/// Fill of a chip-like button, lighter while hovered.
fn chipFill(th: Theme, hov: bool) u32 {
    return if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip;
}

pub fn groupTitle(ui: *Ui, x: i32, y: i32, w: i32, title: []const u8, link: ?[]const u8) !i32 {
    const h = ui.sc(20);
    ui.label(x + ui.sc(2), y, h, 14, ui.th.text, .semibold, title);
    if (link) |l| {
        const lw = ui.width(13, .regular, l);
        const lx = x + w - lw - ui.sc(2);
        const hov = ui.hovered(lx - ui.sc(4), y, lw + ui.sc(8), h);
        ui.label(lx, y, h, 13, if (hov) theme_mod.mix(ui.th.accent_text, ui.th.text, 0.3) else ui.th.accent_text, .regular, l);
        try ui.add(.{ .x = lx - ui.sc(4), .y = y, .w = lw + ui.sc(8), .h = h, .hit = .reset_binds, .radius = 4 });
    }
    return y + h + ui.sc(10);
}

/// A boxed list `h` tall: the card is painted first, rows go on top.
pub fn beginCard(ui: *Ui, x: i32, y: i32, w: i32, h: i32) Card {
    const rad = theme_mod.card_radius * ui.f;
    ui.c.fillRoundRectAA(x - 1, y - 1, w + 2, h + 2, rad + 1, ui.th.line);
    ui.c.fillRoundRectAA(x, y, w, h, rad, ui.th.card | 0xFF000000);
    return .{ .x = x, .y = y, .w = w };
}

/// The next row of `card`, `h` tall, under a separator.
pub fn rowBegin(ui: *Ui, card: *Card, h: i32) Row {
    if (card.n > 0) ui.c.fillRect(card.x, card.y + card.h, card.w, 1, ui.th.line);
    const r = Row{ .x = card.x, .y = card.y + card.h, .w = card.w, .h = h };
    card.n += 1;
    card.h += h;
    return r;
}

pub fn endCard(card: *const Card) i32 {
    return card.y + card.h;
}

pub fn rowTitle(ui: *Ui, r: Row, title: []const u8, subtitle: ?[]const u8) void {
    const x = r.x + ui.sc(16);
    if (subtitle) |s| {
        const t1 = text.height(ui.fs(15));
        const t2 = text.height(ui.fs(13));
        const top = r.y + @divTrunc(r.h - t1 - t2 - ui.sc(2), 2);
        text.draw(&ui.c, x, top, ui.fs(15), ui.th.text, title);
        text.draw(&ui.c, x, top + t1 + ui.sc(2), ui.fs(13), ui.th.text_muted, s);
    } else ui.label(x, r.y, r.h, 15, ui.th.text, .regular, title);
}

pub fn switchRow(ui: *Ui, card: *Card, title: []const u8, subtitle: ?[]const u8, on: bool, hit: Hit) !void {
    const r = rowBegin(ui, card, ui.sc(theme_mod.row_h));
    const th = ui.th;
    rowTitle(ui, r, title, subtitle);
    const sw = ui.sc(theme_mod.switch_w);
    const sh = ui.sc(theme_mod.switch_h);
    const sx = r.x + r.w - ui.sc(16) - sw;
    const sy = r.y + @divTrunc(r.h - sh, 2);
    const hov = ui.hovered(r.x, r.y, r.w, r.h);
    const off = if (hov) theme_mod.mix(th.switch_off, th.text, 0.08) else th.switch_off;
    ui.c.fillRoundRectAA(sx, sy, sw, sh, @as(f64, @floatFromInt(sh)) / 2.0, if (on) (if (hov) th.accent_hover else th.accent) else off);
    const kr = 10.0 * ui.f;
    const kx: f64 = if (on) @as(f64, @floatFromInt(sx + sw)) - 3.0 * ui.f - kr else @as(f64, @floatFromInt(sx)) + 3.0 * ui.f + kr;
    const ky = @as(f64, @floatFromInt(sy)) + @as(f64, @floatFromInt(sh)) / 2.0;
    ui.c.fillCircleAA(kx, ky + 1.0 * ui.f, kr + 0.5 * ui.f, 0x40000000);
    ui.c.fillCircleAA(kx, ky, kr, 0xFFFFFFFF);
    // the whole row toggles
    try ui.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .hit = hit, .radius = 0 });
}

/// `s` shortened from the left with an ellipsis until it fits `max_w`
/// (long paths keep their tail).
fn elideLeft(ui: *const Ui, style: text.Style, s: []const u8, max_w: i32, buf: []u8) []const u8 {
    var shown = s;
    while (ui.width(14, style, shown) > max_w and shown.len > 4) {
        var cut: usize = 1;
        while (cut < shown.len and (shown[cut] & 0xC0) == 0x80) cut += 1;
        const rest = shown[cut..];
        shown = std.fmt.bufPrint(buf, "\u{2026}{s}", .{if (std.mem.startsWith(u8, rest, "\u{2026}")) rest[3..] else rest}) catch rest;
    }
    return shown;
}

/// A chip button on the right of row `r`.
pub fn chipButton(ui: *Ui, r: Row, hit: Hit, icon: ?icons.Icon, label_s: []const u8, bold: bool) !void {
    const th = ui.th;
    const style: text.Style = if (bold) .semibold else .regular;
    const is = ui.sc(16);
    var buf: [300]u8 = undefined;
    const shown = elideLeft(ui, style, label_s, @divTrunc(r.w, 2), &buf);
    const bw = ui.sc(12) + (if (icon != null) is + ui.sc(8) else 0) + ui.width(14, style, shown) + ui.sc(if (icon != null) 12 else 14) + (if (icon == null) ui.sc(2) else 0);
    const bh = ui.sc(34);
    const bx = r.x + r.w - ui.sc(16) - bw;
    const by = r.y + @divTrunc(r.h - bh, 2);
    const hov = ui.hovered(bx, by, bw, bh);
    ui.c.fillRoundRectAA(bx, by, bw, bh, 8 * ui.f, chipFill(th, hov));
    var x = bx + ui.sc(12);
    if (icon) |ic| {
        icons.drawStroke(&ui.c, ic, x, by + @divTrunc(bh - is, 2), is, 2, th.text);
        x += is + ui.sc(8);
    }
    ui.label(x, by, bh, 14, th.text, style, shown);
    try ui.add(.{ .x = bx, .y = by, .w = bw, .h = bh, .hit = hit, .radius = 8 });
}

/// A chip button whose right edge is `right_gap` in from the row's.
pub fn chipButtonAt(ui: *Ui, r: Row, hit: Hit, label_s: []const u8, right_gap: i32) !void {
    const th = ui.th;
    const bw = ui.width(14, .regular, label_s) + ui.sc(28);
    const bh = ui.sc(34);
    const bx = r.x + r.w - right_gap - bw;
    const by = r.y + @divTrunc(r.h - bh, 2);
    const hov = ui.hovered(bx, by, bw, bh);
    ui.c.fillRoundRectAA(bx, by, bw, bh, 8 * ui.f, chipFill(th, hov));
    ui.label(bx + ui.sc(14), by, bh, 14, th.text, .regular, label_s);
    try ui.add(.{ .x = bx, .y = by, .w = bw, .h = bh, .hit = hit, .radius = 8 });
}

pub fn swatchRow(ui: *Ui, r: Row, selected: u3) !void {
    const th = ui.th;
    const d = ui.sc(24);
    const gap = ui.sc(8);
    var x = r.x + r.w - ui.sc(16) - 8 * d - 7 * gap;
    const cy = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2.0;
    for (0..8) |i| {
        const col = shapes.palette[i];
        const rad = @as(f64, @floatFromInt(d)) / 2.0;
        const cxf = @as(f64, @floatFromInt(x)) + rad;
        const hov = ui.hovered(x - @divTrunc(gap, 2), r.y, d + gap, r.h);
        if (i == selected) {
            ui.c.ringAA(cxf, cy, rad + 3.0 * ui.f, 2.0 * ui.f, th.accent);
        } else if (hov) ui.c.ringAA(cxf, cy, rad + 2.5 * ui.f, 1.5 * ui.f, th.switch_off);
        ui.c.fillCircleAA(cxf, cy, rad, col);
        ui.c.ringAA(cxf, cy, rad - 0.5 * ui.f, 1.0 * ui.f, 0x66808080);
        try ui.add(.{ .x = x, .y = @intFromFloat(cy - rad), .w = d, .h = d, .hit = .{ .color = @intCast(i) }, .radius = rad });
        x += d + gap;
    }
}

/// The square - and + buttons of a stepper `bs` wide at x, y, with
/// `val_w` between them for the value.
fn stepButtons(ui: *Ui, x: i32, by: i32, bs: i32, val_w: i32, minus: Hit, plus: Hit) !void {
    const th = ui.th;
    for ([_]Hit{ minus, plus }, 0..) |hit, i| {
        const bx = if (i == 0) x else x + bs + val_w;
        const hov = ui.hovered(bx, by, bs, bs);
        ui.c.fillRoundRectAA(bx, by, bs, bs, 8 * ui.f, chipFill(th, hov));
        const is = ui.sc(16);
        // minus: the plus icon's horizontal stroke only
        if (i == 0) {
            ui.c.fillRoundRectAA(bx + @divTrunc(bs - is, 2) + ui.sc(2), by + @divTrunc(bs, 2) - ui.sc(1), is - ui.sc(4), @max(2, ui.sc(2)), 1, th.text);
        } else icons.drawStroke(&ui.c, .plus, bx + @divTrunc(bs - is, 2), by + @divTrunc(bs - is, 2), is, 2, th.text);
        try ui.add(.{ .x = bx, .y = by, .w = bs, .h = bs, .hit = hit, .radius = 8 });
    }
}

pub fn sizeStepper(ui: *Ui, r: Row, value: i32, color: u32) !void {
    const bs = ui.sc(34);
    const val_w = ui.sc(64);
    var x = r.x + r.w - ui.sc(16) - 2 * bs - val_w;
    const by = r.y + @divTrunc(r.h - bs, 2);
    try stepButtons(ui, x, by, bs, val_w, .th_minus, .th_plus);
    x += bs;
    // a dot as thick as the stroke, and the number
    const cy = @as(f64, @floatFromInt(by)) + @as(f64, @floatFromInt(bs)) / 2.0;
    const dot = @min(9.0 * ui.f, @max(1.5, @as(f64, @floatFromInt(value)) * ui.f / 2.0));
    ui.c.fillCircleAA(@as(f64, @floatFromInt(x + ui.sc(16))), cy, dot, color);
    if ((color & 0xFFFFFF) == 0xFFFFFF or (color & 0xFFFFFF) == 0x1C1C1E) ui.c.ringAA(@as(f64, @floatFromInt(x + ui.sc(16))), cy, dot, 1.0, 0x66808080);
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "?";
    ui.label(x + ui.sc(32), by, bs, 15, ui.th.text, text.Style.regular.num(), label);
}

/// - value + on the right of row `r`.
pub fn valueStepper(ui: *Ui, r: Row, value: []const u8, minus: Hit, plus: Hit) !void {
    const bs = ui.sc(34);
    const val_w = @max(ui.sc(64), ui.width(15, text.Style.regular.num(), value) + ui.sc(20));
    const x = r.x + r.w - ui.sc(16) - 2 * bs - val_w;
    const by = r.y + @divTrunc(r.h - bs, 2);
    try stepButtons(ui, x, by, bs, val_w, minus, plus);
    const tw = ui.width(15, text.Style.regular.num(), value);
    ui.label(x + bs + @divTrunc(val_w - tw, 2), by, bs, 15, ui.th.text, text.Style.regular.num(), value);
}

fn capWidth(ui: *const Ui, k: []const u8) i32 {
    return @max(ui.sc(22), ui.width(13, .semibold, k) + ui.sc(16));
}

/// Key caps right-aligned in row `r`; returns their left edge.
pub fn keyCaps(ui: *Ui, r: Row, caps: []const []const u8, accent: ?u32) i32 {
    const th = ui.th;
    const ch = ui.sc(26);
    const gap = ui.sc(4);
    var total: i32 = -gap;
    for (caps) |k| total += capWidth(ui, k) + gap;
    var x = r.x + r.w - ui.sc(16) - total;
    const left = x;
    const y = r.y + @divTrunc(r.h - ch, 2);
    for (caps) |k| {
        const cw = capWidth(ui, k);
        if (accent) |a| {
            ui.c.fillRoundRectAA(x, y, cw, ch, 6 * ui.f, a);
        } else {
            ui.c.fillRoundRectAA(x, y, cw, ch, 6 * ui.f, th.line);
            ui.c.fillRoundRectAA(x, y, cw, ch - @max(1, ui.sc(1)), 6 * ui.f, th.chip);
        }
        const tw = ui.width(13, .semibold, k);
        ui.label(x + @divTrunc(cw - tw, 2), y, ch, 13, if (accent != null) th.on_accent else th.text, .semibold, k);
        x += cw + gap;
    }
    return left;
}

/// The caps of a binding: Ctrl, Shift, then the key's name.
fn bindCaps(bind: config.Bind, key: []const u8, caps: *[3][]const u8) []const []const u8 {
    var n: usize = 0;
    if (bind.ctrl) {
        caps[n] = "Ctrl";
        n += 1;
    }
    if (bind.shift) {
        caps[n] = "Shift";
        n += 1;
    }
    caps[n] = key;
    n += 1;
    return caps[0..n];
}

pub fn shortcutRow(ui: *Ui, card: *Card, title: []const u8, win: *Window, bind: config.Bind, recording: bool, hit: Hit) !void {
    const r = rowBegin(ui, card, ui.sc(48));
    const th = ui.th;
    if (ui.hovered(r.x, r.y, r.w, r.h) and !recording) {
        ui.c.fillRoundRectAA(r.x + ui.sc(4), r.y + ui.sc(4), r.w - ui.sc(8), r.h - ui.sc(8), 8 * ui.f, theme_mod.fade(th.view_sel, 0.7));
    }
    rowTitle(ui, r, title, null);
    if (recording) {
        _ = keyCaps(ui, r, &.{"Press keys\u{2026}"}, th.accent_fill);
    } else if (bind.code == 0) {
        const s = "Not set";
        ui.label(r.x + r.w - ui.sc(16) - ui.width(13, .regular, s), r.y, r.h, 13, th.text_muted, .regular, s);
    } else {
        var kbuf: [32]u8 = undefined;
        const key = win.kb.keyName(bind.code, &kbuf, config.keyCodeName(bind.code));
        var caps: [3][]const u8 = undefined;
        _ = keyCaps(ui, r, bindCaps(bind, key, &caps), null);
    }
    try ui.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .hit = hit, .radius = 0 });
}
