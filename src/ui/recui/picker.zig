//! The record picker: the frozen desktop, one fullscreen surface per
//! monitor, dimmed outside the chosen area; drag an area (or click for
//! the whole monitor), move and resize it, and pick the format and sound
//! on the bar under it (picker_bar.zig). Enter or Record starts, Esc
//! cancels. Works in logical desktop pixels (what recordings use). It
//! opens on the frozen desktop as it looked and dims in, and eases back
//! to it before closing (the GNOME extension turns mutter's zoom off).

const std = @import("std");
const capture = @import("../../app/capture.zig");
const env_mod = @import("../../app/env.zig");
const window = @import("../../platform/api.zig").window;
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const yuv = @import("../../encode/yuv.zig");
const settings_mod = @import("../../record/settings.zig");
const selmod = @import("picker_sel.zig");
const bar = @import("picker_bar.zig");
const motion = @import("../motion.zig");
const theme = @import("../theme.zig");
const mixRows = @import("../../gfx/effects.zig").mixRows;
const dim = @import("../dim.zig");
const selchrome = @import("../selchrome.zig");
const shapes = @import("../shapes.zig");
const Rect = selmod.Rect;
const Point = selmod.Point;

pub const Result = union(enum) { area: Rect, cancelled };

const Pane = struct {
    /// the monitor's logical rectangle
    rect: Rect,
    /// the image part showing it
    src: capture.Monitor,
    base: []u32 = &.{},
    bw: u32 = 0,
    bh: u32 = 0,
};

