//! The scrolling capture's control: a small glass card beside the region
//! with the stitched image growing in it, a status line and Stop.
//!
//! Its window is titled "shotlet:scroll": the GNOME extension keeps it
//! above other windows and only steps a scrolling capture while it is on
//! screen. With layer shell it is an overlay in the top-right corner.

const std = @import("std");
const wl = @import("../platform/wayland.zig");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const fui = @import("floatui.zig");
const window = @import("window.zig");
const Rect = @import("../app/modes/geom.zig").Rect;

pub const title = "shotlet:scroll";
/// logical size
pub const width = 232;
pub const height = 376;
const pad = 14;
const radius = 18;
const preview_h = 220;

pub const Action = enum { stop, cancel };

/// Rows of the image so far, for the preview.
pub const Source = struct {
    ctx: *const anyopaque,
    width: u32,
    height: u32,
    row: *const fn (ctx: *const anyopaque, y: u32) []const u32,
};

pub const Hud = struct {
    win: *window.Window,
    status: []const u8 = "Starting\u{2026}",
    detail_buf: [64]u8 = undefined,
    detail: []const u8 = "",
    stop_r: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hover_stop: bool = false,
    dirty: bool = true,

    pub fn open(win: *window.Window) !Hud {
        try win.open(title, .{ .fullscreen = false, .transparent = true, .width = width, .height = height, .layer = .{
            .anchor = wl.zwlr_layer_surface_v1.anchor_top | wl.zwlr_layer_surface_v1.anchor_right,
            .width = width,
            .height = height,
            .margin = .{ 24, 24, 0, 0 },
            .keyboard = wl.zwlr_layer_surface_v1.keyboard_on_demand,
            .namespace = "shotlet-scroll",
        } });
        win.setCursor(.arrow) catch {};
        return .{ .win = win };
    }

    pub fn setStatus(self: *Hud, status: []const u8, height_px: u32) void {
        self.status = status;
        self.detail = std.fmt.bufPrint(&self.detail_buf, "{d} px tall", .{height_px}) catch "";
        self.dirty = true;
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
        @memset(card, 0xFF1F1F22);
        var cv = render.Canvas.init(card, bw, bh);
        const x0 = self.sc(pad);
        const fs = 13 * self.k();
        text.drawStyled(&cv, x0, self.sc(pad), fs, 0xFFF5F5F7, .bold, "Scrolling capture");
        text.draw(&cv, x0, self.sc(pad + 20), 12 * self.k(), 0xFFA1A1A8, self.status);
        const pv: Rect = .{ .x = x0, .y = self.sc(pad + 44), .w = @as(i32, @intCast(bw)) - 2 * x0, .h = self.sc(preview_h) };
        cv.fillRect(pv.x, pv.y, pv.w, pv.h, 0xFF141416);
        if (src) |s| drawPreview(&cv, pv, s);
        text.draw(&cv, x0, pv.y + pv.h + self.sc(8), 12 * self.k(), 0xFFA1A1A8, self.detail);
        self.drawStop(&cv);
        const px = try self.win.backBuffer();
        @memset(px, 0);
        fui.placeCard(px, bw, bh, card, bw, bh, 0, 0, @intCast(self.sc(radius)), 0);
        fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
        try self.win.present();
    }

    fn drawStop(self: *Hud, cv: *render.Canvas) void {
        const h = self.sc(32);
        const r: Rect = .{ .x = self.sc(pad), .y = cv.h - self.sc(pad) - h, .w = cv.w - 2 * self.sc(pad), .h = h };
        cv.fillRoundRectAA(r.x, r.y, r.w, r.h, @floatFromInt(@divTrunc(h, 2)), if (self.hover_stop) 0xFF3D95FF else fui.accent);
        fui.textCentered(cv, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, 13 * self.k(), 0xFFFFFFFF, .bold, "Stop");
        self.stop_r = r;
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

    /// Wait up to `ms` for input; Stop, Enter, Esc or closing ends it.
    pub fn poll(self: *Hud, ms: i32) !?Action {
        const deadline = @import("../platform/sys.zig").monoMs() + ms;
        while (true) {
            const left = deadline - @import("../platform/sys.zig").monoMs();
            const ev = (try self.win.nextEventTimeout(@intCast(@max(0, left)))) orelse return null;
            if (self.handle(ev)) |a| return a;
            if (left <= 0) return null;
        }
    }

    fn handle(self: *Hud, ev: window.InputEvent) ?Action {
        switch (ev) {
            .close => return .cancel,
            .resize, .frame_done => self.dirty = true,
            .key => |key| if (key.pressed) switch (key.code) {
                window.KEY_ESC => return .cancel,
                window.KEY_ENTER, window.KEY_KPENTER => return .stop,
                else => {},
            },
            .pointer_motion => |m| {
                const over = self.stop_r.contains(@intFromFloat(m.x), @intFromFloat(m.y));
                if (over != self.hover_stop) self.dirty = true;
                self.hover_stop = over;
            },
            .pointer_button => |b| if (b.pressed and b.button == window.BTN_LEFT and self.stop_r.contains(@intFromFloat(b.x), @intFromFloat(b.y))) return .stop,
            else => {},
        }
        return null;
    }
};
