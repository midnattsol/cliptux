//! The scrolling capture's control: a small glass card beside the region
//! with the stitched image growing in it, what is happening (or why it
//! stopped, in plain words) and its buttons:
//!
//!   running, warning   Stop                         Enter; Esc cancels
//!   paused             Cancel  Finish  Continue     Esc, Enter, C or Space
//!   done               Finish (the editor opens by itself)
//!
//! Light or dark with the desktop (ui/theme.zig). It changes in place:
//! the layout is the same in every phase, only words and buttons change,
//! and nothing animates (so reduced motion has nothing to reduce).
//!
//! Its window is titled "shotlet:scroll": the GNOME extension keeps it
//! above other windows and only steps a scrolling capture while it is on
//! screen. With layer shell it is an overlay in the top-right corner.

const std = @import("std");
const wl = @import("../platform/wayland.zig");
const sys = @import("../platform/sys.zig");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const fui = @import("floatui.zig");
const theme = @import("theme.zig");
const window = @import("window.zig");
const Rect = @import("../app/modes/geom.zig").Rect;

pub const title = "shotlet:scroll";
/// logical size
pub const width = 264;
pub const height = 356;
const pad = 14;
const radius = 18;
const preview_y = pad + 60;
const preview_h = 196;
const button_h = 32;
const button_gap = 6;

pub const Phase = enum {
    running,
    /// running, with something to say (the person scrolled too fast)
    warning,
    /// stopped short: Continue, Finish or Cancel
    paused,
    /// complete; the editor opens in a moment
    done,
};

pub const Action = enum { finish, cancel, @"continue" };

/// Rows of the image so far, for the preview.
pub const Source = struct {
    ctx: *const anyopaque,
    width: u32,
    height: u32,
    row: *const fn (ctx: *const anyopaque, y: u32) []const u32,
};

const Button = struct { r: Rect, action: Action, label: []const u8, primary: bool };

/// The colours of the card, made opaque (no backdrop blur for a client).
const Look = struct {
    th: theme.Theme,
    card: u32,
    edge: u32,
    well: u32,
    muted: u32,
    secondary: u32,

    fn of(th: theme.Theme) Look {
        const card = effects.over(th.window_bg, th.panel);
        return .{
            .th = th,
            .card = card,
            .edge = effects.over(card, th.hairline),
            .well = effects.over(card, th.field),
            .muted = effects.over(card, th.muted),
            .secondary = effects.over(card, th.pressed),
        };
    }
};

