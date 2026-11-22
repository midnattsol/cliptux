//! Pin to screen (`shotlet pin FILE`): a small frameless window showing a
//! capture at 1:1 (one image pixel per screen pixel). Scroll to zoom, drag
//! to move, Esc or the close button to close; several pins can be open.
//!
//! With zwlr_layer_shell_v1 (KDE, wlroots) the pin is a top-layer surface,
//! above normal windows, moved by changing its margins. On GNOME it is a
//! regular toplevel titled "shotlet:pin": the Shotlet GNOME Shell
//! extension keeps it above other windows; without the extension GNOME
//! cannot keep a Wayland window on top unless the person chooses "Always
//! on Top" in the window menu (right-click on the pin opens that menu, and
//! the pin says so when it appears).
//!
//! Pinned from the editor it opens where the capture was (`--at`, the
//! centre in logical pixels: the extension places a toplevel titled
//! "shotlet:pin:X:Y"), and it fades in rather than zooming from nowhere.

const std = @import("std");
const shell = @import("../platform/api.zig").shell;
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;
const png = @import("../gfx/png.zig");
const resample = @import("../gfx/resample.zig");
const text = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const Env = env_mod.Env;

/// shadow room around the picture, logical pixels
const pad = 14;
const radius = 8;
const hint_ms = 5000;
const fade_in_ms = 150;

pub const zoom_min = 0.1;
pub const zoom_max = 8.0;

/// Next zoom level for `steps` wheel notches (positive = zoom out).
pub fn zoomStep(z: f64, steps: i32) f64 {
    const nz = z * std.math.pow(f64, 1.1, @floatFromInt(-steps));
    // snap to 100% when crossing it
    if ((z < 1 and nz > 1) or (z > 1 and nz < 1)) return 1;
    return std.math.clamp(nz, zoom_min, zoom_max);
}

test "zoom steps snap to 100% and stay in range" {
    try std.testing.expectEqual(@as(f64, 1), zoomStep(0.95, -1));
    try std.testing.expectEqual(@as(f64, 1), zoomStep(1.05, 1));
    try std.testing.expect(zoomStep(1, -1) > 1.09);
    try std.testing.expectEqual(@as(f64, zoom_max), zoomStep(7.9, -10));
    try std.testing.expectEqual(@as(f64, zoom_min), zoomStep(0.11, 10));
}

/// `shotlet pin FILE [--at X,Y]`: PNG, JPEG or WebP
/// (src/gfx/imgload.zig), centred on X,Y when given.
pub fn run(gpa: std.mem.Allocator, env: Env, path: []const u8, at: ?[2]i32) !void {
    var img = try @import("../gfx/imgload.zig").loadFile(gpa, path);
    defer img.deinit(gpa);
    return show(gpa, env, &img, path, at);
}

