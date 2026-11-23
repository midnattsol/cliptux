//! `shotlet toast [--info] TITLE [TEXT]`: a small card at the bottom of
//! the screen for a couple of seconds, after the editor has closed
//! ("Copied" and the first line of the text `shotlet text` read). With
//! --info it tells why something cannot be done (a scrolling capture
//! where none can run): an "i" instead of the check, as wide as its words
//! need and up for longer. Placed like the
//! thumbnail: a layer surface where there is layer shell, else a window
//! titled shotlet:quick that the GNOME extension puts bottom-left, above,
//! without the keyboard focus. A click closes it.

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;
const text = @import("../gfx/text.zig");
const render = @import("../gfx/render.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("../ui/icons.zig");
const Env = env_mod.Env;

const card_w = 340;
const card_max_w = 560;
const card_h = 64;
const pad = 20;
/// the text's left edge (after the badge) and the card's right margin
const text_x = 16 + 24 + 12;
const text_right = 16;
const title_size = 14.0;
const body_size = 12.0;

pub const Kind = enum {
    /// done: a check
    done,
    /// why something cannot be done: an "i"
    info,

    fn showMs(self: Kind) i64 {
        return switch (self) {
            .done => 2600,
            .info => 6000,
        };
    }
};

pub const Toast = struct {
    kind: Kind = .done,
    title: []const u8,
    body: []const u8 = "",
};

/// `[--info] TITLE [TEXT]`.
pub fn runArgs(gpa: std.mem.Allocator, env: Env, args: []const [:0]const u8) !void {
    const info = args.len > 0 and std.mem.eql(u8, args[0], "--info");
    const rest = args[@intFromBool(info)..];
    if (rest.len == 0) return error.MissingTitle;
    return run(gpa, env, .{ .kind = if (info) .info else .done, .title = rest[0], .body = if (rest.len > 1) rest[1] else "" });
}

/// The card's logical width: fixed for done, else as wide as the words.
fn cardWidth(t: Toast) u32 {
    if (t.kind == .done) return card_w;
    const words = @max(text.widthStyled(title_size, .semibold, t.title), text.width(body_size, t.body));
    return @intCast(std.math.clamp(words + text_x + text_right, card_w, card_max_w));
}

fn prefsOf(gpa: std.mem.Allocator, env: Env) theme.Prefs {
    var conn = desktop.connect(gpa, env) catch return .{ .dark = true };
    defer conn.deinit();
    return theme.readPrefs(&conn, 300);
}

pub fn run(gpa: std.mem.Allocator, env: Env, t: Toast) !void {
    text.init(gpa);
    defer text.deinit();
    const th = prefsOf(gpa, env);
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    const cw = cardWidth(t);
    const w: u32 = cw + 2 * pad;
    const h: u32 = card_h + 2 * pad;
    if (win.hasLayerShell()) {
        try win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = w, .height = h, .layer = .{
            .layer = .overlay,
            .anchor = .{ .bottom = true },
            .width = w,
            .height = h,
            .margin = .{ 0, 0, 24, 0 },
            .keyboard = .none,
        } });
    } else try win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = w, .height = h });
    win.setCursor(.arrow) catch {};
    std.log.info("toast: {s}: {s}", .{ t.title, t.body });
    const end = sys.monoMs() + t.kind.showMs();
    var drawn = false;
    while (sys.monoMs() < end) {
        if (!drawn and win.width > 0 and !win.frame_pending) {
            try draw(&win, th, t, cw);
            drawn = true;
        }
        const ev = (try win.nextEventTimeout(100)) orelse continue;
        switch (ev) {
            .close => break,
            .pointer_button => |b| if (b.pressed) break,
            .resize => drawn = false,
            else => {},
        }
    }
    win.closeWindow();
}

fn sc(v: f64, k: f64) i32 {
    return @intFromFloat(@round(v * k));
}

/// The card of logical width `card_lw`, at the window's scale.
fn draw(win: *window.Window, prefs: theme.Prefs, t: Toast, card_lw: u32) !void {
    const k = @as(f64, @floatFromInt(win.scale120)) / 120.0;
    const px = try win.backBuffer();
    @memset(px, 0);
    const cw: u32 = @intCast(sc(@floatFromInt(card_lw), k));
    const ch: u32 = @intCast(sc(card_h, k));
    const card = try std.heap.page_allocator.alloc(u32, @as(usize, cw) * ch);
    defer std.heap.page_allocator.free(card);
    const th = fui.Theme.fromPrefs(prefs);
    @memset(card, th.panel);
    var c = render.Canvas.init(card, cw, ch);
    drawBadge(&c, th, t.kind, k);
    const tx = sc(text_x, k);
    const fs = title_size * k;
    const ss = body_size * k;
    const room = @as(i32, @intCast(cw)) - tx - sc(text_right, k);
    var tbuf: [256]u8 = undefined;
    var bbuf: [256]u8 = undefined;
    const top: i32 = @divTrunc(@as(i32, @intCast(ch)) - text.heightStyled(fs, .semibold) - (if (t.body.len > 0) text.height(ss) else 0), 2);
    text.drawStyled(&c, tx, top, fs, th.fg, .semibold, fui.ellipsize(&tbuf, fs, t.title, room));
    if (t.body.len > 0) text.draw(&c, tx, top + text.heightStyled(fs, .semibold), ss, th.muted, fui.ellipsize(&bbuf, ss, t.body, room));
    fui.placeCard(px, win.width, win.height, card, cw, ch, sc(pad, k), sc(pad, k), @intCast(sc(14, k)), @intCast(sc(10, k)));
    fui.premultiply(px, win.width, win.height, .{ .x = 0, .y = 0, .w = @intCast(win.width), .h = @intCast(win.height) });
    try win.present();
}

/// The accent disc at the card's left: a check, or an "i".
fn drawBadge(c: *render.Canvas, th: fui.Theme, kind: Kind, k: f64) void {
    const cy = @as(f64, @floatFromInt(c.h)) / 2.0;
    const bx = 16.0 * k + 12.0 * k;
    c.fillCircleAA(bx, cy, 12.0 * k, th.accent);
    const is = sc(14, k);
    const ix = @as(i32, @intFromFloat(bx)) - @divTrunc(is, 2);
    const iy = @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2);
    switch (kind) {
        .done => icons.drawStroke(c, .check, ix, iy, is, 3, 0xFFFFFFFF),
        .info => {
            const fs = 15.0 * k;
            text.drawStyled(c, ix + @divTrunc(is - text.widthStyled(fs, .bold, "i"), 2), iy + @divTrunc(is - text.heightStyled(fs, .bold), 2), fs, 0xFFFFFFFF, .bold, "i");
        },
    }
}
