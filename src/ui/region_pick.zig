//! A picker over a frozen capture, on one fullscreen surface per monitor:
//!
//! - `.region`: drag out a region, then Start (or Enter) confirms it, for
//!   the scrolling capture;
//! - `.window`: the given rectangles (windows) are outlined, the one under
//!   the pointer lights up, a click picks it.
//!
//! Esc, a right click or closing the surfaces cancels. Everything is in
//! the capture's image pixels.

const std = @import("std");
const capture = @import("../app/capture.zig");
const geom = @import("../app/modes/geom.zig");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const view_mod = @import("view.zig");
const window = @import("window.zig");
const Rect = geom.Rect;
const View = view_mod.View;

pub const Kind = union(enum) {
    region: struct { label: []const u8 = "Start" },
    window: []const Rect,
};

pub const Result = union(enum) {
    cancelled,
    region: Rect,
    /// the index of the rectangle picked
    window: usize,
};

const accent: u32 = 0xFF0A84FF;
const pill_bg: u32 = 0xE01C1C1E;
const dim_keep: u32 = 0x5A; // of 255, kept outside the selection: about 65% dim

const Pane = struct {
    view: View = .{},
    bright: []u32 = &.{},
    dimmed: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    fn deinit(self: *Pane, gpa: std.mem.Allocator) void {
        gpa.free(self.bright);
        gpa.free(self.dimmed);
        self.* = .{};
    }
};

