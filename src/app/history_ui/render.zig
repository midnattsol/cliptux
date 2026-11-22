//! Drawing the "Recent captures" panel: header, search field, the grid
//! of rounded thumbnails with relative times (clipped to its band), the
//! action bar of the picked capture and a passing notice, onto a card
//! with a shadow.

const std = @import("std");
const clock = @import("../clock.zig");
const sys = @import("../../platform/api.zig").sys;
const text = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const shapes = @import("../../ui/shapes.zig");
const fui = @import("../../ui/floatui.zig");
const theme = @import("../../ui/theme.zig");
const layout = @import("layout.zig");
const panel_mod = @import("panel.zig");

const Panel = panel_mod.Panel;
const Item = panel_mod.Item;
const Rect = shapes.Rect;
const Canvas = fui.Canvas;
const panel_w = layout.panel_w;
const pad = layout.pad;
const inset = layout.inset;
const field_h = layout.field_h;
const thumb_h = layout.thumb_h;
const actions_h = layout.actions_h;

/// Logical to buffer pixels.
fn s(v: i32, f: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * f));
}

pub fn render(self: *Panel) !void {
    if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
    self.dirty = false;
    const kk = self.k();
    const px = try self.win.backBuffer();
    const bw = self.win.width;
    const bh = self.win.height;
    @memset(px, 0);
    const pw: u32 = @intFromFloat(@round(panel_w * kk));
    const ph_l = self.panelH();
    const ph: u32 = @min(bh -| @as(u32, @intFromFloat(@round(2 * pad * kk))), @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(ph_l)) * kk))));
    if (ph == 0 or pw == 0) return;
    const panel = try self.gpa.alloc(u32, @as(usize, pw) * ph);
    defer self.gpa.free(panel);
    @memset(panel, self.theme.panel);
    var cv = Canvas.init(panel, pw, ph);

    drawHeader(self, &cv, kk);
    drawSearch(self, &cv, kk);
    try drawGrid(self, panel, pw, ph, kk);
    if (self.selected) |si| {
        drawActions(self, &cv, &self.items.items[si], kk);
    } else if (self.confirm_clear) {
        drawConfirm(self, &cv, kk);
    } else if (self.items.items.len > 0) drawClear(self, &cv, kk);
    if (self.notice.len > 0) drawNotice(self, &cv, pw, ph, kk);

    const o: i32 = @intFromFloat(@round(pad * kk));
    fui.placeCard(px, bw, bh, panel, pw, ph, o, o, @intFromFloat(14 * kk), @intFromFloat(14 * kk));
    fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
    try self.win.present();
}

/// Title and the close button.
fn drawHeader(self: *const Panel, cv: *Canvas, kk: f64) void {
    const th = self.theme;
    text.drawStyled(cv, s(inset, kk), s(inset, kk), 14 * kk, th.fg, .semibold, "Recent captures");
    const xr = self.closeRect();
    const xcx = (@as(f64, @floatFromInt(xr.x)) + 11) * kk;
    const xcy = (@as(f64, @floatFromInt(xr.y)) + 11) * kk;
    if (self.hover_close) cv.fillCircleAA(xcx, xcy, 11 * kk, th.field);
    fui.icon(cv, .close, xcx, xcy, 14 * kk, th.muted);
}

/// The search field; without Tesseract it shows dimmed, takes no typing
/// and says why.
fn drawSearch(self: *const Panel, cv: *Canvas, kk: f64) void {
    const th = self.theme;
    const y = s(self.searchTop(), kk);
    const k: f64 = if (self.searchable) 1 else theme.disabled_alpha;
    cv.fillRoundRectAA(s(inset, kk), y, s(panel_w - 2 * inset, kk), s(field_h, kk), 8 * kk, theme.fade(th.field, k));
    fui.icon(cv, .search, @as(f64, @floatFromInt(inset + 17)) * kk, @as(f64, @floatFromInt(y)) + 16 * kk, 14 * kk, theme.fade(th.muted, k));
    const ty = y + @divTrunc(s(field_h, kk) - text.height(13 * kk), 2);
    if (self.search.items.len == 0) {
        const hint = if (self.searchable) "Search text in captures" else "Search needs Tesseract (not installed)";
        // the reason stays legible: it is all the field has to say
        text.draw(cv, s(inset + 32, kk), ty, 13 * kk, th.muted, hint);
    } else {
        text.draw(cv, s(inset + 32, kk), ty, 13 * kk, th.fg, self.search.items);
    }
}