pub const Picker = struct {
    gpa: std.mem.Allocator,
    win: window.Window,
    cap: *const capture.Capture,
    panes: [window.max_surfaces]Pane = undefined,
    mon_rects: [window.max_surfaces]Rect = undefined,
    n: usize = 0,
    sel: selmod.Selection,
    st: bar.State,
    /// the bar, in logical desktop pixels (null: not shown)
    bar_at: ?Point = null,
    mouse: Point = .{ .x = 0, .y = 0 },
    /// the mid-edge handle showing under the pointer, for repaints
    edge_handle: ?usize = null,
    /// of 256, what the dim outside the area keeps (ui/dim.zig)
    dim_keep: u32 = 256,
    pressed_bar: ?bar.Item = null,
    dirty: bool = true,
    result: ?Result = null,
    /// first frame drawn, and the fade out begun (0: not yet)
    shown_ms: i64 = 0,
    leaving_ms: i64 = 0,

    pub fn deinit(self: *Picker) void {
        for (self.panes[0..self.n]) |p| self.gpa.free(p.base);
        self.win.deinit();
    }

    fn setup(self: *Picker) void {
        const surfs = self.win.surfaceList();
        self.n = @min(surfs.len, self.panes.len);
        for (surfs[0..self.n], 0..) |s, i| {
            const r: Rect = if (s.out_w > 0) .{ .x = s.x, .y = s.y, .w = @intCast(s.out_w), .h = @intCast(s.out_h) } else .{ .x = 0, .y = 0, .w = @intCast(@max(1, s.logical_w)), .h = @intCast(@max(1, s.logical_h)) };
            self.panes[i] = .{ .rect = r, .src = self.sourceFor(r) };
            self.mon_rects[i] = r;
        }
        self.sel.monitors = self.mon_rects[0..self.n];
    }

    /// The captured monitor shown on the surface at logical `r`.
    fn sourceFor(self: *const Picker, r: Rect) capture.Monitor {
        for (self.cap.monitors) |m| if (m.logical) |l| {
            if (l.x == r.x and l.y == r.y) return m;
        };
        return self.cap.monitors[0];
    }

    fn paneAt(self: *const Picker, p: Point) usize {
        for (self.panes[0..self.n], 0..) |pane, i| if (selmod.inside(pane.rect, p)) return i;
        return 0;
    }

    fn toLogical(self: *const Picker, surface: u8, x: f64, y: f64) Point {
        const i = @min(surface, self.n - 1);
        const p = self.panes[i];
        const sx = @as(f64, @floatFromInt(p.rect.w)) / @as(f64, @floatFromInt(@max(1, p.bw)));
        const sy = @as(f64, @floatFromInt(p.rect.h)) / @as(f64, @floatFromInt(@max(1, p.bh)));
        return .{ .x = p.rect.x + @as(i32, @intFromFloat(@round(x * sx))), .y = p.rect.y + @as(i32, @intFromFloat(@round(y * sy))) };
    }

    fn scaleOf(self: *const Picker, i: usize) f64 {
        return @as(f64, @floatFromInt(self.panes[i].bw)) / @as(f64, @floatFromInt(@max(1, self.panes[i].rect.w)));
    }

    // --- events

    fn onEvent(self: *Picker, ev: window.InputEvent) !void {
        switch (ev) {
            .resize => |r| try self.onResize(r.surface, r.w, r.h),
            .frame_done => {},
            .close => self.result = .cancelled,
            .pointer_motion => |m| self.onMotion(self.toLogical(m.surface, m.x, m.y)),
            .pointer_button => |b| {
                const p = self.toLogical(b.surface, b.x, b.y);
                if (b.button == .right and b.pressed) self.result = .cancelled;
                if (b.button != .left) return;
                if (b.pressed) self.onPress(p) else self.onRelease(p);
                self.win.setCursor(self.cursorAt(p)) catch {};
            },
            .key => |k| if (k.pressed) self.onKey(k),
            .pointer_axis => {},
        }
    }

    fn onResize(self: *Picker, surface: u8, w: u32, h: u32) !void {
        if (surface >= self.n) return;
        const p = &self.panes[surface];
        if (w == 0 or h == 0) return;
        self.gpa.free(p.base);
        p.base = &.{};
        p.base = try self.gpa.alloc(u32, @as(usize, w) * h);
        const img = &self.cap.image;
        const off = p.src.y * img.width + p.src.x;
        yuv.downscale(img.pixels[off..], img.width, p.src.w, p.src.h, p.base, w, h);
        p.bw = w;
        p.bh = h;
        self.dirty = true;
    }

    fn barItemAt(self: *const Picker, p: Point) ?bar.Item {
        const at = self.bar_at orelse return null;
        return bar.hit(p.x - at.x, p.y - at.y);
    }

    fn onMotion(self: *Picker, p: Point) void {
        self.mouse = p;
        if (self.sel.drag != .none) {
            self.sel.motion(p);
            self.dirty = true;
        }
        const eh = self.edgeHandle();
        if (eh != self.edge_handle) self.dirty = true;
        self.edge_handle = eh;
        const hv = if (self.sel.drag == .none) self.barItemAt(p) else null;
        if (hv != self.st.hover) self.dirty = true;
        self.st.hover = hv;
        self.win.setCursor(self.cursorAt(p)) catch {};
    }

    /// The mid-edge handle the pointer brings out (selchrome.handleShown).
    fn edgeHandle(self: *const Picker) ?usize {
        const s = self.sel.sel orelse return null;
        for ([_]usize{ 1, 3, 5, 7 }) |i| {
            if (selchrome.handleShown(shapeRect(s), i, .{ .x = self.mouse.x, .y = self.mouse.y }, grab)) return i;
        }
        return null;
    }

    /// What the drag in progress does, else what a press at `p` would.
    fn cursorAt(self: *const Picker, p: Point) window.Cursor {
        switch (self.sel.drag) {
            .moving => return .grabbing,
            .resizing => |rz| return selchrome.handleCursor(rz.handle),
            .selecting => return .crosshair,
            .none => {},
        }
        if (self.st.hover != null or self.pressed_bar != null) return .arrow;
        if (self.sel.handleAt(p)) |h| return selchrome.handleCursor(h);
        if (self.sel.sel) |s| if (selmod.inside(s, p)) return .grab;
        return .crosshair;
    }

    fn onPress(self: *Picker, p: Point) void {
        if (self.barItemAt(p)) |it| {
            self.pressed_bar = it;
            return;
        }
        self.sel.press(p);
        self.dirty = true;
    }

    fn onRelease(self: *Picker, p: Point) void {
        if (self.pressed_bar) |it| {
            self.pressed_bar = null;
            if (self.barItemAt(p) == it) self.activate(it);
            return;
        }
        self.sel.release(p);
        self.dirty = true;
    }

    fn activate(self: *Picker, it: bar.Item) void {
        switch (it) {
            .record => if (self.sel.sel) |s| {
                self.result = .{ .area = s };
            },
            .close => self.result = .cancelled,
            else => bar.toggle(&self.st, it),
        }
        self.dirty = true;
    }

    fn onKey(self: *Picker, k: window.Key) void {
        switch (k.code) {
            .escape => self.result = .cancelled,
            .enter, .kp_enter => {
                const s = self.sel.sel orelse self.sel.monitorAt(self.mouse) orelse return;
                self.result = .{ .area = s };
            },
            else => {},
        }
    }

    // --- drawing

    fn placeBar(self: *Picker) void {
        const s = self.sel.sel orelse {
            self.bar_at = null;
            return;
        };
        if (self.sel.drag == .selecting or s.w < 4) {
            self.bar_at = null;
            return;
        }
        const sz = bar.size();
        const mon = self.panes[self.paneAt(.{ .x = s.x + @divTrunc(s.w, 2), .y = s.bottom() - 1 })].rect;
        const x = std.math.clamp(s.x + @divTrunc(s.w - sz[0], 2), mon.x + 8, @max(mon.x + 8, mon.right() - sz[0] - 8));
        var y = s.bottom() + 14;
        if (y + sz[1] + 40 > mon.bottom()) y = s.y - sz[1] - 14;
        if (y < mon.y + 8) y = s.bottom() - sz[1] - 14;
        self.bar_at = .{ .x = x, .y = y };
    }

    /// How far the dim is in, 0..256: fading in from the first frame, out
    /// once there is a result.
    fn level(self: *Picker, now: i64) u32 {
        if (!motion.enabled) return if (self.leaving_ms != 0) 0 else 256;
        if (self.shown_ms == 0) self.shown_ms = now;
        var t = motion.easeOut(@as(f64, @floatFromInt(now - self.shown_ms)) / theme.motion_fast);
        if (self.leaving_ms != 0) t = @min(t, 1 - motion.easeOut(@as(f64, @floatFromInt(now - self.leaving_ms)) / theme.motion_fast));
        return @intFromFloat(@round(@max(0, t) * 256));
    }

    /// Still fading in or out (a frame per refresh).
    fn fading(self: *const Picker) bool {
        const now = motion.now();
        if (!motion.enabled) return false;
        if (self.leaving_ms != 0) return now - self.leaving_ms < theme.motion_fast;
        return self.shown_ms == 0 or now - self.shown_ms < theme.motion_fast;
    }

    fn draw(self: *Picker) !void {
        if (self.fading()) self.dirty = true;
        if (!self.dirty) return;
        self.placeBar();
        for (0..self.n) |i| {
            const s = &self.win.surfaceList()[i];
            if (s.frame_pending or self.panes[i].bw == 0) return;
        }
        self.dirty = false;
        const k = self.level(motion.now());
        for (0..self.n) |i| try self.renderPane(@intCast(i), k);
    }

    fn bufRect(self: *const Picker, i: usize, r: Rect) Rect {
        const p = self.panes[i];
        const k = self.scaleOf(i);
        const x0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.x - p.rect.x)) * k));
        const y0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.y - p.rect.y)) * k));
        const x1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.right() - p.rect.x)) * k));
        const y1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(r.bottom() - p.rect.y)) * k));
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn renderPane(self: *Picker, i: u8, k_dim: u32) !void {
        const p = &self.panes[i];
        const px = try self.win.backBufferOf(i);
        @memcpy(px[0..p.base.len], p.base);
        var cv = render.Canvas.init(px, p.bw, p.bh);
        const k = self.scaleOf(i);
        const sb: ?Rect = if (self.sel.sel) |s| self.bufRect(i, s) else null;
        dim.outside(px[0..p.base.len], p.bw, p.bh, if (sb) |r| shapeRect(r) else null, self.dim_keep);
        if (sb) |r| self.drawSelection(i, &cv, shapeRect(r), k);
        if (self.sel.sel == null and i == self.paneAt(self.mouse)) drawHint(&cv, k, self.st.th);
        if (self.bar_at) |at| {
            const b = self.bufRect(i, .{ .x = at.x, .y = at.y, .w = 1, .h = 1 });
            if (selmod.inside(p.rect, at)) bar.paint(self.gpa, &cv, b.x, b.y, k, &self.st);
        }
        if (k_dim < 256) mixRows(px[0..p.base.len], p.base, px[0..p.base.len], k_dim);
        try self.win.presentSurface(i);
    }

    /// As the editor draws a capture's selection: the edge, the handles
    /// while nothing is dragged, the size (in recorded pixels) above it.
    fn drawSelection(self: *const Picker, i: u8, cv: *render.Canvas, r: shapes.Rect, k: f64) void {
        const th = self.st.th;
        selchrome.edge(cv, r, th);
        if (self.sel.drag == .none) {
            const m: ?shapes.Point = if (i == self.paneAt(self.mouse)) blk: {
                const b = self.bufRect(i, .{ .x = self.mouse.x, .y = self.mouse.y, .w = 1, .h = 1 });
                break :blk .{ .x = b.x, .y = b.y };
            } else null;
            selchrome.handles(cv, r, m, @max(6, @as(i32, @intFromFloat(@round(grab * k)))), k, th);
        }
        const logical = self.sel.sel.?;
        var buf: [32]u8 = undefined;
        const label = selchrome.sizeLabel(&buf, logical.w, logical.h);
        selchrome.sizePill(cv, selchrome.sizePillRect(label, r, cv.w, k), k, th, label);
    }
};