pub const Hud = struct {
    win: *window.Window,
    look: Look,
    phase: Phase = .running,
    headline_buf: [96]u8 = undefined,
    headline: []const u8 = "Starting\u{2026}",
    hint_buf: [96]u8 = undefined,
    hint: []const u8 = "",
    detail_buf: [48]u8 = undefined,
    detail: []const u8 = "",
    buttons_buf: [3]Button = undefined,
    buttons: []const Button = &.{},
    hover: ?Action = null,
    dirty: bool = true,

    pub fn open(win: *window.Window, th: theme.Theme) !Hud {
        try win.open(title, .{ .fullscreen = false, .transparent = true, .width = width, .height = height, .layer = .{
            .anchor = wl.zwlr_layer_surface_v1.anchor_top | wl.zwlr_layer_surface_v1.anchor_right,
            .width = width,
            .height = height,
            .margin = .{ 24, 24, 0, 0 },
            .keyboard = wl.zwlr_layer_surface_v1.keyboard_on_demand,
            .namespace = "shotlet-scroll",
        } });
        win.setCursor(.arrow) catch {};
        return .{ .win = win, .look = Look.of(th) };
    }

    /// What the card says: `headline`, an optional `hint` under it, and
    /// the image's height so far.
    pub fn show(self: *Hud, phase: Phase, headline: []const u8, hint: []const u8, height_px: u32) void {
        self.phase = phase;
        self.headline = copy(&self.headline_buf, headline);
        self.hint = copy(&self.hint_buf, hint);
        var nbuf: [24]u8 = undefined;
        self.detail = std.fmt.bufPrint(&self.detail_buf, "{s} px tall", .{grouped(&nbuf, height_px)}) catch "";
        self.dirty = true;
    }

    /// A message "Headline \u{2014} hint" on two lines, the hint capitalised.
    pub fn showMessage(self: *Hud, phase: Phase, message: []const u8, height_px: u32) void {
        const sep = " \u{2014} ";
        const i = std.mem.indexOf(u8, message, sep) orelse return self.show(phase, message, "", height_px);
        var hbuf: [96]u8 = undefined;
        const hint = copy(&hbuf, message[i + sep.len ..]);
        if (hint.len > 0) hbuf[0] = std.ascii.toUpper(hbuf[0]);
        self.show(phase, message[0..i], hint, height_px);
    }

    fn k(self: *const Hud) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    fn sc(self: *const Hud, v: f64) i32 {
        return @intFromFloat(@round(v * self.k()));
    }

    pub fn draw(self: *Hud, src: ?Source) !void {
        if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
        self.dirty = false;
        const bw = self.win.width;
        const bh = self.win.height;
        const card = try self.win.alloc.alloc(u32, @as(usize, bw) * bh);
        defer self.win.alloc.free(card);
        var cv = render.Canvas.init(card, bw, bh);
        self.drawCard(&cv, src);
        const px = try self.win.backBuffer();
        @memset(px, 0);
        fui.placeCard(px, bw, bh, card, bw, bh, 0, 0, @intCast(self.sc(radius)), 0);
        fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
        try self.win.present();
    }

    /// Everything on the card, on an opaque canvas of the window's size.
    fn drawCard(self: *Hud, cv: *render.Canvas, src: ?Source) void {
        const lk = self.look;
        @memset(cv.px, lk.edge);
        const one = @max(1, self.sc(1));
        cv.fillRoundRectAA(one, one, cv.w - 2 * one, cv.h - 2 * one, @floatFromInt(self.sc(radius) - one), lk.card);
        const x0 = self.sc(pad);
        const inner = cv.w - 2 * x0;
        const fs = theme.font_small * self.k();
        text.drawStyled(cv, x0, self.sc(pad), theme.font_label * self.k(), lk.th.fg, .semibold, "Scrolling capture");
        const loud = self.phase != .running;
        var ebuf: [128]u8 = undefined;
        text.drawStyled(cv, x0, self.sc(pad + 22), fs, if (loud) lk.th.fg else lk.muted, if (loud) .semibold else .regular, fui.ellipsize(&ebuf, fs, self.headline, inner));
        text.draw(cv, x0, self.sc(pad + 38), fs, lk.muted, fui.ellipsize(&ebuf, fs, self.hint, inner));
        const pv: Rect = .{ .x = x0, .y = self.sc(preview_y), .w = inner, .h = self.sc(preview_h) };
        cv.fillRect(pv.x, pv.y, pv.w, pv.h, lk.well);
        if (src) |s| drawPreview(cv, pv, s);
        text.drawStyled(cv, x0, pv.y + pv.h + self.sc(8), fs, lk.muted, text.Style.regular.num(), self.detail);
        self.layoutButtons(cv.w, cv.h);
        for (self.buttons) |b| self.drawButton(cv, b);
    }

    /// The bottom row for this phase: one wide button, or three.
    fn layoutButtons(self: *Hud, w: i32, h: i32) void {
        const bh = self.sc(button_h);
        const y = h - self.sc(pad) - bh;
        const x0 = self.sc(pad);
        const inner = w - 2 * x0;
        const b = &self.buttons_buf;
        if (self.phase != .paused) {
            b[0] = .{ .r = .{ .x = x0, .y = y, .w = inner, .h = bh }, .action = .finish, .label = if (self.phase == .done) "Finish" else "Stop", .primary = true };
            self.buttons = b[0..1];
            return;
        }
        const gap = self.sc(button_gap);
        const bw = @divTrunc(inner - 2 * gap, 3);
        const acts = [3]Action{ .cancel, .finish, .@"continue" };
        const labels = [3][]const u8{ "Cancel", "Finish", "Continue" };
        for (0..3) |i| {
            const x = x0 + @as(i32, @intCast(i)) * (bw + gap);
            const last = i == 2;
            b[i] = .{ .r = .{ .x = x, .y = y, .w = if (last) x0 + inner - x else bw, .h = bh }, .action = acts[i], .label = labels[i], .primary = last };
        }
        self.buttons = b[0..3];
    }

    fn drawButton(self: *const Hud, cv: *render.Canvas, b: Button) void {
        const th = self.look.th;
        const hot = self.hover == b.action;
        const bg = if (b.primary)
            (if (hot) th.accent_fill_hover else th.accent_fill)
        else if (hot) effects.over(self.look.secondary, th.hover) else self.look.secondary;
        const r = b.r;
        cv.fillRoundRectAA(r.x, r.y, r.w, r.h, theme.button_radius * self.k(), bg);
        fui.textCentered(cv, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, theme.font_label * self.k(), if (b.primary) th.on_accent else th.fg, .semibold, b.label);
    }

    /// The bottom of the image, as wide as the preview.
    fn drawPreview(cv: *render.Canvas, pv: Rect, s: Source) void {
        if (s.width == 0 or s.height == 0) return;
        const scale = @as(f64, @floatFromInt(pv.w)) / @as(f64, @floatFromInt(s.width));
        const shown: u32 = @min(s.height, @as(u32, @intFromFloat(@as(f64, @floatFromInt(pv.h)) / scale)));
        const first = s.height - shown;
        const dh: i32 = @intFromFloat(@as(f64, @floatFromInt(shown)) * scale);
        const top = pv.y + pv.h - dh;
        var y: i32 = 0;
        while (y < dh) : (y += 1) {
            const sy = first + @min(shown - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(y)) / scale)));
            const row = s.row(s.ctx, sy);
            const out = cv.px[@as(usize, @intCast((top + y) * cv.w + pv.x))..][0..@intCast(pv.w)];
            for (out, 0..) |*o, x| o.* = row[@min(s.width - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(x)) / scale)))] | 0xFF000000;
        }
    }

    /// Wait up to `ms` for input: the action asked for, if any.
    pub fn poll(self: *Hud, ms: i32) !?Action {
        const deadline = sys.monoMs() + ms;
        while (true) {
            const left = deadline - sys.monoMs();
            const ev = (try self.win.nextEventTimeout(@intCast(@max(0, left)))) orelse return null;
            if (self.handle(ev)) |a| return a;
            if (left <= 0) return null;
        }
    }

    fn handle(self: *Hud, ev: window.InputEvent) ?Action {
        switch (ev) {
            .close => return .cancel,
            .resize, .frame_done => self.dirty = true,
            .key => |key| if (key.pressed and !key.repeat) return keyAction(self.phase, key),
            .pointer_motion => |m| {
                const over = self.buttonAt(m.x, m.y);
                if (over != self.hover) self.dirty = true;
                self.hover = over;
            },
            .pointer_button => |b| if (b.pressed and b.button == window.BTN_LEFT) return self.buttonAt(b.x, b.y),
            else => {},
        }
        return null;
    }

    fn buttonAt(self: *const Hud, x: f64, y: f64) ?Action {
        for (self.buttons) |b| if (b.r.contains(@intFromFloat(x), @intFromFloat(y))) return b.action;
        return null;
    }
};

