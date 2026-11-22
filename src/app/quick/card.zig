//! Drawing the quick access thumbnails: each card (its picture, the
//! controls while hovered or focused, or its menu, and a notice) with a
//! shadow, faded as a whole; and the GNOME hint above the stack.

const std = @import("std");
const keep = @import("../keep.zig");
const sys = @import("../../platform/sys.zig");
const png = @import("../../gfx/png.zig");
const text = @import("../../gfx/text.zig");
const shapes = @import("../../ui/shapes.zig");
const fui = @import("../../ui/floatui.zig");
const effects = @import("../../gfx/effects.zig");
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Card = stack.Card;
const Control = layout.Control;
const Canvas = fui.Canvas;
const Rect = shapes.Rect;
const card_w = layout.card_w;
const card_h = layout.card_h;
const pad = layout.pad;

pub fn render(self: *Quick) !void {
    if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
    self.dirty = false;
    const px = try self.win.backBuffer();
    const bw = self.win.width;
    const bh = self.win.height;
    @memset(px, 0);
    const k = self.f();
    const now = sys.monoMs();
    const lh: i32 = @intCast(self.size[1]);
    for (self.cards.items) |*c| if (c.born_ms == 0) {
        c.born_ms = now;
    };
    var i = self.cards.items.len;
    while (i > 0) {
        i -= 1;
        const r = layout.cardRect(i, lh);
        try drawCard(self, .{ .px = px, .w = bw, .h = bh }, i, .{
            .x = sc(r.x, k),
            .y = sc(r.y, k),
            .w = sc(card_w, k),
            .h = sc(card_h, k),
        }, now);
    }
    if (self.hint) drawHint(self, px, bw, bh);
    fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
    try self.win.present();
    // committed (the cards fade in from it): the editor may go. Not on
    // its frame callback: mutter holds those back while the editor
    // still covers the window.
    self.signalReady();
}

fn drawHint(self: *Quick, px: []u32, bw: u32, bh: u32) void {
    const k = self.f();
    const r: Rect = .{ .x = sc(pad, k), .y = sc(pad, k), .w = sc(card_w, k), .h = sc(layout.hint_h - layout.gap, k) };
    // an opaque pill drawn through a card buffer
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    const buf = self.gpa.alloc(u32, @as(usize, w) * h) catch return;
    defer self.gpa.free(buf);
    @memset(buf, 0xF0202024);
    var cv = Canvas.init(buf, w, h);
    const hovered = if (self.hover) |hv| hv.control == .hint else false;
    text.draw(&cv, sc(10, k), sc(5, k), 12 * k, 0xFFD0D0D6, self.hint_text);
    text.drawStyled(&cv, sc(10, k), sc(21, k), 12 * k, if (hovered) 0xFF64B0FF else 0xFF409CFF, .bold, self.hint_link);
    fui.placeCard(px, bw, bh, buf, w, h, r.x, r.y, @intCast(sc(10, k)), @intCast(sc(8, k)));
}

/// The window's back buffer.
const Target = struct { px: []u32, w: u32, h: u32 };

/// Card i at r (buffer pixels).
fn drawCard(self: *Quick, dst: Target, i: usize, r: Rect, now: i64) !void {
    const c = &self.cards.items[i];
    const k = self.f();
    const cw: u32 = @intCast(r.w);
    const ch: u32 = @intCast(r.h);
    try ensureScaled(self.gpa, c, cw, ch);
    const card = try self.gpa.alloc(u32, @as(usize, cw) * ch);
    defer self.gpa.free(card);
    @memcpy(card, c.scaled);
    var cv = Canvas.init(card, cw, ch);
    const hovered = if (self.hover) |h| h.card == i and h.control != .hint else false;
    const focused = if (self.focus) |fo| fo.card == i else false;
    const dragged = self.dragging == i;
    // the controls fade in and out with the hover, the status the other way
    c.hov.to(if ((hovered or focused) and !dragged and !c.menu) 1 else 0, now);
    const shown = c.hov.at(now);
    if (c.menu) {
        drawMenu(self, &cv, c, i, r, k);
    } else {
        if (shown < 1) drawStatus(&cv, c, k);
        if (shown > 0) try drawControls(self, card, cw, ch, i, .{ .hovered = hovered, .focused = focused }, shown);
    }
    if (c.notice.len > 0) drawNotice(&cv, c.notice, r, k);
    try composite(self, dst, card, r, cardAlpha(c, now, dragged), k);
}

