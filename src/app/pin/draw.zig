//! A pin's frame: the picture as a rounded card with its shadow, at the
//! pin's opacity (fading in when it first shows), the chrome over it at
//! full strength, and the menu over everything.

const std = @import("std");
const effects = @import("../../gfx/effects.zig");
const resample = @import("../../gfx/resample.zig");
const sys = @import("../../platform/api.zig").sys;
const fui = @import("../../ui/floatui.zig");
const state = @import("state.zig");
const chrome = @import("chrome.zig");
const menu_draw = @import("menu_draw.zig");

const Pin = state.Pin;
const radius = 8;
const fade_in_ms = 150;
/// the Keep on Top hint shows this long
pub const hint_ms = 5000;

/// Opacity while fading in.
fn fadeIn(p: *Pin, now: i64) f64 {
    if (p.shown_ms == 0) p.shown_ms = now;
    return @min(1, @as(f64, @floatFromInt(now - p.shown_ms)) / fade_in_ms);
}

/// Fading in (or not drawn yet), or the menu fading in or out.
fn moving(p: *const Pin, now: i64) bool {
    return p.shown_ms == 0 or now - p.shown_ms < fade_in_ms or p.menu.shown.busy(now);
}

/// Frames are due: something moves, or it stopped since the last frame.
pub fn animating(p: *const Pin, now: i64) bool {
    return moving(p, now) or !p.settled;
}

pub fn hintShown(p: *const Pin, now: i64) bool {
    return p.hint and now - p.born < hint_ms;
}

/// Rescales the cached picture when its size changed.
fn rescale(p: *Pin, pw: u32, ph: u32) !void {
    if (p.scaled_w == pw and p.scaled_h == ph) return;
    p.gpa.free(p.scaled);
    p.scaled = &.{};
    p.scaled = try p.gpa.alloc(u32, @as(usize, pw) * ph);
    try resample.scale(p.gpa, p.img.pixels, p.img.width, p.img.height, p.scaled, pw, ph);
    p.scaled_w = pw;
    p.scaled_h = ph;
}

pub fn frame(p: *Pin, k: f64) !void {
    const win = p.win;
    const px = try win.backBuffer();
    const bw = win.width;
    const bh = win.height;
    @memset(px, 0);
    const now = sys.monoMs();
    p.settled = !moving(p, now);
    // away in the editor: nothing shows, nothing takes clicks
    if (p.edit != null) {
        p.settled = true;
        return win.present();
    }
    const sz = p.picSize();
    try rescale(p, sz[0], sz[1]);
    const a = fadeIn(p, now);
    try picture(p, px, bw, bh, k, a);
    if (p.menu.visible(now)) try menu_draw.draw(p.gpa, px, bw, bh, k, p.th, &p.menu, .{ .locked = p.locked, .opacity = p.opacity }, now);
    fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
    try win.present();
}

/// The card at the pin's opacity, then whatever chrome shows, opaque
/// (only faded in with the pin): it must stay readable on a faint pin.
fn picture(p: *Pin, px: []u32, bw: u32, bh: u32, k: f64, a: f64) !void {
    const pw = p.scaled_w;
    const ph = p.scaled_h;
    const ox: i32 = @intFromFloat(@round(state.pad * k));
    const card = try p.gpa.alloc(u32, @as(usize, pw) * ph);
    defer p.gpa.free(card);
    @memset(card, 0xFF000000);
    for (card, p.scaled) |*d, s| d.* = effects.over(d.*, s);
    fui.placeCard(px, bw, bh, card, pw, ph, ox, ox, @intFromFloat(radius * k), @intFromFloat(@max(1, 10 * k)));
    fui.fadeAlpha(px, a * p.opacity.alpha());
    const look: chrome.Look = .{ .hover = p.hover, .locked = p.locked, .zoom = p.zoom, .hint = hintShown(p, sys.monoMs()) };
    if (!look.locked and look.hover == .none and !look.hint) return;
    const over = try p.gpa.dupe(u32, card);
    defer p.gpa.free(over);
    var cv = fui.Canvas.init(over, pw, ph);
    chrome.draw(&cv, k, pw, ph, look);
    overlayChanged(px, bw, bh, card, over, pw, ph, ox, a);
}

/// The pixels where `over` differs from `card` (the chrome), at `a`, onto
/// px at ox, ox.
fn overlayChanged(px: []u32, bw: u32, bh: u32, card: []const u32, over: []const u32, pw: u32, ph: u32, ox: i32, a: f64) void {
    const alpha: u32 = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
    for (0..ph) |y| {
        const dy = @as(i64, ox) + @as(i64, @intCast(y));
        if (dy < 0 or dy >= bh) continue;
        for (0..pw) |x| {
            const i = y * pw + x;
            if (over[i] == card[i]) continue;
            const dx = @as(i64, ox) + @as(i64, @intCast(x));
            if (dx < 0 or dx >= bw) continue;
            const d = &px[@as(usize, @intCast(dy)) * bw + @as(usize, @intCast(dx))];
            d.* = effects.over(d.*, (over[i] & 0x00FFFFFF) | (alpha << 24));
        }
    }
}

test "the chrome overlay changes only where the chrome is" {
    var px: [4]u32 = @splat(0x80102030);
    const card = [_]u32{ 0xFF000000, 0xFF000000, 0xFF000000, 0xFF000000 };
    const over = [_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF000000, 0xFF000000 };
    overlayChanged(&px, 2, 2, &card, &over, 2, 2, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x80102030), px[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[1]);
}