/// The grid, drawn into its own band-sized buffer (so it clips) and
/// copied into the panel.
fn drawGrid(self: *Panel, panel: []u32, pw: u32, ph: u32, kk: f64) !void {
    const th = self.theme;
    const top = s(self.gridTop(), kk);
    const view_h = s(self.gridViewH(), kk);
    const grid = try self.gpa.alloc(u32, @as(usize, pw) * @as(usize, @intCast(@max(1, view_h))));
    defer self.gpa.free(grid);
    @memset(grid, th.panel);
    var band: Band = .{ .gc = Canvas.init(grid, pw, @intCast(@max(1, view_h))), .px = grid, .w = pw, .h = @intCast(view_h) };
    const gc = &band.gc;
    if (self.shown.items.len == 0) {
        const msg = if (!self.cfg.history) "History is off (history=false)" else if (self.search.items.len > 0) "No capture has that text" else "Nothing copied or saved yet";
        fui.textCentered(gc, .{ .x = 0, .y = 0, .w = @intCast(pw), .h = @min(view_h, s(60, kk)) }, 13 * kk, th.muted, .regular, msg);
    }
    const now = sys.realtimeSec();
    const now_local = now + clock.utcOffset(self.gpa, self.env.tz, now);
    for (self.shown.items, 0..) |idx, n| {
        const r = self.itemRect(n);
        const rx = s(r.x, kk);
        const ry = s(r.y, kk) - top;
        if (ry + s(layout.itemH(), kk) < 0 or ry > view_h) continue;
        try drawItem(self, &band, idx, rx, ry, s(r.w, kk), kk, now_local);
    }
    for (0..@intCast(view_h)) |row| {
        const dy = @as(usize, @intCast(top)) + row;
        if (dy >= ph) break;
        @memcpy(panel[dy * pw ..][0..pw], grid[row * pw ..][0..pw]);
    }
}

/// The grid's band: a canvas on it, and its pixels for the blit.
const Band = struct { gc: Canvas, px: []u32, w: u32, h: u32 };

/// One capture at rx, ry of the grid: its thumbnail, pick or hover ring,
/// and when it was taken.
fn drawItem(self: *Panel, band: *Band, idx: usize, rx: i32, ry: i32, rw: i32, kk: f64, now_local: i64) !void {
    const th = self.theme;
    const gc = &band.gc;
    const rh = s(thumb_h, kk);
    const it = &self.items.items[idx];
    const tw: u32 = @intCast(rw);
    const tth: u32 = @intCast(rh);
    try ensureScaled(self.gpa, it, tw, tth);
    // a rounded thumbnail with a hairline
    const rr = self.gpa.alloc(u32, @as(usize, tw) * tth) catch return;
    defer self.gpa.free(rr);
    @memcpy(rr, it.scaled);
    blitRoundedClipped(band.px, band.w, band.h, rr, tw, tth, rx, ry, @intFromFloat(8 * kk));
    const sel = self.selected == idx;
    const hov = self.hover_item == idx;
    if (sel or hov) {
        shapes.roundRectRing(gc, .{ .x = rx - s(2, kk), .y = ry - s(2, kk), .w = rw + s(4, kk), .h = rh + s(4, kk) }, 10 * kk, if (sel) 2.5 * kk else 1.5 * kk, if (sel) th.accent else th.line);
    }
    var tb: [32]u8 = undefined;
    const then = @divFloor(it.entry.meta.time_ms, 1000);
    const when = clock.relTime(&tb, now_local, then + clock.utcOffset(self.gpa, self.env.tz, then));
    text.draw(gc, rx, ry + rh + s(6, kk), 11 * kk, th.muted, when);
    if (it.entry.meta.saved.len > 0) {
        const w2 = text.width(11 * kk, when);
        text.draw(gc, rx + w2 + s(6, kk), ry + rh + s(6, kk), 11 * kk, th.muted, "· saved");
    }
}

/// Keep the item's thumbnail scaled to the size it is drawn at.
fn ensureScaled(gpa: std.mem.Allocator, it: *Item, tw: u32, tth: u32) !void {
    if (it.sw == tw and it.sh == tth) return;
    gpa.free(it.scaled);
    it.scaled = &.{};
    it.scaled = try gpa.alloc(u32, @as(usize, tw) * tth);
    it.sw = tw;
    it.sh = tth;
    if (it.thumb) |t| {
        fui.drawImageFill(gpa, it.scaled, tw, tth, t.pixels, t.width, t.height);
    } else @memset(it.scaled, fui.card_bg);
}

