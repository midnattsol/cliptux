//! The self-timer's countdown where the GNOME extension does not draw it
//! (wlroots, KDE, GNOME without the extension): a small glass card in the
//! middle of the screen. It never takes the keyboard on layer-shell
//! compositors (a menu left open for the timer stays open); a click on it
//! cancels. Before the capture it turns fully transparent and waits for
//! the compositor to show that, so it is never in the picture.

const std = @import("std");
const wl = @import("../platform/wayland.zig");
const sys = @import("../platform/sys.zig");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const fui = @import("floatui.zig");
const window = @import("window.zig");

const size = 132;

fn draw(win: *window.Window, left: u32) !void {
    const bw = win.width;
    const bh = win.height;
    const card = try win.alloc.alloc(u32, @as(usize, bw) * bh);
    defer win.alloc.free(card);
    @memset(card, 0xFF1E1E20);
    var cv = render.Canvas.init(card, bw, bh);
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{left}) catch "";
    const k = @as(f64, @floatFromInt(win.scale120)) / 120.0;
    fui.textCentered(&cv, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) }, 60 * k, 0xFFFFFFFF, text.Style.semibold.num(), s);
    const px = try win.backBuffer();
    @memset(px, 0);
    fui.placeCard(px, bw, bh, card, bw, bh, 0, 0, @intFromFloat(32 * k), 0);
    fui.fadeAlpha(px, 0.86);
    fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
    try win.present();
}

/// Nothing drawn, and shown: the capture may start.
fn vanish(win: *window.Window) !void {
    const px = try win.backBuffer();
    @memset(px, 0);
    try win.present();
    const deadline = sys.monoMs() + 300;
    while (win.frame_pending and sys.monoMs() < deadline) _ = try win.nextEventTimeout(20);
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Count `seconds` down. True when it ran out (the card is invisible
/// now and is closed by the caller), false when cancelled.
pub fn run(win: *window.Window, seconds: u8) !bool {
    try win.open("shotlet:timer", .{ .fullscreen = false, .transparent = true, .width = size, .height = size, .layer = .{
        .width = size,
        .height = size,
        .keyboard = wl.zwlr_layer_surface_v1.keyboard_none,
        .namespace = "shotlet-timer",
    } });
    const end = sys.monoMs() + @as(i64, seconds) * 1000;
    var shown: u32 = 0;
    while (true) {
        const now = sys.monoMs();
        if (now >= end) break;
        const left: u32 = @intCast(@divTrunc(end - now + 999, 1000));
        if (left != shown and !win.frame_pending and win.width > 0) {
            try draw(win, left);
            shown = left;
        }
        const ev = (try win.nextEventTimeout(@intCast(@min(100, end - now)))) orelse continue;
        switch (ev) {
            .close => return false,
            .pointer_button => |b| if (b.pressed) return false,
            .key => |k| if (k.pressed and k.code == window.KEY_ESC) return false,
            .resize => shown = 0,
            else => {},
        }
    }
    try vanish(win);
    return true;
}
