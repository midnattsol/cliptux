//! The drawn frame of the ordinary windows (Settings, Trim): the content
//! goes into an opaque buffer and is placed with rounded corners, a
//! hairline edge and a soft shadow on a see-through surface, as the
//! history panel and the pins are. GNOME draws no decorations for us, so
//! this is the window's whole frame. The window geometry and the input
//! region are the content alone: the compositor snaps, tiles and
//! hit-tests the window proper, never its shadow.
//!
//! Stable API:
//!   pad                       shadow room around the content (logical px)
//!   outer(w, h)               the surface size for w x h of content
//!   Frame.begin(gpa, win)     the content's canvas for the next frame
//!   Frame.present(win, edge)  frame the content and present it
//!   Frame.toContent(win, x)   a surface coordinate (buffer px) in content px
//!   Frame.deinit(gpa)
//! Open the window with .transparent = true at outer(w, h).

const std = @import("std");
const window = @import("../platform/linux/window.zig");
const render = @import("../gfx/render.zig");
const effects = @import("../gfx/effects.zig");
const shapes = @import("shapes.zig");
const fui = @import("floatui.zig");
const theme = @import("theme.zig");

const Window = window.Window;
const Canvas = render.Canvas;

pub const pad = 20;
/// as the history panel: a little rounder than the cards inside
const radius = theme.popover_radius;
const shadow_blur = 14;

pub fn outer(w: u32, h: u32) [2]u32 {
    return .{ w + 2 * pad, h + 2 * pad };
}

pub const Frame = struct {
    content: []u32 = &.{},
    cw: u32 = 0,
    ch: u32 = 0,
    /// the shadow alone, for the current surface size
    shade: []u32 = &.{},
    shade_w: u32 = 0,
    shade_h: u32 = 0,
    /// the logical size the window geometry was set for
    geom: [2]u32 = .{ 0, 0 },

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.shade);
        self.* = .{};
    }

    fn scale(win: *const Window) f64 {
        return @as(f64, @floatFromInt(win.scale120)) / 120.0;
    }

    fn padPx(win: *const Window) u32 {
        return @intFromFloat(@round(pad * scale(win)));
    }

    /// A surface coordinate (buffer pixels) in content pixels.
    pub fn toContent(win: *const Window, v: f64) f64 {
        return v - @as(f64, @floatFromInt(padPx(win)));
    }

    /// The content's canvas for this frame (its size follows the window).
    pub fn begin(self: *Frame, gpa: std.mem.Allocator, win: *Window) !Canvas {
        try self.syncGeometry(win);
        const p = 2 * padPx(win);
        const cw = win.width -| p;
        const ch = win.height -| p;
        if (cw != self.cw or ch != self.ch) {
            gpa.free(self.content);
            self.content = &.{};
            self.content = try gpa.alloc(u32, @as(usize, cw) * ch);
            self.cw = cw;
            self.ch = ch;
        }
        try self.ensureShade(gpa, win);
        return Canvas.init(self.content, cw, ch);
    }

    /// Only the content is the window: for snapping, tiling and input.
    fn syncGeometry(self: *Frame, win: *Window) !void {
        const s = win.surfaceList()[0];
        if (s.logical_w == self.geom[0] and s.logical_h == self.geom[1]) return;
        self.geom = .{ s.logical_w, s.logical_h };
        const r: window.Rect = .{ .x = pad, .y = pad, .w = @intCast(s.logical_w -| 2 * pad), .h = @intCast(s.logical_h -| 2 * pad) };
        try win.setWindowGeometry(0, r);
        try win.setInputRegion(0, &.{r});
    }

    fn ensureShade(self: *Frame, gpa: std.mem.Allocator, win: *const Window) !void {
        if (self.shade_w == win.width and self.shade_h == win.height) return;
        gpa.free(self.shade);
        self.shade = &.{};
        self.shade = try gpa.alloc(u32, @as(usize, win.width) * win.height);
        self.shade_w = win.width;
        self.shade_h = win.height;
        @memset(self.shade, 0);
        const p: i32 = @intCast(padPx(win));
        const b: u32 = @intFromFloat(@round(shadow_blur * scale(win)));
        effects.dropShadow(self.shade, win.width, win.height, .{ .x = p, .y = p, .w = @intCast(self.cw), .h = @intCast(self.ch) }, b, @intCast(b / 3), fui.shadow);
    }

    /// Edge the content with `edge`, round it onto the shadow and present.
    pub fn present(self: *Frame, win: *Window, edge: u32) !void {
        const k = scale(win);
        var cv = Canvas.init(self.content, self.cw, self.ch);
        const rad = radius * k;
        shapes.roundRectRing(&cv, .{ .x = 0, .y = 0, .w = @intCast(self.cw), .h = @intCast(self.ch) }, rad, @max(1, @round(k)), edge);
        const px = try win.backBuffer();
        @memcpy(px, self.shade[0..px.len]);
        const p: i32 = @intCast(padPx(win));
        effects.blitRounded(px, win.width, win.height, self.content, self.cw, self.ch, p, p, @intFromFloat(@round(rad)));
        fui.premultiply(px, win.width, win.height, .{ .x = 0, .y = 0, .w = @intCast(win.width), .h = @intCast(win.height) });
        try win.present();
    }
};

test "the surface is the content plus room for the shadow" {
    const o = outer(720, 372);
    try std.testing.expectEqual(@as(u32, 720 + 2 * pad), o[0]);
    try std.testing.expectEqual(@as(u32, 372 + 2 * pad), o[1]);
}
