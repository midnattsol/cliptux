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
    if (c.menu) {
        drawMenu(self, &cv, c, i, r, k);
    } else if ((hovered or focused) and !dragged) {
        cv.fillRect(0, 0, r.w, r.h, fui.veil);
        const fo: ?Control = if (focused) self.focus.?.control else null;
        const hv: ?Control = if (hovered) self.hover.?.control else null;
        drawRoundButtons(self, &cv, c, fo, hv, k);
        drawPills(self, &cv, fo, hv, k);
    }
    if (c.notice.len > 0) drawNotice(&cv, c.notice, r, k);
    try composite(self, dst, card, r, cardAlpha(c, now, dragged), k);
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

/// Copy and Save: pills along the bottom.
fn drawPills(self: *const Quick, cv: *Canvas, fo: ?Control, hv: ?Control, k: f64) void {
    for ([_]Control{ .copy, .save }) |ctl| {
        const cr = layout.controlRect(ctl);
        const rr: Rect = .{ .x = sc(cr.x, k), .y = sc(cr.y, k), .w = sc(cr.w, k), .h = sc(cr.h, k) };
        cv.fillRoundRectAA(rr.x, rr.y, rr.w, rr.h, 8 * k, if (hv == ctl) fui.pill_hover else fui.pill);
        fui.textCentered(cv, rr, 13 * k, fui.pill_text, .bold, if (ctl == .copy) "Copy" else "Save");
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