/// The veil, the round buttons and the bottom pills over the picture,
/// mixed into `card` at `shown` (0..1).
fn drawControls(self: *Quick, card: []u32, cw: u32, ch: u32, i: usize, on: struct { hovered: bool, focused: bool }, shown: f64) !void {
    const c = &self.cards.items[i];
    const k = self.f();
    const deco = try self.gpa.dupe(u32, c.scaled);
    defer self.gpa.free(deco);
    var dv = Canvas.init(deco, cw, ch);
    dv.fillRect(0, 0, @intCast(cw), @intCast(ch), fui.veil);
    const fo: ?Control = if (on.focused) self.focus.?.control else null;
    const hv: ?Control = if (on.hovered) self.hover.?.control else null;
    drawRoundButtons(self, &dv, c, fo, hv, k);
    drawPills(self, &dv, layout.pillActions(c.meta.saved.len > 0), fo, hv, k);
    effects.mixRows(card, card, deco, @intFromFloat(@round(shown * 256)));
}

/// What happened to the capture, along the bottom: "Copied" or
/// "Saved · NAME".
fn drawStatus(cv: *Canvas, c: *const Card, k: f64) void {
    const saved = c.meta.saved;
    var buf: [300]u8 = undefined;
    var cut: [300]u8 = undefined;
    const label = if (saved.len == 0) "Copied" else blk: {
        const name = saved[(std.mem.lastIndexOfScalar(u8, saved, '/') orelse return) + 1 ..];
        break :blk std.fmt.bufPrint(&buf, "Saved \u{00B7} {s}", .{name}) catch "Saved";
    };
    const fs = 12 * k;
    const icon_w = sc(14, k);
    const max_w = sc(card_w - 16 - 24, k) - icon_w;
    const shown = fui.ellipsize(&cut, fs, label, max_w);
    const h = sc(24, k);
    const w = text.widthStyled(fs, .bold, shown) + icon_w + sc(22, k);
    const x = sc(8, k);
    const y = @as(i32, @intCast(cv.h)) - h - sc(8, k);
    cv.fillRoundRectAA(x, y, w, h, @as(f64, @floatFromInt(h)) / 2, 0xB8000000);
    fui.icon(cv, .check, @as(f64, @floatFromInt(x + sc(9, k))) + @as(f64, @floatFromInt(icon_w)) / 2, @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(h)) / 2, 14 * k, fui.white);
    text.drawStyled(cv, x + sc(13, k) + icon_w, y + @divTrunc(h - text.heightStyled(fs, .bold), 2), fs, fui.white, .bold, shown);
}

/// The card's picture, scaled once per size.
fn ensureScaled(gpa: std.mem.Allocator, c: *Card, cw: u32, ch: u32) !void {
    if (c.scaled_w == cw and c.scaled_h == ch) return;
    gpa.free(c.scaled);
    c.scaled = &.{};
    c.scaled = try gpa.alloc(u32, @as(usize, cw) * ch);
    c.scaled_w = cw;
    c.scaled_h = ch;
    const cov = try coverScaled(gpa, c.thumb, cw, ch);
    defer gpa.free(cov.pixels);
    fui.drawImageFill(c.scaled, cw, ch, cov.pixels, cov.width, cov.height);
}

fn drawMenu(self: *const Quick, cv: *Canvas, c: *const Card, i: usize, r: Rect, k: f64) void {
    cv.fillRect(0, 0, r.w, r.h, 0xB8000000);
    const top = sc(layout.menuTop(), k);
    for (layout.menu_items, 0..) |item, j| {
        const row: Rect = .{ .x = sc(8, k), .y = top + sc(@as(i32, @intCast(j)) * layout.menu_row, k), .w = sc(card_w - 16, k), .h = sc(layout.menu_row, k) };
        const on = if (self.hover) |h| h.card == i and h.control == .menu and h.item == j else false;
        if (on) cv.fillRoundRectAA(row.x, row.y, row.w, row.h, 5 * k, 0x40FFFFFF);
        const dim = item.action == .annotate and !c.editable;
        text.draw(cv, row.x + sc(10, k), row.y + @divTrunc(row.h - text.height(12.5 * k), 2), 12.5 * k, if (dim) 0x80FFFFFF else fui.white, item.label);
    }
}

/// Close, Annotate and Pin: round buttons along the top.
fn drawRoundButtons(self: *const Quick, cv: *Canvas, c: *const Card, fo: ?Control, hv: ?Control, k: f64) void {
    for ([_]Control{ .close, .annotate, .pin }) |ctl| {
        const cr = layout.controlRect(ctl);
        const cx = (@as(f64, @floatFromInt(cr.x)) + 13) * k;
        const cy = (@as(f64, @floatFromInt(cr.y)) + 13) * k;
        const dim = ctl == .annotate and !c.editable;
        cv.fillCircleAA(cx, cy, 13 * k, if (hv == ctl and !dim) fui.btn_round_hover else fui.btn_round);
        const ic: fui.Icon = switch (ctl) {
            .close => .close,
            .annotate => .pencil,
            else => .pin,
        };
        fui.icon(cv, ic, cx, cy, 14 * k, if (dim) 0x80FFFFFF else fui.white);
        if (fo == ctl) cv.ringAA(cx, cy, 15 * k, 2 * k, self.accent);
    }
}