pub const Picker = struct {
    gpa: std.mem.Allocator,
    win: *window.Window,
    cap: *const capture.Capture,
    kind: Kind,
    panes: [window.max_surfaces]Pane = @splat(.{}),
    sel: ?Rect = null,
    anchor: ?[2]i32 = null,
    hovered: ?usize = null,
    /// the Start pill, buffer pixels of the surface it is on
    start_btn: ?struct { surface: u8, r: Rect } = null,
    dirty: bool = true,

    pub fn deinit(self: *Picker) void {
        for (&self.panes) |*p| p.deinit(self.gpa);
    }

    fn scale(self: *const Picker, i: usize) f64 {
        return @as(f64, @floatFromInt(self.win.surfaceList()[i].scale120)) / 120.0;
    }

    /// The view of surface i: its monitor's part of the image.
    fn viewFor(self: *const Picker, i: usize, w: u32, h: u32) View {
        const sf = self.win.surfaceList()[i];
        for (self.cap.monitors) |m| {
            const l = m.logical orelse continue;
            if (l.x == sf.x and l.y == sf.y and l.w == sf.out_w and l.h == sf.out_h)
                return view_mod.monitorView(.{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) }, w, h);
        }
        return View.fit(self.cap.image.width, self.cap.image.height, .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) }, 8);
    }

    fn prepare(self: *Picker, i: usize, w: u32, h: u32) !void {
        const p = &self.panes[i];
        p.deinit(self.gpa);
        if (w == 0 or h == 0) return;
        p.w = w;
        p.h = h;
        p.view = self.viewFor(i, w, h);
        p.bright = try self.gpa.alloc(u32, @as(usize, w) * h);
        p.dimmed = try self.gpa.alloc(u32, p.bright.len);
        const img = &self.cap.image;
        view_mod.resample(img.pixels, img.width, img.height, p.view, p.bright, w, h, .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) });
        for (p.dimmed, p.bright) |*d, b| d.* = dimmed(b);
    }

    fn dimmed(px: u32) u32 {
        var out: u32 = 0xFF000000;
        inline for (.{ 0, 8, 16 }) |sh| out |= (((px >> sh) & 0xFF) * dim_keep / 255) << sh;
        return out;
    }

    fn paint(self: *Picker, i: usize) !void {
        const p = &self.panes[i];
        if (p.w == 0) return;
        const px = try self.win.backBufferOf(@intCast(i));
        @memcpy(px, p.dimmed);
        var cv = render.Canvas.init(px, p.w, p.h);
        const k = self.scale(i);
        switch (self.kind) {
            .region => |r| self.paintRegion(i, &cv, k, r.label),
            .window => |rects| self.paintWindows(i, &cv, k, rects),
        }
        try self.win.presentSurface(@intCast(i));
    }

    fn toBuf(p: *const Pane, r: Rect) Rect {
        const b = p.view.rectToBuf(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
        return .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
    }

    fn paintRegion(self: *Picker, i: usize, cv: *render.Canvas, k: f64, label: []const u8) void {
        const p = &self.panes[i];
        if (self.sel) |s| {
            const b = toBuf(p, s);
            // the selection shows the screen as it is
            if (Rect.intersect(b, .{ .x = 0, .y = 0, .w = @intCast(p.w), .h = @intCast(p.h) })) |c| for (@intCast(c.y)..@intCast(c.y + c.h)) |y| {
                const row = y * @as(usize, p.w) + @as(usize, @intCast(c.x));
                @memcpy(cv.px[row..][0..@intCast(c.w)], p.bright[row..][0..@intCast(c.w)]);
            };
            cv.rectOutline(b.x - 2, b.y - 2, b.w + 4, b.h + 4, @max(2, @as(i32, @intFromFloat(2 * k))), accent);
            if (self.anchor == null) self.drawStart(i, cv, k, b, label);
        }
        if (self.sel == null) self.drawHint(cv, k, "Drag over what to scroll \u{00b7} Esc to cancel");
    }

    fn drawStart(self: *Picker, i: usize, cv: *render.Canvas, k: f64, b: Rect, label: []const u8) void {
        const p = &self.panes[i];
        const fs = 14 * k;
        const w = text.widthStyled(fs, .bold, label) + @as(i32, @intFromFloat(36 * k));
        const h: i32 = @intFromFloat(34 * k);
        var y = b.y + b.h + @as(i32, @intFromFloat(10 * k));
        if (y + h > @as(i32, @intCast(p.h))) y = b.y + b.h - h - @as(i32, @intFromFloat(10 * k));
        const x = std.math.clamp(b.x + @divTrunc(b.w - w, 2), 0, @max(0, @as(i32, @intCast(p.w)) - w));
        cv.fillRoundRectAA(x, y, w, h, @floatFromInt(@divTrunc(h, 2)), accent);
        const ty = y + @divTrunc(h - text.heightStyled(fs, .bold), 2);
        text.drawStyled(cv, x + @divTrunc(w - text.widthStyled(fs, .bold, label), 2), ty, fs, 0xFFFFFFFF, .bold, label);
        self.start_btn = .{ .surface = @intCast(i), .r = .{ .x = x, .y = y, .w = w, .h = h } };
    }

    fn drawHint(self: *Picker, cv: *render.Canvas, k: f64, msg: []const u8) void {
        _ = self;
        const fs = 13 * k;
        const w = text.width(fs, msg) + @as(i32, @intFromFloat(32 * k));
        const h: i32 = @intFromFloat(32 * k);
        const x = @divTrunc(cv.w - w, 2);
        const y: i32 = @intFromFloat(28 * k);
        cv.fillRoundRectAA(x, y, w, h, @floatFromInt(@divTrunc(h, 2)), pill_bg);
        text.draw(cv, x + @as(i32, @intFromFloat(16 * k)), y + @divTrunc(h - text.height(fs), 2), fs, 0xFFF5F5F7, msg);
    }

    fn paintWindows(self: *Picker, i: usize, cv: *render.Canvas, k: f64, rects: []const Rect) void {
        const p = &self.panes[i];
        for (rects) |r| {
            const b = toBuf(p, r);
            cv.rectOutline(b.x, b.y, b.w, b.h, 1, 0x99FFFFFF);
        }
        if (self.hovered) |h| {
            const b = toBuf(p, rects[h]);
            if (Rect.intersect(b, .{ .x = 0, .y = 0, .w = @intCast(p.w), .h = @intCast(p.h) })) |c| for (@intCast(c.y)..@intCast(c.y + c.h)) |y| {
                const row = y * @as(usize, p.w) + @as(usize, @intCast(c.x));
                @memcpy(cv.px[row..][0..@intCast(c.w)], p.bright[row..][0..@intCast(c.w)]);
            };
            cv.rectOutline(b.x, b.y, b.w, b.h, @max(3, @as(i32, @intFromFloat(3 * k))), accent);
        }
        self.drawHint(cv, k, "Click a window to capture it \u{00b7} Esc to cancel");
    }

    fn imgAt(self: *const Picker, surface: u8, x: f64, y: f64) [2]i32 {
        const v = self.panes[surface].view;
        const pt = v.toImgEdge(.{ .x = @intFromFloat(x), .y = @intFromFloat(y) });
        const iw: i32 = @intCast(self.cap.image.width);
        const ih: i32 = @intCast(self.cap.image.height);
        return .{ std.math.clamp(pt.x, 0, iw), std.math.clamp(pt.y, 0, ih) };
    }

    fn onMotion(self: *Picker, surface: u8, x: f64, y: f64) void {
        const pt = self.imgAt(surface, x, y);
        switch (self.kind) {
            .region => if (self.anchor) |a| {
                self.sel = .{ .x = @min(a[0], pt[0]), .y = @min(a[1], pt[1]), .w = @intCast(@abs(pt[0] - a[0])), .h = @intCast(@abs(pt[1] - a[1])) };
                self.dirty = true;
            },
            .window => |rects| {
                var hit: ?usize = null;
                for (rects, 0..) |r, i| if (r.contains(pt[0], pt[1])) {
                    hit = i;
                    break;
                };
                if (hit != self.hovered) self.dirty = true;
                self.hovered = hit;
            },
        }
    }

    fn onStart(self: *const Picker, surface: u8, x: f64, y: f64) bool {
        const b = self.start_btn orelse return false;
        return b.surface == surface and b.r.contains(@intFromFloat(x), @intFromFloat(y));
    }

    /// A press or release: the result once the picker is done.
    fn onButton(self: *Picker, b: anytype) ?Result {
        if (b.button == window.BTN_RIGHT) return if (b.pressed) .cancelled else null;
        if (b.button != window.BTN_LEFT) return null;
        switch (self.kind) {
            .window => if (b.pressed) {
                self.onMotion(b.surface, b.x, b.y);
                if (self.hovered) |h| return .{ .window = h };
            },
            .region => if (b.pressed) {
                if (self.sel != null and self.onStart(b.surface, b.x, b.y)) return .{ .region = self.sel.? };
                self.anchor = self.imgAt(b.surface, b.x, b.y);
                self.sel = null;
                self.start_btn = null;
                self.dirty = true;
            } else if (self.anchor != null) {
                self.onMotion(b.surface, b.x, b.y);
                self.anchor = null;
                if (self.sel) |s| if (s.w < 8 or s.h < 8) {
                    self.sel = null;
                };
                self.dirty = true;
            },
        }
        return null;
    }

    fn onKey(self: *const Picker, k: window.Key) ?Result {
        if (!k.pressed) return null;
        if (k.code == window.KEY_ESC) return .cancelled;
        if (k.code == window.KEY_ENTER or k.code == window.KEY_KPENTER) if (self.sel) |s| if (self.kind == .region) return .{ .region = s };
        return null;
    }

    fn handle(self: *Picker, ev: window.InputEvent) !?Result {
        switch (ev) {
            .close => return .cancelled,
            .resize => |r| {
                try self.prepare(r.surface, r.w, r.h);
                self.dirty = true;
            },
            .frame_done => {},
            .pointer_motion => |m| if (m.x >= 0) self.onMotion(m.surface, m.x, m.y),
            .pointer_button => |b| return self.onButton(b),
            .key => |k| return self.onKey(k),
            .pointer_axis => {},
        }
        return null;
    }

    fn paintAll(self: *Picker) !void {
        if (!self.dirty) return;
        const surfs = self.win.surfaceList();
        for (surfs) |s| if (s.alive and s.frame_pending) return;
        self.dirty = false;
        for (surfs, 0..) |s, i| if (s.alive) try self.paint(i);
    }

    /// Open the surfaces and run until something is picked or cancelled;
    /// the surfaces are closed again before returning.
    pub fn run(self: *Picker, title: []const u8) !Result {
        try self.win.openOutputs(title);
        defer self.win.closeWindow();
        self.win.setCursor(if (self.kind == .region) .crosshair else .arrow) catch {};
        for (self.win.surfaceList(), 0..) |s, i| if (s.alive) try self.prepare(i, s.width, s.height);
        while (true) {
            try self.paintAll();
            const ev = (try self.win.nextEventTimeout(500)) orelse continue;
            if (try self.handle(ev)) |r| return r;
        }
    }
};

pub fn pick(gpa: std.mem.Allocator, win: *window.Window, cap: *const capture.Capture, kind: Kind) !Result {
    var p: Picker = .{ .gpa = gpa, .win = win, .cap = cap, .kind = kind };
    defer p.deinit();
    return p.run("Shotlet");
}
