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

const std = @import("std");
const env_mod = @import("env.zig");
const gnome = @import("gnome.zig");
const keep = @import("keep.zig");
const dbus = @import("../platform/dbus.zig");
const sys = @import("../platform/sys.zig");
const wl = @import("../platform/wayland.zig");
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const window = @import("../ui/window.zig");
const fui = @import("../ui/floatui.zig");
const Env = env_mod.Env;

/// shadow room around the picture, logical pixels
const pad = 14;
const radius = 8;
const hint_ms = 5000;

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

pub fn run(gpa: std.mem.Allocator, env: Env, path: []const u8) !void {
    const data = try sys.readFileAlloc(gpa, path, 512 * 1024 * 1024);
    var img = blk: {
        defer gpa.free(data);
        break :blk try png.decode(gpa, data);
    };
    defer img.deinit(gpa);
    text.init(gpa);
    defer text.deinit();

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    const layer = win.hasLayerShell();
    // a layer surface is moved by hand: follow the pointer's own motion
    win.track_relative = layer;
    var margin: [4]i32 = .{ 120, 0, 0, 120 };
    // first guess at scale 1; corrected once the real scale is known
    var lw: u32 = img.width + 2 * pad;
    var lh: u32 = img.height + 2 * pad;
    if (layer) {
        try win.open("shotlet:pin", .{ .fullscreen = false, .transparent = true, .width = lw, .height = lh, .layer = .{
            .layer = wl.zwlr_layer_shell_v1.layer_top,
            .anchor = wl.zwlr_layer_surface_v1.anchor_top | wl.zwlr_layer_surface_v1.anchor_left,
            .width = lw,
            .height = lh,
            .margin = margin,
        } });
    } else {
        try win.open("shotlet:pin", .{ .fullscreen = false, .transparent = true, .width = lw, .height = lh });
    }
    win.report_leave = true;
    win.setCursor(.arrow) catch {};

    var hint = false;
    if (!layer and gnome.isGnome()) {
        if (dbus.Connection.connectSession(gpa, env.bus_addr)) |bus_c| {
            var bus = bus_c;
            defer bus.deinit();
            hint = !gnome.extensionActive(&bus);
        } else |_| hint = true;
    }
    std.log.info("pin: showing {s} ({d}x{d}, {s})", .{ path, img.width, img.height, if (layer) "layer shell" else if (hint) "plain window" else "kept above by the GNOME extension" });

    var zoom: f64 = 1;
    var scaled: []u32 = &.{};
    defer gpa.free(scaled);
    var scaled_w: u32 = 0;
    var scaled_h: u32 = 0;
    var hover = false;
    var hover_close = false;
    var dirty = true;
    var scroll_acc: f64 = 0;
    // layer shell: a drag in progress, from this pointer position (only
    // without relative pointer events), and the margins (top, left) it
    // has moved the pin to, unrounded
    var drag_from: ?[2]f64 = null;
    var drag_at: [2]f64 = .{ 0, 0 };
    const born = sys.monoMs();
    var last_f: f64 = 0;

    while (true) {
        const k = @as(f64, @floatFromInt(win.scale120)) / 120.0;
        // the picture's size on screen: image pixels * zoom, in buffer pixels
        const pw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.width)) * zoom))));
        const ph: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.height)) * zoom))));
        const want_w: u32 = @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(pw)) / k))) + 2 * pad;
        const want_h: u32 = @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(ph)) / k))) + 2 * pad;
        if (want_w != lw or want_h != lh or k != last_f) {
            lw = want_w;
            lh = want_h;
            last_f = k;
            if (layer) try win.setLayerPlacement(0, lw, lh, margin) else try win.resizeTo(0, lw, lh);
            try win.setWindowGeometry(0, .{ .x = pad, .y = pad, .w = @intCast(lw - 2 * pad), .h = @intCast(lh - 2 * pad) });
            const p: i32 = pad;
            try win.setInputRegion(0, &.{.{ .x = p, .y = p, .w = @intCast(lw - 2 * pad), .h = @intCast(lh - 2 * pad) }});
            dirty = true;
        }
        const show_hint = hint and sys.monoMs() - born < hint_ms;

        if (dirty and !win.frame_pending and win.width > 0) {
            dirty = false;
            if (scaled_w != pw or scaled_h != ph) {
                gpa.free(scaled);
                scaled = &.{};
                scaled = try gpa.alloc(u32, @as(usize, pw) * ph);
                keep.scaleInto(img.pixels, img.width, img.height, scaled, pw, ph);
                scaled_w = pw;
                scaled_h = ph;
            }
            const px = try win.backBuffer();
            const bw = win.width;
            const bh = win.height;
            @memset(px, 0);
            const ox: i32 = @intFromFloat(@round(pad * k));
            // the picture plus its chrome, opaque, then placed rounded
            const card = try gpa.alloc(u32, @as(usize, pw) * ph);
            defer gpa.free(card);
            @memset(card, 0xFF000000);
            for (card, scaled) |*d, s| d.* = effects.over(d.*, s);
            var cv = fui.Canvas.init(card, pw, ph);
            if (hover or show_hint) {
                const r = 11 * k;
                const cx = @as(f64, @floatFromInt(pw)) - 8 * k - r;
                const cy = 8 * k + r;
                if (hover) {
                    cv.fillCircleAA(cx, cy, r, if (hover_close) 0xD0000000 else 0x99000000);
                    fui.icon(&cv, .close, cx, cy, 12 * k, 0xFFFFFFFF);
                    var zb: [16]u8 = undefined;
                    const zs = std.fmt.bufPrint(&zb, "{d}%", .{@as(u32, @intFromFloat(@round(zoom * 100)))}) catch "";
                    if (zoom != 1) {
                        const tw = text.width(11 * k, zs) + @as(i32, @intFromFloat(12 * k));
                        const th: i32 = @intFromFloat(20 * k);
                        cv.fillRoundRectAA(@intFromFloat(8 * k), @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(8 * k)), tw, th, 10 * k, 0x99000000);
                        fui.textCentered(&cv, .{ .x = @intFromFloat(8 * k), .y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(8 * k)), .w = tw, .h = th }, 11 * k, 0xFFFFFFFF, .regular, zs);
                    }
                }
                if (show_hint) {
                    const msg = "Right-click: Always on Top";
                    const tw = text.width(11 * k, msg) + @as(i32, @intFromFloat(16 * k));
                    const th: i32 = @intFromFloat(22 * k);
                    const x = @divTrunc(@as(i32, @intCast(pw)) - tw, 2);
                    const y = @as(i32, @intCast(ph)) - th - @as(i32, @intFromFloat(10 * k));
                    cv.fillRoundRectAA(x, y, tw, th, 11 * k, 0xCC000000);
                    fui.textCentered(&cv, .{ .x = x, .y = y, .w = tw, .h = th }, 11 * k, 0xFFFFFFFF, .regular, msg);
                }
            }
            fui.placeCard(px, bw, bh, card, pw, ph, ox, ox, @intFromFloat(radius * k), @intFromFloat(@max(1, 10 * k)));
            fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
            try win.present();
        }

        const ev = (try win.nextEventTimeout(if (show_hint) 250 else 1000)) orelse {
            if (hint and !show_hint) {
                hint = false;
                dirty = true;
            }
            continue;
        };
        const ox = pad * k;
        switch (ev) {
            .close => break,
            .resize, .frame_done => dirty = true,
            .key => |key| if (key.pressed) switch (key.code) {
                window.KEY_ESC => break,
                12, 74 => { // - zooms out
                    zoom = zoomStep(zoom, 1);
                    dirty = true;
                },
                13, 78 => { // = + zooms in
                    zoom = zoomStep(zoom, -1);
                    dirty = true;
                },
                11 => { // 0: 100%
                    zoom = 1;
                    dirty = true;
                },
                else => {},
            },
            .pointer_axis => |a| {
                const v = if (a.value120) |n| @as(f64, @floatFromInt(n)) / 120.0 else a.value / 10.0;
                scroll_acc += v;
                const steps: i32 = @intFromFloat(@trunc(scroll_acc));
                if (steps != 0) {
                    scroll_acc -= @floatFromInt(steps);
                    zoom = zoomStep(zoom, steps);
                    dirty = true;
                }
            },
            .pointer_motion => |m| {
                const inside = m.x >= 0;
                const r = 11 * k;
                const cx = ox + @as(f64, @floatFromInt(scaled_w)) - 8 * k - r;
                const cy = ox + 8 * k + r;
                const hc = inside and (m.x - cx) * (m.x - cx) + (m.y - cy) * (m.y - cy) <= r * r * 1.4;
                if (inside != hover or hc != hover_close) dirty = true;
                hover = inside;
                hover_close = hc;
                // layer shell: follow the pointer by moving the margins.
                // Positions on the pin cannot say how far the pointer went:
                // the pin moves under it with a delay, and compositors
                // differ on which place a held button's motion is relative
                // to (sway: where the press happened). Relative pointer
                // motion is the pointer's own.
                if (drag_from) |from| {
                    if (win.takeRelative()) |d| {
                        drag_at[0] += d[1];
                        drag_at[1] += d[0];
                    } else if (inside) {
                        drag_at[0] += (m.y - from[1]) / k;
                        drag_at[1] += (m.x - from[0]) / k;
                    }
                    const top: i32 = @intFromFloat(@round(drag_at[0]));
                    const left: i32 = @intFromFloat(@round(drag_at[1]));
                    if (top != margin[0] or left != margin[3]) {
                        margin[0] = top;
                        margin[3] = left;
                        try win.setLayerPlacement(0, lw, lh, margin);
                    }
                }
            },
            .pointer_button => |b| {
                if (b.button == window.BTN_LEFT and b.pressed) {
                    if (hover_close) break;
                    if (layer) {
                        drag_from = .{ b.x, b.y };
                        drag_at = .{ @floatFromInt(margin[0]), @floatFromInt(margin[3]) };
                        _ = win.takeRelative();
                    } else try win.startMoveOf(0);
                } else if (b.button == window.BTN_LEFT) {
                    drag_from = null;
                } else if (b.button == window.BTN_RIGHT and b.pressed) {
                    try win.showWindowMenu(0, @intFromFloat(b.x / k), @intFromFloat(b.y / k));
                } else if (b.button == window.BTN_MIDDLE and b.pressed) {
                    break;
                }
            },
        }
    }
    std.log.info("pin: closed", .{});
}