/// The two pills along the bottom: the primary one in the accent.
fn drawPills(self: *const Quick, cv: *Canvas, acts: [2]layout.Action, fo: ?Control, hv: ?Control, k: f64) void {
    for ([_]Control{ .primary, .secondary }, acts) |ctl, a| {
        const cr = layout.controlRect(ctl);
        const rr: Rect = .{ .x = sc(cr.x, k), .y = sc(cr.y, k), .w = sc(cr.w, k), .h = sc(cr.h, k) };
        const primary = ctl == .primary;
        const bg = if (primary) self.accent else if (hv == ctl) fui.pill_hover else fui.pill;
        cv.fillRoundRectAA(rr.x, rr.y, rr.w, rr.h, 8 * k, if (primary and hv == ctl) effects.over(bg, 0x24FFFFFF) else bg);
        fui.textCentered(cv, rr, @as(f64, if (a == .show_in_files) 12 else 13) * k, if (primary) fui.white else fui.pill_text, .bold, a.label());
        if (fo == ctl) shapes.roundRectRing(cv, .{ .x = rr.x - sc(2, k), .y = rr.y - sc(2, k), .w = rr.w + sc(4, k), .h = rr.h + sc(4, k) }, 10 * k, 2 * k, self.accent);
    }
}

fn drawNotice(cv: *Canvas, s: []const u8, r: Rect, k: f64) void {
    const tw = text.widthStyled(13 * k, .bold, s) + sc(28, k);
    const nh = sc(30, k);
    const nr: Rect = .{ .x = @divTrunc(r.w - tw, 2), .y = @divTrunc(r.h - nh, 2), .w = tw, .h = nh };
    cv.fillRoundRectAA(nr.x, nr.y, nr.w, nr.h, 15 * k, 0xE6000000);
    fui.textCentered(cv, nr, 13 * k, fui.white, .bold, s);
}

/// The card's opacity: fading in, fading out, or half while dragged.
fn cardAlpha(c: *const Card, now: i64, dragged: bool) f64 {
    var alpha: f64 = 1;
    if (now - c.born_ms < stack.fade_in_ms) alpha = @as(f64, @floatFromInt(now - c.born_ms)) / stack.fade_in_ms;
    if (c.fade_from != 0) alpha = @min(alpha, 1 - @as(f64, @floatFromInt(now - c.fade_from)) / stack.fade_ms);
    if (dragged) alpha = @min(alpha, 0.5);
    return alpha;
}

/// Shadow and card into a scratch layer so it can fade as a whole, then
/// over the back buffer.
fn composite(self: *Quick, dst: Target, card: []const u32, r: Rect, alpha: f64, k: f64) !void {
    const cw: u32 = @intCast(r.w);
    const ch: u32 = @intCast(r.h);
    const sp: i32 = sc(pad, k);
    const tw: u32 = cw + @as(u32, @intCast(2 * sp));
    const th: u32 = ch + @as(u32, @intCast(2 * sp));
    const layer = try self.gpa.alloc(u32, @as(usize, tw) * th);
    defer self.gpa.free(layer);
    @memset(layer, 0);
    fui.placeCard(layer, tw, th, card, cw, ch, sp, sp, @intCast(sc(12, k)), @intCast(sc(20, k)));
    fui.fadeAlpha(layer, @max(0, alpha));
    fui.blitOver(dst.px, dst.w, dst.h, layer, tw, th, r.x - sp, r.y - sp);
}

pub fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

/// The thumbnail box-filtered to the size it is drawn at in a w x h box
/// (cover, or contain for very different shapes: see drawImageFill).
pub fn coverScaled(gpa: std.mem.Allocator, t: png.Image, w: u32, h: u32) !keep.Pixels {
    const ar_src = @as(f64, @floatFromInt(t.width)) / @as(f64, @floatFromInt(t.height));
    const ar_dst = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const ratio = ar_src / ar_dst;
    const cover = ratio > 0.7 and ratio < 1.4;
    const fw = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(t.width));
    const fh = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(t.height));
    const s = if (cover) @max(fw, fh) else @min(fw, fh);
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.width)) * s))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.height)) * s))));
    const out = try gpa.alloc(u32, @as(usize, dw) * dh);
    keep.scaleInto(t.pixels, t.width, t.height, out, dw, dh);
    return .{ .pixels = out, .width = dw, .height = dh };
}