const key_c = 46;

/// Enter finishes, Esc cancels; when paused, C or Space continues.
pub fn keyAction(phase: Phase, key: window.Key) ?Action {
    if (key.ctrl or key.alt) return null;
    switch (key.code) {
        window.KEY_ESC => return .cancel,
        window.KEY_ENTER, window.KEY_KPENTER => return .finish,
        else => {},
    }
    if (phase != .paused) return null;
    const c = if (key.keysym != 0) key.keysym == 'c' or key.keysym == 'C' else key.code == key_c;
    return if (c or key.code == window.KEY_SPACE) .@"continue" else null;
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// `v` with a thin space between groups of three digits: 20 000.
pub fn grouped(buf: []u8, v: u32) []const u8 {
    var digits: [10]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable;
    const sep = "\u{2009}";
    var n: usize = 0;
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0 and n + sep.len <= buf.len) {
            @memcpy(buf[n..][0..sep.len], sep);
            n += sep.len;
        }
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

test "keys: Enter finishes, Esc cancels, C or Space continues only when paused" {
    const key = struct {
        fn of(code: u32, sym: u32) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = false, .shift = false, .keysym = sym };
        }
    }.of;
    try std.testing.expectEqual(@as(?Action, .finish), keyAction(.running, key(window.KEY_ENTER, 0)));
    try std.testing.expectEqual(@as(?Action, .cancel), keyAction(.paused, key(window.KEY_ESC, 0)));
    try std.testing.expectEqual(@as(?Action, .@"continue"), keyAction(.paused, key(window.KEY_SPACE, ' ')));
    try std.testing.expectEqual(@as(?Action, .@"continue"), keyAction(.paused, key(key_c, 'c')));
    // C where the layout puts it, not the physical key
    try std.testing.expectEqual(@as(?Action, null), keyAction(.paused, key(key_c, 'j')));
    try std.testing.expectEqual(@as(?Action, null), keyAction(.running, key(window.KEY_SPACE, ' ')));
    var ctrl_c = key(key_c, 'c');
    ctrl_c.ctrl = true;
    try std.testing.expectEqual(@as(?Action, null), keyAction(.paused, ctrl_c));
}

test "the labels fit their buttons" {
    text.init(std.testing.allocator);
    defer text.deinit();
    if (!text.available()) return error.SkipZigTest;
    const inner = width - 2 * pad;
    const bw = @divTrunc(inner - 2 * button_gap, 3);
    for ([_][]const u8{ "Cancel", "Finish", "Continue" }) |l|
        try std.testing.expect(text.widthStyled(theme.font_label, .semibold, l) + 12 <= bw);
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("20\u{2009}000", grouped(&buf, 20_000));
}