/// The action bar for the picked capture (Annotate dimmed if it cannot).
fn drawActions(self: *const Panel, cv: *Canvas, it: *const Item, kk: f64) void {
    const th = self.theme;
    const ay = s(self.actionRect(0).y, kk);
    cv.fillRect(s(inset, kk), ay - s(2, kk), s(panel_w - 2 * inset, kk), @max(1, s(1, kk)), th.line);
    for (layout.action_names, 0..) |name, i| {
        const r = self.actionRect(i);
        const cx = (@as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) / 2) * kk;
        const dim = i == 2 and !it.entry.editable;
        const color = if (dim) th.line else if (self.hover_action == i) th.accent else th.fg;
        fui.icon(cv, layout.action_icons[i], cx, (@as(f64, @floatFromInt(r.y)) + 13) * kk, 16 * kk, color);
        fui.textCentered(cv, .{ .x = s(r.x, kk), .y = s(r.y + 24, kk), .w = s(r.w, kk), .h = s(14, kk) }, 10 * kk, if (dim) th.line else th.muted, .regular, name);
    }
}

/// Logical to buffer pixels, for a whole rectangle.
fn sr(r: Rect, kk: f64) Rect {
    return .{ .x = s(r.x, kk), .y = s(r.y, kk), .w = s(r.w, kk), .h = s(r.h, kk) };
}

/// The footer's separator, as above the action bar.
fn footerLine(self: *const Panel, cv: *Canvas, kk: f64) void {
    const ay = s(self.actionRect(0).y, kk);
    cv.fillRect(s(inset, kk), ay - s(2, kk), s(panel_w - 2 * inset, kk), @max(1, s(1, kk)), self.theme.line);
}

/// "Clear history…" in the footer, the first of two steps.
fn drawClear(self: *const Panel, cv: *Canvas, kk: f64) void {
    const th = self.theme;
    footerLine(self, cv, kk);
    const r = sr(self.clearRect(), kk);
    if (self.hover_clear) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 7 * kk, th.hover);
    fui.textCentered(cv, r, 12 * kk, if (self.hover_clear) theme.legible(0xFFFF453A, th.panel, theme.aa_text) else th.muted, .regular, "Clear history\u{2026}");
}

/// "Clear N captures?" with Cancel and a destructive Clear.
fn drawConfirm(self: *const Panel, cv: *Canvas, kk: f64) void {
    const th = self.theme;
    footerLine(self, cv, kk);
    const cancel = sr(self.confirmRect(.cancel), kk);
    const clear = sr(self.confirmRect(.clear), kk);
    var buf: [48]u8 = undefined;
    const n = self.items.items.len;
    const q = std.fmt.bufPrint(&buf, "Clear {d} capture{s}?", .{ n, if (n == 1) "" else "s" }) catch "Clear all?";
    text.drawStyled(cv, s(inset, kk), cancel.y + @divTrunc(cancel.h - text.height(12 * kk), 2), 12 * kk, th.fg, .semibold, q);
    cv.fillRoundRectAA(cancel.x, cancel.y, cancel.w, cancel.h, 7 * kk, if (self.hover_confirm == .cancel) th.hover else th.field);
    fui.textCentered(cv, cancel, 12 * kk, th.fg, .regular, "Cancel");
    const red = if (self.hover_confirm == .clear) theme.destructive_fill_hover else theme.destructive_fill;
    cv.fillRoundRectAA(clear.x, clear.y, clear.w, clear.h, 7 * kk, red);
    fui.textCentered(cv, clear, 12 * kk, fui.white, .semibold, "Clear");
}

fn drawNotice(self: *const Panel, cv: *Canvas, pw: u32, ph: u32, kk: f64) void {
    const nw = text.widthStyled(13 * kk, .semibold, self.notice) + s(28, kk);
    const nh = s(30, kk);
    const nr: Rect = .{ .x = @divTrunc(@as(i32, @intCast(pw)) - nw, 2), .y = @as(i32, @intCast(ph)) - nh - s(actions_h + 12, kk), .w = nw, .h = nh };
    cv.fillRoundRectAA(nr.x, nr.y, nr.w, nr.h, 15 * kk, 0xE6000000);
    fui.textCentered(cv, nr, 13 * kk, fui.white, .semibold, self.notice);
}

/// blitRounded onto an opaque buffer, clipped (rows may fall outside).
fn blitRoundedClipped(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, radius: u32) void {
    effects.blitRounded(dst, dw, dh, src, sw, sh, x, y, radius);
}