/// "X,Y" as `--at` takes it.
pub fn parseAt(s: []const u8) ?[2]i32 {
    var it = std.mem.splitScalar(u8, s, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    return if (it.next() == null) .{ x, y } else null;
}

/// Pin `img` (`what` names it in the log) until the pin is closed;
/// centred on `at` (logical pixels) when given.
pub fn show(gpa: std.mem.Allocator, env: Env, img: *const png.Image, what: []const u8, at: ?[2]i32) !void {
    text.init(gpa);
    defer text.deinit();

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    var pin: Pin = .{ .gpa = gpa, .win = &win, .img = img, .layer = win.hasLayerShell(), .born = sys.monoMs(), .at = at };
    defer gpa.free(pin.scaled);
    try pin.open();
    pin.hint = !pin.layer and shell.applies() and needsTopHint(gpa, env);
    std.log.info("pin: showing {s} ({d}x{d}, {s})", .{ what, img.width, img.height, if (pin.layer) "layer shell" else if (pin.hint) "plain window" else "kept above by the GNOME extension" });
    try pin.loop();
    std.log.info("pin: closed", .{});
}

/// GNOME without the Shotlet extension cannot keep the pin on top: true
/// when the pin should tell the person about "Always on Top".
fn needsTopHint(gpa: std.mem.Allocator, env: Env) bool {
    var bus = desktop.connectBrief(gpa, env) catch return true;
    defer bus.deinit();
    return !shell.active(&bus);
}

/// One pin window: its placement, zoom, hover and drag state.
const Pin = struct {
    gpa: std.mem.Allocator,
    win: *window.Window,
    img: *const png.Image,
    /// a layer-shell surface (moved by its margins) rather than a toplevel
    layer: bool,
    born: i64,
    /// where its centre goes (logical); null: where the compositor puts it
    at: ?[2]i32 = null,
    /// first drawn (0: not yet): it fades in from there
    shown_ms: i64 = 0,
    hint: bool = false,
    margin: [4]i32 = .{ 120, 0, 0, 120 },
    // window size in logical pixels; first guess at scale 1, corrected
    // once the real scale is known
    lw: u32 = 0,
    lh: u32 = 0,
    last_f: f64 = 0,
    zoom: f64 = 1,
    scaled: []u32 = &.{},
    scaled_w: u32 = 0,
    scaled_h: u32 = 0,
    hover: bool = false,
    hover_close: bool = false,
    dirty: bool = true,
    scroll_acc: f64 = 0,
    // layer shell: a drag in progress, from this pointer position (only
    // without relative pointer events), and the margins (top, left) it
    // has moved the pin to, unrounded
    drag_from: ?[2]f64 = null,
    drag_at: [2]f64 = .{ 0, 0 },
    drag_rel: bool = false,

    fn open(p: *Pin) !void {
        const win = p.win;
        // a layer surface is moved by hand: follow the pointer's own motion
        win.track_relative = p.layer;
        p.lw = p.img.width + 2 * pad;
        p.lh = p.img.height + 2 * pad;
        var title_buf: [48]u8 = undefined;
        const title = p.placeAt(&title_buf);
        if (p.layer) {
            try win.open(title, .{ .fullscreen = false, .transparent = true, .width = p.lw, .height = p.lh, .layer = .{
                .layer = .top,
                .anchor = .{ .top = true, .left = true },
                .width = p.lw,
                .height = p.lh,
                .margin = p.margin,
            } });
        } else {
            try win.open(title, .{ .fullscreen = false, .transparent = true, .width = p.lw, .height = p.lh });
        }
        win.report_leave = true;
        win.setCursor(.arrow) catch {};
    }

    /// With `at`: the margins (layer shell) and the title (the GNOME
    /// extension) that put the picture's centre there, at the scale of
    /// the output under it. Returns the title.
    fn placeAt(p: *Pin, buf: []u8) []const u8 {
        const at = p.at orelse return "shotlet:pin";
        var scale: u32 = 1;
        var origin: [2]i32 = .{ 0, 0 };
        for (p.win.outputList()) |o| {
            const r = o.logicalRect();
            const inside = at[0] >= r.x and at[0] < r.x + r.w and at[1] >= r.y and at[1] < r.y + r.h;
            if (o.id == 0 or !inside) continue;
            scale = @intCast(@max(1, o.scale));
            origin = .{ r.x, r.y };
        }
        const w: i32 = @intCast((p.img.width + scale - 1) / scale + 2 * pad);
        const h: i32 = @intCast((p.img.height + scale - 1) / scale + 2 * pad);
        const x = at[0] - @divTrunc(w, 2);
        const y = at[1] - @divTrunc(h, 2);
        p.margin = .{ y - origin[1], 0, 0, x - origin[0] };
        return std.fmt.bufPrint(buf, "shotlet:pin:{d}:{d}", .{ x, y }) catch "shotlet:pin";
    }

    /// Opacity while fading in.
    fn fadeIn(p: *Pin, now: i64) f64 {
        if (p.shown_ms == 0) p.shown_ms = now;
        return @min(1, @as(f64, @floatFromInt(now - p.shown_ms)) / fade_in_ms);
    }

    fn loop(p: *Pin) !void {
        while (true) {
            const k = @as(f64, @floatFromInt(p.win.scale120)) / 120.0;
            // the picture's size on screen: image pixels * zoom, in buffer pixels
            const pw = zoomedSize(p.img.width, p.zoom);
            const ph = zoomedSize(p.img.height, p.zoom);
            try p.fitWindow(k, pw, ph);
            const show_hint = p.hint and sys.monoMs() - p.born < hint_ms;
            if (p.dirty and !p.win.frame_pending and p.win.width > 0) {
                p.dirty = false;
                try p.draw(k, pw, ph, show_hint);
            }
            const fading = p.shown_ms == 0 or sys.monoMs() - p.shown_ms < fade_in_ms;
            if (fading) p.dirty = true;
            const ev = (try p.win.nextEventTimeout(if (fading) 16 else if (show_hint) 250 else 1000)) orelse {
                if (p.hint and !show_hint) {
                    p.hint = false;
                    p.dirty = true;
                }
                continue;
            };
            if (try p.handle(ev, k)) break;
        }
    }

    fn zoomedSize(n: u32, zoom: f64) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * zoom))));
    }

    /// Resizes the window around a `pw` x `ph` picture when it or the
    /// scale changed.
    fn fitWindow(p: *Pin, k: f64, pw: u32, ph: u32) !void {
        const want_w: u32 = @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(pw)) / k))) + 2 * pad;
        const want_h: u32 = @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(ph)) / k))) + 2 * pad;
        if (want_w == p.lw and want_h == p.lh and k == p.last_f) return;
        p.lw = want_w;
        p.lh = want_h;
        p.last_f = k;
        const win = p.win;
        if (p.layer) try win.setLayerPlacement(0, p.lw, p.lh, p.margin) else try win.resizeTo(0, p.lw, p.lh);
        try win.setWindowGeometry(0, .{ .x = pad, .y = pad, .w = @intCast(p.lw - 2 * pad), .h = @intCast(p.lh - 2 * pad) });
        const o: i32 = pad;
        try win.setInputRegion(0, &.{.{ .x = o, .y = o, .w = @intCast(p.lw - 2 * pad), .h = @intCast(p.lh - 2 * pad) }});
        p.dirty = true;
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

    fn draw(p: *Pin, k: f64, pw: u32, ph: u32, show_hint: bool) !void {
        try p.rescale(pw, ph);
        const win = p.win;
        const px = try win.backBuffer();
        const bw = win.width;
        const bh = win.height;
        @memset(px, 0);
        const ox: i32 = @intFromFloat(@round(pad * k));
        // the picture plus its chrome, opaque, then placed rounded
        const card = try p.gpa.alloc(u32, @as(usize, pw) * ph);
        defer p.gpa.free(card);
        @memset(card, 0xFF000000);
        for (card, p.scaled) |*d, s| d.* = effects.over(d.*, s);
        var cv = fui.Canvas.init(card, pw, ph);
        if (p.hover) p.drawHoverChrome(&cv, k, pw, ph);
        if (show_hint) drawTopHint(&cv, k, pw, ph);
        fui.placeCard(px, bw, bh, card, pw, ph, ox, ox, @intFromFloat(radius * k), @intFromFloat(@max(1, 10 * k)));
        const a = p.fadeIn(sys.monoMs());
        if (a < 1) fui.fadeAlpha(px, a);
        fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
        try win.present();
    }

    /// The close button and, away from 100%, the zoom level.
    fn drawHoverChrome(p: *const Pin, cv: *fui.Canvas, k: f64, pw: u32, ph: u32) void {
        const r = 11 * k;
        const cx = @as(f64, @floatFromInt(pw)) - 8 * k - r;
        const cy = 8 * k + r;
        cv.fillCircleAA(cx, cy, r, if (p.hover_close) 0xD0000000 else 0x99000000);
        fui.icon(cv, .close, cx, cy, 12 * k, 0xFFFFFFFF);
        if (p.zoom == 1) return;
        var zb: [16]u8 = undefined;
        const zs = std.fmt.bufPrint(&zb, "{d}%", .{@as(u32, @intFromFloat(@round(p.zoom * 100)))}) catch "";
        const tw = text.widthStyled(11 * k, text.Style.regular.num(), zs) + @as(i32, @intFromFloat(12 * k));
        const th: i32 = @intFromFloat(20 * k);
        cv.fillRoundRectAA(@intFromFloat(8 * k), @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(8 * k)), tw, th, 10 * k, 0x99000000);
        fui.textCentered(cv, .{ .x = @intFromFloat(8 * k), .y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(8 * k)), .w = tw, .h = th }, 11 * k, 0xFFFFFFFF, text.Style.regular.num(), zs);
    }

    fn drawTopHint(cv: *fui.Canvas, k: f64, pw: u32, ph: u32) void {
        const msg = "Right-click: Always on Top";
        const tw = text.width(11 * k, msg) + @as(i32, @intFromFloat(16 * k));
        const th: i32 = @intFromFloat(22 * k);
        const x = @divTrunc(@as(i32, @intCast(pw)) - tw, 2);
        const y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(10 * k));
        cv.fillRoundRectAA(x, y, tw, th, 11 * k, 0xCC000000);
        fui.textCentered(cv, .{ .x = x, .y = y, .w = tw, .h = th }, 11 * k, 0xFFFFFFFF, .regular, msg);
    }

    /// Handles one event; true when the pin should close.
    fn handle(p: *Pin, ev: window.InputEvent, k: f64) !bool {
        switch (ev) {
            .close => return true,
            .resize, .frame_done => p.dirty = true,
            .key => |key| if (key.pressed) return p.onKey(key.code),
            .pointer_axis => |a| p.onAxis(if (a.value120) |n| @as(f64, @floatFromInt(n)) / 120.0 else a.value / 10.0),
            .pointer_motion => |m| try p.onMotion(m.x, m.y, k),
            .pointer_button => |b| return p.onButton(b.button, b.pressed, b.x, b.y, k),
        }
        return false;
    }

    fn setZoom(p: *Pin, z: f64) void {
        p.zoom = z;
        p.dirty = true;
    }

    fn onKey(p: *Pin, code: window.KeyCode) bool {
        switch (code) {
            .escape => return true,
            .minus, .kp_minus => p.setZoom(zoomStep(p.zoom, 1)), // - zooms out
            .equal, .kp_plus => p.setZoom(zoomStep(p.zoom, -1)), // = + zooms in
            .digit_0 => p.setZoom(1), // 0: 100%
            else => {},
        }
        return false;
    }

    fn onAxis(p: *Pin, v: f64) void {
        p.scroll_acc += v;
        const steps: i32 = @intFromFloat(@trunc(p.scroll_acc));
        if (steps == 0) return;
        p.scroll_acc -= @floatFromInt(steps);
        p.setZoom(zoomStep(p.zoom, steps));
    }

    fn onMotion(p: *Pin, x: f64, y: f64, k: f64) !void {
        const inside = x >= 0;
        const ox = pad * k;
        const r = 11 * k;
        const cx = ox + @as(f64, @floatFromInt(p.scaled_w)) - 8 * k - r;
        const cy = ox + 8 * k + r;
        const hc = inside and (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r * 1.4;
        if (inside != p.hover or hc != p.hover_close) p.dirty = true;
        p.hover = inside;
        p.hover_close = hc;
        if (p.drag_from) |from| try p.dragTo(from, inside, x, y, k);
    }

    /// Layer shell: follows the pointer by moving the margins. Positions
    /// on the pin cannot say how far the pointer went: the pin moves under
    /// it with a delay, and compositors differ on which place a held
    /// button's motion is relative to (sway: where the press happened).
    /// Relative pointer motion is the pointer's own.
    fn dragTo(p: *Pin, from: [2]f64, inside: bool, x: f64, y: f64, k: f64) !void {
        const rel = p.win.takeRelative() orelse .{ 0, 0 };
        // absolute devices (tablets; KWin's fake input) may move the
        // pointer without relative motion: then go by positions, which
        // KWin gives relative to where the pin is now
        if (rel[0] != 0 or rel[1] != 0) p.drag_rel = true;
        if (p.drag_rel) {
            p.drag_at[0] += rel[1];
            p.drag_at[1] += rel[0];
        } else if (inside) {
            p.drag_at[0] += (y - from[1]) / k;
            p.drag_at[1] += (x - from[0]) / k;
        }
        const top: i32 = @intFromFloat(@round(p.drag_at[0]));
        const left: i32 = @intFromFloat(@round(p.drag_at[1]));
        if (top != p.margin[0] or left != p.margin[3]) {
            p.margin[0] = top;
            p.margin[3] = left;
            try p.win.setLayerPlacement(0, p.lw, p.lh, p.margin);
        }
    }

    fn onButton(p: *Pin, button: window.Button, pressed: bool, x: f64, y: f64, k: f64) !bool {
        if (button == .left and pressed) {
            if (p.hover_close) return true;
            if (p.layer) {
                p.drag_from = .{ x, y };
                p.drag_at = .{ @floatFromInt(p.margin[0]), @floatFromInt(p.margin[3]) };
                p.drag_rel = false;
                _ = p.win.takeRelative();
            } else try p.win.startMoveOf(0);
        } else if (button == .left) {
            p.drag_from = null;
        } else if (button == .right and pressed) {
            try p.win.showWindowMenu(0, @intFromFloat(x / k), @intFromFloat(y / k));
        } else if (button == .middle and pressed) {
            return true;
        }
        return false;
    }
};
