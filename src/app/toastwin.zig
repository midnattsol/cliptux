//! `shotlet toast TITLE [TEXT]`: a small card at the bottom of the screen
//! for a couple of seconds, after the editor has closed ("Copied" and the
//! first line of the text `shotlet text` read). Placed like the
//! thumbnail: a layer surface where there is layer shell, else a window
//! titled shotlet:quick that the GNOME extension puts bottom-left, above,
//! without the keyboard focus. A click closes it.

const std = @import("std");
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;
const wl = @import("../platform/linux/wayland.zig");
const portal = @import("../platform/linux/portal.zig");
const text = @import("../gfx/text.zig");
const render = @import("../gfx/render.zig");
const window = @import("../platform/linux/window.zig");
const fui = @import("../ui/floatui.zig");
const theme = @import("../ui/theme.zig");
const icons = @import("../ui/icons.zig");
const Env = env_mod.Env;

const card_w = 340;
const card_h = 64;
const pad = 20;
const show_ms = 2600;

fn prefsOf(gpa: std.mem.Allocator, env: Env) theme.Prefs {
    var conn = portal.connectApp(gpa, env.bus_addr) catch return .{ .dark = true };
    defer conn.deinit();
    return theme.readPrefs(&conn, 300);
}

pub fn run(gpa: std.mem.Allocator, env: Env, title: []const u8, body: []const u8) !void {
    text.init(gpa);
    defer text.deinit();
    const th = prefsOf(gpa, env);
    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    const w: u32 = card_w + 2 * pad;
    const h: u32 = card_h + 2 * pad;
    if (win.hasLayerShell()) {
        try win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = w, .height = h, .layer = .{
            .layer = wl.zwlr_layer_shell_v1.layer_overlay,
            .anchor = wl.zwlr_layer_surface_v1.anchor_bottom,
            .width = w,
            .height = h,
            .margin = .{ 0, 0, 24, 0 },
            .keyboard = wl.zwlr_layer_surface_v1.keyboard_none,
        } });
    } else try win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = w, .height = h });
    win.setCursor(.arrow) catch {};
    std.log.info("toast: {s}: {s}", .{ title, body });
    const end = sys.monoMs() + show_ms;
    var drawn = false;
    while (sys.monoMs() < end) {
        if (!drawn and win.width > 0 and !win.frame_pending) {
            try draw(&win, th, title, body);
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

fn draw(win: *window.Window, prefs: theme.Prefs, title: []const u8, body: []const u8) !void {
    const k = @as(f64, @floatFromInt(win.scale120)) / 120.0;
    const px = try win.backBuffer();
    @memset(px, 0);
    const sc = struct {
        fn f(v: f64, kk: f64) i32 {
            return @intFromFloat(@round(v * kk));
        }
    }.f;
    const cw: u32 = @intCast(sc(card_w, k));
    const ch: u32 = @intCast(sc(card_h, k));
    const card = try std.heap.page_allocator.alloc(u32, @as(usize, cw) * ch);
    defer std.heap.page_allocator.free(card);
    const th = fui.Theme.fromPrefs(prefs);
    @memset(card, th.panel);
    var c = render.Canvas.init(card, cw, ch);
    const cy = @as(f64, @floatFromInt(ch)) / 2.0;
    const bx = 16.0 * k + 12.0 * k;
    c.fillCircleAA(bx, cy, 12.0 * k, th.accent);
    const is = sc(14, k);
    icons.drawStroke(&c, .check, @as(i32, @intFromFloat(bx)) - @divTrunc(is, 2), @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2), is, 3, 0xFFFFFFFF);
    const tx = sc(16 + 24 + 12, k);
    const fs = 14.0 * k;
    const ss = 12.0 * k;
    var buf: [256]u8 = undefined;
    const line = fui.ellipsize(&buf, ss, body, @as(i32, @intCast(cw)) - tx - sc(16, k));
    const top: i32 = @divTrunc(@as(i32, @intCast(ch)) - text.heightStyled(fs, .semibold) - (if (body.len > 0) text.height(ss) else 0), 2);
    text.drawStyled(&c, tx, top, fs, th.fg, .semibold, title);
    if (body.len > 0) text.draw(&c, tx, top + text.heightStyled(fs, .semibold), ss, th.muted, line);
    fui.placeCard(px, win.width, win.height, card, cw, ch, sc(pad, k), sc(pad, k), @intCast(sc(14, k)), @intCast(sc(10, k)));
    fui.premultiply(px, win.width, win.height, .{ .x = 0, .y = 0, .w = @intCast(win.width), .h = @intCast(win.height) });
    try win.present();
}