/// how near a handle the pointer grabs it, logical px (as the editor's)
const grab = 10;

fn shapeRect(r: Rect) shapes.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

fn drawHint(cv: *render.Canvas, k: f64, th: theme.Theme) void {
    const s = "Drag to choose what to record \u{00B7} click: the whole screen \u{00B7} Esc: cancel";
    const fs = 14 * k;
    const tw = text.width(fs, s) + @as(i32, @intFromFloat(32 * k));
    const hh = text.height(fs) + @as(i32, @intFromFloat(18 * k));
    const x = @divTrunc(cv.w - tw, 2);
    const y = @divTrunc(cv.h - hh, 2);
    selchrome.pill(cv, .{ .x = x, .y = y, .w = tw, .h = hh }, 12 * k, th);
    text.draw(cv, x + @as(i32, @intFromFloat(16 * k)), y + @as(i32, @intFromFloat(9 * k)), fs, th.pill_fg, s);
}

/// Show the picker over the frozen desktop `cap`; the chosen area, or
/// cancelled. `set` holds the bar's choices (format, sound, overlays);
/// `th` is the desktop's appearance.
pub fn pick(gpa: std.mem.Allocator, env: env_mod.Env, cap: *const capture.Capture, set: *settings_mod.Settings, overlays: bool, th: theme.Theme) !Result {
    var p: Picker = .{
        .gpa = gpa,
        .win = try window.Window.init(gpa, env),
        .cap = cap,
        .sel = .{ .monitors = &.{} },
        .st = .{ .set = set, .overlays = overlays, .th = th },
        .dim_keep = dim.keepFor(cap.image.pixels, cap.image.width, cap.image.height),
    };
    defer p.deinit();
    try p.win.openOutputs("Shotlet");
    p.setup();
    p.win.setCursor(.crosshair) catch {};
    while (p.result == null or p.fading()) {
        if (p.result != null and p.leaving_ms == 0) p.leaving_ms = motion.now();
        if (try p.win.nextEventTimeout(p.win.pollTimeoutMs(if (p.fading()) 8 else 100))) |ev| {
            if (p.result == null) try p.onEvent(ev);
            while (p.win.queue.items.len > 0) {
                const e = try p.win.nextEvent();
                if (p.result == null) try p.onEvent(e);
            }
        }
        try p.draw();
    }
    p.win.closeWindow();
    return p.result.?;
}
