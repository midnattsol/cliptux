//! Interactive annotation editor: freeze-frame the screenshot fullscreen,
//! drag to select a region, annotate, then copy to clipboard or save.
//!
//! The document (shapes, selection) lives in image pixels (doc.zig). A
//! native-resolution composite `layer` holds the image with every
//! committed shape; exports crop it. The window shows the layer through a
//! `View` (view.zig) into `viewc`, a buffer-sized cache, and each frame
//! repaints only the rectangles that changed since that back buffer was
//! last drawn, then paints the chrome on top.

const std = @import("std");
const capture = @import("../app/capture.zig");
const window = @import("window.zig");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const png = @import("../gfx/png.zig");
const config = @import("../app/config.zig");
const sys = @import("../platform/sys.zig");
const shapes_mod = @import("shapes.zig");
const doc_mod = @import("doc.zig");
const view_mod = @import("view.zig");
const textedit = @import("textedit.zig");
const ui = @import("editor_ui.zig");

const Window = window.Window;
const Canvas = render.Canvas;
pub const Tool = shapes_mod.Tool;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;
const View = view_mod.View;
const palette = shapes_mod.palette;

pub const Action = enum {
    cancel,
    save,
    /// save to a path the user picks (the caller shows the dialog)
    save_as,
};

pub const CopyNotice = enum { none, copying, copied, failed };

pub const Result = struct {
    action: Action,
    /// encoded PNG of the selected region; null when action == .cancel
    png_data: ?[]u8 = null,
};

pub const dim_color: u32 = 0x8C000000;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub const DragMode = union(enum) {
    none,
    /// anchor corner, image pixels
    selecting: Point,
    moving_sel: struct { orig: Rect, start: Point },
    resizing_sel: struct { handle: u3, orig: Rect },
    drawing,
    moving_shape: struct { start: Point, applied: Point },
    resizing_shape: struct { handle: u3, orig: Shape },
    picking: ui.PickPart,
};

const TextState = struct {
    idx: usize,
    te: textedit.TextEdit,
    is_new: bool,
    /// the text before this edit, to tell whether anything changed
    orig: []u8,
};

/// A small set of dirty rectangles; overflows merge into one bounding box.
pub const RectList = struct {
    items: [64]Rect = undefined,
    len: usize = 0,

    pub fn add(self: *RectList, r: Rect) void {
        if (r.isEmpty()) return;
        if (self.len == self.items.len) {
            var u = self.items[0];
            for (self.items[1..self.len]) |x| u = Rect.unite(u, x);
            self.items[0] = u;
            self.len = 1;
        }
        self.items[self.len] = r;
        self.len += 1;
    }
    pub fn addAll(self: *RectList, other: *const RectList) void {
        for (other.items[0..other.len]) |r| self.add(r);
    }
    pub fn slice(self: *const RectList) []const Rect {
        return self.items[0..self.len];
    }
    pub fn area(self: *const RectList) i64 {
        var a: i64 = 0;
        for (self.slice()) |r| a += @as(i64, r.w) * r.h;
        return a;
    }
};

// evdev key codes
const KEY_1 = 2;
const KEY_9 = 10;
const KEY_MINUS = 12;
const KEY_EQUAL = 13;
const KEY_TAB = 15;
const KEY_LEFTBRACE = 26;
const KEY_RIGHTBRACE = 27;
const KEY_S = 31;
const KEY_D = 32;
const KEY_F = 33;
const KEY_Y = 21;
const KEY_B = 48;
const KEY_SLASH = 53;
const KEY_F1 = 59;
const KEY_KPMINUS = 74;
const KEY_KPPLUS = 78;
const KEY_KPENTER = 96;
const KEY_HOME = 102;
const KEY_UP = 103;
const KEY_LEFT = 105;
const KEY_RIGHT = 106;
const KEY_END = 107;
const KEY_DOWN = 108;

pub const Editor = struct {
    alloc: std.mem.Allocator,
    win: *Window,
    img: *const png.Image,
    doc: doc_mod.Document,

    // --- render caches ---
    view: View = .{},
    /// image + committed shapes at native resolution (minus `lifted`)
    layer: []u32 = &.{},
    /// layer as shown through `view`, buffer-sized, and a dimmed copy
    viewc: []u32 = &.{},
    viewc_dim: []u32 = &.{},
    stroke_mask: []u8 = &.{}, // scratch for Canvas strokes
    /// coverage of the freehand stroke being drawn, buffer-sized
    live_cov: []u8 = &.{},
    live_bbox: Rect = Rect.empty,
    /// beautify preview of the selection (background, shadow, corners)
    bcache: []u32 = &.{},
    bcache_rect: Rect = Rect.empty,
    bcache_valid: bool = false,
    /// per back buffer: what changed since it was last drawn
    pending: [2]RectList = .{ .{}, .{} },
    content_dirty: RectList = .{},
    overlays: RectList = .{},
    last_frame: []u32 = &.{},

    // --- tool state ---
    tool: Tool = .select,
    color_idx: u3 = 0,
    custom_active: bool = false,
    custom_color: u32 = 0xFF15AABF,
    /// logical stroke width; image pixels = thickness * ui scale / view scale
    thickness: i32 = 3,
    /// bit 0: filled (text: background pill), bit 1: rounded corners
    /// per tool, so the rectangle's fill doesn't leak into text
    styles: std.EnumArray(Tool, u2) = .initFill(0),
    beautify: doc_mod.Beautify = .{},

    cur: ?Shape = null,
    selected: ?usize = null,
    /// shape left out of `layer` and drawn live (being moved or edited)
    lifted: ?usize = null,
    text: ?TextState = null,
    drag: DragMode = .none,
    mouse: Point = .{ .x = -10000, .y = -10000 },
    scroll_acc: f64 = 0,
    last_click_ms: i64 = 0,
    last_click: Point = .{ .x = 0, .y = 0 },
    ck_kind: u8 = 0,
    ck_ms: i64 = 0,

    // --- chrome ---
    buttons: std.ArrayList(ui.Button) = .empty,
    toolbar_rect: Rect = Rect.empty,
    hover_btn: i32 = -1,
    focus: ?usize = null,
    help_open: bool = false,
    picker: ui.Picker = .{},

    needs_render: bool = true,
    running: bool = true,
    action: Action = .cancel,
    ui_init: bool = false,
    smoke_deadline_ms: i64 = 0, // dev: auto-cancel timestamp (0 = off)
    cfg_thickness: i32 = 3,
    binds: [config.n_actions]config.Bind = config.default_binds,
    copy_notice: CopyNotice = .none,
    copy_notice_hide_at_ms: i64 = 0,
    preset_sel: ?[4]i32 = null,
    script: ?[]const u8 = null,
    script_pos: usize = 0,

    /// where each captured monitor lies inside `img`; set by the caller
    monitors: []const capture.Monitor = &.{},

    pub fn init(alloc: std.mem.Allocator, win: *Window, img: *const png.Image) Editor {
        return .{ .alloc = alloc, .win = win, .img = img, .doc = doc_mod.Document.init(alloc, img.width, img.height) };
    }

    /// Dev helper: start with a selection already in place (window pixels).
    pub fn presetSelection(self: *Editor, sel: ?[4]i32) void {
        self.preset_sel = sel;
    }

    pub fn deinit(self: *Editor) void {
        if (self.text) |t| self.alloc.free(t.orig);
        self.text = null;
        if (self.cur) |*s| s.deinit(self.alloc);
        if (self.drag == .resizing_shape) self.drag.resizing_shape.orig.deinit(self.alloc);
        self.doc.deinit();
        self.buttons.deinit(self.alloc);
        self.releaseCaches();
        self.alloc.free(self.layer);
        self.layer = &.{};
    }

    /// Free the window-sized caches. Call after the editing session ends
    /// while the process stays alive (e.g. serving the clipboard).
    pub fn releaseCaches(self: *Editor) void {
        self.alloc.free(self.viewc);
        self.viewc = &.{};
        self.alloc.free(self.viewc_dim);
        self.viewc_dim = &.{};
        self.alloc.free(self.stroke_mask);
        self.stroke_mask = &.{};
        self.alloc.free(self.live_cov);
        self.live_cov = &.{};
        self.alloc.free(self.bcache);
        self.bcache = &.{};
        self.bcache_valid = false;
        self.last_frame = &.{};
    }

    pub fn color(self: *const Editor) u32 {
        return if (self.custom_active) self.custom_color else palette[self.color_idx];
    }

    /// UI scale factor from the window's fractional scale (1.0 at 100%).
    pub fn uf(self: *const Editor) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    /// Scale a logical UI length to physical pixels.
    pub fn sc(self: *const Editor, v: f64) i32 {
        return @intFromFloat(@round(v * self.uf()));
    }

    pub fn screenRect(self: *const Editor) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.win.width), .h = @intCast(self.win.height) };
    }

    /// Stroke width in image pixels for the current thickness.
    pub fn imgThickness(self: *const Editor) i32 {
        const t = @as(f64, @floatFromInt(self.thickness)) * self.uf() / self.view.scale;
        return @max(1, @as(i32, @intFromFloat(@round(t))));
    }

    fn logicalThickness(self: *const Editor, img_t: i32) i32 {
        const t = @as(f64, @floatFromInt(img_t)) * self.view.scale / self.uf();
        return std.math.clamp(@as(i32, @intFromFloat(@round(t))), 1, 32);
    }

    pub fn imgAt(self: *const Editor, b: Point) Point {
        return self.view.toImgEdge(b);
    }

    fn clampImg(self: *const Editor, p: Point) Point {
        return .{
            .x = std.math.clamp(p.x, 0, @as(i32, @intCast(self.img.width))),
            .y = std.math.clamp(p.y, 0, @as(i32, @intCast(self.img.height))),
        };
    }

    /// The selection on screen (buffer pixels).
    pub fn selBuf(self: *const Editor) ?Rect {
        const s = self.doc.sel orelse return null;
        return self.view.rectToBuf(s.normalized());
    }

    /// Image-pixel tolerance for clicking on shapes.
    fn hitTol(self: *const Editor) f64 {
        return self.view.lenToImg(@floatFromInt(self.sc(5)));
    }

    pub fn handleRadius(self: *const Editor) i32 {
        return @max(6, self.sc(10));
    }

    /// Run the editor; returns the user's chosen action and exported PNG.
    pub fn run(self: *Editor) !Result {
        if (getenv("SHOTLET_EDITOR_SCRIPT")) |s| self.script = s;
        while (self.running) {
            const now = nowMs();
            if (self.smoke_deadline_ms != 0 and now > self.smoke_deadline_ms) {
                self.action = .cancel;
                break;
            }
            if (self.copy_notice_hide_at_ms != 0 and now >= self.copy_notice_hide_at_ms) {
                self.copy_notice = .none;
                self.copy_notice_hide_at_ms = 0;
                self.needs_render = true;
            }
            const scripted = self.script != null and self.script_pos < self.script.?.len and self.viewc.len > 0;
            if (try self.win.nextEventTimeout(self.win.pollTimeoutMs(if (scripted) 5 else 100))) |ev| {
                try self.handle(ev);
                while (self.win.queue.items.len > 0) {
                    try self.handle(try self.win.nextEvent());
                }
            }
            if (self.needs_render and !self.win.frame_pending) {
                // drain buffered Wayland events to get latest pointer position
                try self.win.drainPending();
                while (self.win.queue.items.len > 0) {
                    try self.handle(try self.win.nextEvent());
                }
                try self.renderFrame();
                self.needs_render = false;
            }
            if (scripted and !self.needs_render) try self.scriptStep();
        }
        if (getenv("SHOTLET_EDITOR_DUMP")) |prefix| self.dumpAtExit(prefix);
        if (self.action == .cancel) return .{ .action = .cancel };
        return .{ .action = self.action, .png_data = try self.exportPng() };
    }

    // --- caches ---

    fn onResize(self: *Editor) !void {
        if (!self.ui_init) {
            self.ui_init = true;
            self.thickness = std.math.clamp(self.cfg_thickness, 1, 32);
        }
        const w = self.win.width;
        const h = self.win.height;
        const n: usize = @as(usize, w) * h;
        self.view = View.fit(self.img.width, self.img.height, self.screenRect(), 1.0);
        self.releaseCaches();
        self.viewc = try self.alloc.alloc(u32, n);
        self.viewc_dim = try self.alloc.alloc(u32, n);
        self.stroke_mask = try self.alloc.alloc(u8, n);
        @memset(self.stroke_mask, 0);
        self.live_cov = try self.alloc.alloc(u8, n);
        @memset(self.live_cov, 0);
        self.live_bbox = Rect.empty;
        if (self.layer.len == 0) {
            self.layer = try self.alloc.alloc(u32, self.img.pixels.len);
            try doc_mod.composeRegion(self.alloc, self.layer, self.img.pixels, self.img.width, self.img.height, self.doc.shapes.items, self.lifted, self.doc.imageRect());
        }
        if (self.preset_sel) |v| {
            self.preset_sel = null;
            const a = self.clampImg(self.imgAt(.{ .x = v[0], .y = v[1] }));
            const b = self.clampImg(self.imgAt(.{ .x = v[0] + v[2], .y = v[1] + v[3] }));
            const r = Rect.fromCorners(a, b);
            if (!r.isEmpty()) self.doc.sel = r;
        }
        self.refreshView(self.screenRect());
        for (&self.pending) |*p| {
            p.len = 0;
            p.add(self.screenRect());
        }
        self.needs_render = true;
    }

    /// Re-render `b` (buffer pixels) of the view caches from the layer.
    fn refreshView(self: *Editor, b: Rect) void {
        const r = Rect.intersect(b, self.screenRect()) orelse return;
        view_mod.resample(self.layer, self.img.width, self.img.height, self.view, self.viewc, self.win.width, self.win.height, r);
        const keep: u32 = 255 - (dim_color >> 24);
        const w: usize = self.win.width;
        var y: usize = @intCast(r.y);
        while (y < @as(usize, @intCast(r.bottom()))) : (y += 1) {
            const off = y * w + @as(usize, @intCast(r.x));
            dimRow(self.viewc[off..][0..@intCast(r.w)], self.viewc_dim[off..][0..@intCast(r.w)], keep);
        }
        self.content_dirty.add(r);
        if (self.selBuf()) |s| {
            if (Rect.intersect(s, r) != null) self.bcache_valid = false;
        }
    }

    /// Recompose image rect `r` of the layer and everything derived.
    fn recompose(self: *Editor, r: Rect) !void {
        if (self.layer.len == 0) return;
        var margin: i32 = 0;
        for (self.doc.shapes.items) |*s| margin += s.readMargin();
        const reg = r.expand(margin);
        try doc_mod.composeRegion(self.alloc, self.layer, self.img.pixels, self.img.width, self.img.height, self.doc.shapes.items, self.lifted, reg);
        if (self.viewc.len > 0) self.refreshView(self.view.rectToBufOuter(reg));
        self.needs_render = true;
    }

    fn recomposeAll(self: *Editor) !void {
        try self.recompose(self.doc.imageRect());
    }

    fn dimRow(src: []const u32, dst: []u32, keep: u32) void {
        @setRuntimeSafety(false);
        for (src, dst) |p, *d| {
            const rb = ((p & 0x00FF00FF) * keep >> 8) & 0x00FF00FF;
            const g = ((p & 0x0000FF00) * keep >> 8) & 0x0000FF00;
            d.* = 0xFF000000 | rb | g;
        }
    }

    /// Mark the on-screen selection area (or its beautify frame) dirty.
    fn selDirty(self: *Editor) void {
        if (self.selBuf()) |s| self.content_dirty.add(self.frameRect(s).expand(2));
        self.bcache_valid = false;
        self.needs_render = true;
    }

    /// The selection plus its beautify padding, on screen.
    pub fn frameRect(self: *const Editor, s: Rect) Rect {
        if (!self.beautify.enabled) return s;
        const sel = self.doc.sel.?.normalized();
        const g = self.beautify.geometry(@intCast(@max(1, sel.w)), @intCast(@max(1, sel.h)));
        const pad: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(g.pad)) * self.view.scale));
        return s.expand(pad);
    }

    fn ensureBeautyCache(self: *Editor) !void {
        if (!self.beautify.enabled or self.bcache_valid) return;
        const s = self.selBuf() orelse return;
        if (s.w < 2 or s.h < 2) return;
        const fr = self.frameRect(s);
        const old = self.bcache_rect;
        self.bcache_valid = true;
        self.bcache_rect = fr;
        const fw: u32 = @intCast(fr.w);
        const fh: u32 = @intCast(fr.h);
        self.alloc.free(self.bcache);
        self.bcache = &.{};
        self.bcache = try self.alloc.alloc(u32, @as(usize, fw) * fh);
        // the shot as shown (clipped to the screen; off-screen parts are dim)
        const sw: u32 = @intCast(s.w);
        const sh: u32 = @intCast(s.h);
        const shot = try self.alloc.alloc(u32, @as(usize, sw) * sh);
        defer self.alloc.free(shot);
        const ww: i32 = @intCast(self.win.width);
        const wh: i32 = @intCast(self.win.height);
        for (0..sh) |yy| {
            const by = std.math.clamp(s.y + @as(i32, @intCast(yy)), 0, wh - 1);
            for (0..sw) |xx| {
                const bx = std.math.clamp(s.x + @as(i32, @intCast(xx)), 0, ww - 1);
                shot[yy * sw + xx] = self.viewc[@as(usize, @intCast(by)) * self.win.width + @as(usize, @intCast(bx))];
            }
        }
        const b = self.beautify;
        // scale the frame like the export: same proportions, view pixels
        const sel = self.doc.sel.?.normalized();
        const g_img = b.geometry(@intCast(@max(1, sel.w)), @intCast(@max(1, sel.h)));
        const k = self.view.scale;
        const effects = @import("../gfx/effects.zig");
        const bg = b.background();
        effects.gradient(self.bcache, fw, fh, .{ .x = 0, .y = 0, .w = fr.w, .h = fr.h }, bg.from, bg.to);
        const pad = s.x - fr.x;
        const inner: effects.Rect = .{ .x = pad, .y = s.y - fr.y, .w = s.w, .h = s.h };
        const blur: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(g_img.shadow_blur)) * k));
        if (blur > 0) effects.dropShadow(self.bcache, fw, fh, inner, blur, @intFromFloat(@round(@as(f64, @floatFromInt(g_img.shadow_dy)) * k)), 0x70000000);
        const rad: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(g_img.radius)) * k));
        effects.blitRounded(self.bcache, fw, fh, shot, sw, sh, inner.x, inner.y, rad);
        self.content_dirty.add(old);
        self.content_dirty.add(fr);
    }

    // --- event handling ---

    pub fn handle(self: *Editor, ev: window.InputEvent) !void {
        switch (ev) {
            // other surfaces are the integrator's (one view per monitor)
            .resize => |r| if (r.surface == 0 and r.w > 0) try self.onResize(),
            .frame_done => {
                if (self.needs_render) {
                    try self.renderFrame();
                    self.needs_render = false;
                }
            },
            .close => {
                self.action = .cancel;
                self.running = false;
            },
            .pointer_motion => |m| if (m.surface == 0) {
                self.mouse = .{ .x = @intFromFloat(@round(m.x)), .y = @intFromFloat(@round(m.y)) };
                try self.onMotion();
            },
            .pointer_button => |b| {
                self.mouse = .{ .x = @intFromFloat(@round(b.x)), .y = @intFromFloat(@round(b.y)) };
                if (b.button == window.BTN_LEFT) {
                    if (b.pressed) try self.onPress() else try self.onRelease();
                } else if (b.button == window.BTN_RIGHT and b.pressed) {
                    try self.onRightClick();
                }
            },
            .pointer_axis => |a| try self.onScroll(a.value),
            .key => |k| {
                if (k.code == 0) {
                    // input method: committed text or a preedit change,
                    // never a shortcut
                    if (k.pressed and self.picker.open) {
                        if (ui.pickerKey(self, k) orelse false) try self.applyPickerColor();
                    } else if (k.pressed and self.text != null) try self.typeText(k);
                    self.needs_render = true;
                } else if (k.pressed) try self.onKey(k);
            },
        }
    }

    fn onScroll(self: *Editor, value: f64) !void {
        const steps = scrollSteps(&self.scroll_acc, value);
        if (steps != 0) try self.setThickness(self.thickness + steps);
    }

    pub fn setThickness(self: *Editor, t: i32) !void {
        const nt = std.math.clamp(t, 1, 32);
        if (nt == self.thickness) return;
        self.thickness = nt;
        self.needs_render = true;
        const it = self.imgThickness();
        try self.editTarget(1, struct {
            fn f(s: *Shape, v: i32) void {
                s.thickness = v;
            }
        }.f, it);
    }

    /// Apply `op(shape, arg)` to the text being edited or the selected
    /// shape, with undo (coalescing repeats of the same `kind`).
    fn editTarget(self: *Editor, kind: u8, comptime op: anytype, arg: anytype) !void {
        if (self.text) |t| {
            op(&self.doc.shapes.items[t.idx], arg);
            self.needs_render = true;
            return;
        }
        const i = self.selected orelse return;
        const now = nowMs();
        if (!(self.ck_kind == kind and now - self.ck_ms < 1200)) try self.doc.checkpoint();
        self.ck_kind = kind;
        self.ck_ms = now;
        const before = self.doc.shapes.items[i].bounds();
        op(&self.doc.shapes.items[i], arg);
        try self.recompose(Rect.unite(before, self.doc.shapes.items[i].bounds()));
    }

    fn breakCoalescing(self: *Editor) void {
        self.ck_kind = 0;
    }

    fn onMotion(self: *Editor) !void {
        const m = self.mouse;
        const ip = self.imgAt(m);
        switch (self.drag) {
            .none => {
                try self.win.setCursor(self.cursorFor(m));
                var hover: i32 = -1;
                if (self.toolbar_rect.contains(m.x, m.y)) {
                    for (self.buttons.items, 0..) |btn, bi| {
                        if (btn.rect.contains(m.x, m.y)) {
                            hover = @intCast(bi);
                            break;
                        }
                    }
                }
                if (hover != self.hover_btn) {
                    self.hover_btn = hover;
                    self.needs_render = true;
                }
                if (ui.loupeVisible(self)) self.needs_render = true;
            },
            .selecting => |anchor| {
                self.selDirty();
                self.doc.sel = Rect.fromCorners(anchor, self.clampImg(ip));
                self.selDirty();
            },
            .moving_sel => |mv| {
                self.selDirty();
                self.doc.sel = mv.orig;
                self.doc.moveSelection(ip.x - mv.start.x, ip.y - mv.start.y);
                self.selDirty();
            },
            .resizing_sel => |rs| {
                self.selDirty();
                self.doc.sel = shapes_mod.resizeWithHandle(rs.orig, rs.handle, self.clampImg(ip));
                self.selDirty();
            },
            .drawing => try self.updateDrawing(ip),
            .moving_shape => |*mv| {
                const i = self.lifted orelse return;
                const dx = ip.x - mv.start.x - mv.applied.x;
                const dy = ip.y - mv.start.y - mv.applied.y;
                if (dx != 0 or dy != 0) {
                    self.doc.shapes.items[i].translate(dx, dy);
                    mv.applied.x += dx;
                    mv.applied.y += dy;
                    self.needs_render = true;
                }
            },
            .resizing_shape => |*rs| {
                const i = self.lifted orelse return;
                const s = &self.doc.shapes.items[i];
                switch (s.handleKind()) {
                    .endpoints => if (rs.handle == 0) {
                        s.p0 = ip;
                    } else {
                        s.p1 = ip;
                    },
                    .box => s.setFrame(&rs.orig, shapes_mod.resizeWithHandle(rs.orig.frame(), rs.handle, ip).normalized()),
                    .none => {},
                }
                self.needs_render = true;
            },
            .picking => |part| {
                ui.pickAt(self, part, m);
                try self.applyPickerColor();
            },
        }
    }

    fn cursorFor(self: *Editor, m: Point) window.Cursor {
        if (self.toolbar_rect.contains(m.x, m.y) or self.help_open) return .arrow;
        if (self.picker.open and self.picker.rect.contains(m.x, m.y)) return .crosshair;
        if (self.selected) |i| {
            if (self.shapeHandleAt(i, m) != null) return .move;
        }
        if (self.tool == .select) {
            if (self.doc.sel != null and self.doc.hit(self.imgAt(m), self.hitTol()) != null) return .move;
            if (self.selBuf()) |n| {
                if (shapes_mod.handleAt(n, m, self.handleRadius())) |hi| return switch (hi) {
                    0, 4 => .resize_nwse,
                    2, 6 => .resize_nesw,
                    1, 5 => .resize_ns,
                    else => .resize_ew,
                };
                if (n.contains(m.x, m.y)) return .move;
            }
        }
        if (self.tool == .text and self.doc.sel != null) return .text;
        return .crosshair;
    }

    fn shapeHandleAt(self: *const Editor, i: usize, m: Point) ?u3 {
        const s = &self.doc.shapes.items[i];
        const r = self.handleRadius();
        switch (s.handleKind()) {
            .none => return null,
            .endpoints => {
                for ([_]Point{ s.p0, s.p1 }, 0..) |p, k| {
                    const b = self.view.toBuf(p);
                    if (@abs(b.x - m.x) <= r and @abs(b.y - m.y) <= r) return @intCast(k);
                }
                return null;
            },
            .box => {
                const f = self.view.rectToBuf(s.frame());
                // a press inside a small shape moves it rather than resizing
                if (f.w < 4 * r or f.h < 4 * r) {
                    if (f.contains(m.x, m.y)) return null;
                }
                return shapes_mod.handleAt(f, m, r);
            },
        }
    }

    fn onPress(self: *Editor) !void {
        const m = self.mouse;
        self.breakCoalescing();
        if (self.help_open) {
            self.help_open = false;
            self.needs_render = true;
            return;
        }
        if (self.picker.open) {
            if (ui.pickPartAt(self, m)) |part| {
                self.drag = .{ .picking = part };
                ui.pickAt(self, part, m);
                try self.applyPickerColor();
                return;
            }
            if (self.picker.rect.contains(m.x, m.y)) return;
            self.picker.open = false;
            self.needs_render = true;
        }

        // toolbar gets priority
        if (self.toolbar_rect.contains(m.x, m.y)) {
            for (self.buttons.items) |b| {
                if (b.rect.contains(m.x, m.y)) {
                    try self.onButton(b.kind);
                    return;
                }
            }
            return;
        }
        const ip = self.imgAt(m);
        const now = nowMs();
        const double = now - self.last_click_ms < 400 and @abs(m.x - self.last_click.x) < 5 and @abs(m.y - self.last_click.y) < 5;
        self.last_click_ms = now;
        self.last_click = m;

        if (self.text) |*t| {
            const s = &self.doc.shapes.items[t.idx];
            if (self.view.rectToBuf(s.frame()).expand(self.sc(4)).contains(m.x, m.y)) {
                t.te.caret = caretAt(s, ip);
                self.needs_render = true;
                return;
            }
            try self.endText();
            if (self.tool == .text) return; // a click outside just commits
        }

        // the selected shape's handles
        if (self.selected) |i| {
            if (self.shapeHandleAt(i, m)) |h| {
                try self.doc.checkpoint();
                const orig = try self.doc.shapes.items[i].clone(self.alloc);
                try self.lift(i);
                self.drag = .{ .resizing_shape = .{ .handle = h, .orig = orig } };
                return;
            }
        }

        if (self.doc.sel == null or self.tool == .select) {
            if (self.doc.sel != null) {
                if (self.doc.hit(ip, self.hitTol())) |i| {
                    self.selectShape(i);
                    if (double and self.doc.shapes.items[i].tool == .text) {
                        try self.startText(i, false, ip);
                        return;
                    }
                    try self.doc.checkpoint();
                    try self.lift(i);
                    self.drag = .{ .moving_shape = .{ .start = ip, .applied = .{ .x = 0, .y = 0 } } };
                    return;
                }
                self.deselectShape();
                const n = self.selBuf().?;
                if (shapes_mod.handleAt(n, m, self.handleRadius())) |h| {
                    self.drag = .{ .resizing_sel = .{ .handle = h, .orig = self.doc.sel.?.normalized() } };
                    return;
                }
                if (n.contains(m.x, m.y)) {
                    self.drag = .{ .moving_sel = .{ .orig = self.doc.sel.?.normalized(), .start = ip } };
                    return;
                }
            }
            self.deselectShape();
            self.selDirty();
            const a = self.clampImg(ip);
            self.doc.sel = .{ .x = a.x, .y = a.y, .w = 0, .h = 0 };
            self.drag = .{ .selecting = a };
            self.selDirty();
            return;
        }

        self.deselectShape();
        switch (self.tool) {
            .counter => {
                try self.doc.checkpoint();
                const i = try self.doc.add(.{
                    .tool = .counter,
                    .color = self.color(),
                    .thickness = self.imgThickness(),
                    .p0 = ip,
                    .number = self.doc.nextNumber(),
                });
                try self.recompose(self.doc.shapes.items[i].bounds());
            },
            .text => {
                if (self.doc.hit(ip, self.hitTol())) |i| {
                    if (self.doc.shapes.items[i].tool == .text) {
                        try self.startText(i, false, ip);
                        return;
                    }
                }
                const t = self.imgThickness();
                const lh = text_mod.height(shapes_mod.textFontPx(t));
                const i = try self.doc.add(.{
                    .tool = .text,
                    .color = self.color(),
                    .thickness = t,
                    .p0 = .{ .x = ip.x, .y = ip.y - @divTrunc(lh, 2) },
                    .pill = (self.styles.get(.text) & 1) != 0,
                });
                try self.startText(i, true, ip);
            },
            else => {
                var s = Shape{
                    .tool = self.tool,
                    .color = self.color(),
                    .thickness = self.imgThickness(),
                    .p0 = ip,
                    .p1 = ip,
                    .filled = (self.styles.get(self.tool) & 1) != 0,
                    .rounded = (self.styles.get(self.tool) & 2) != 0,
                };
                errdefer s.deinit(self.alloc);
                if (self.tool == .pen or self.tool == .highlight) {
                    try s.points.append(self.alloc, ip);
                    self.liveSegment(&s, ip, ip);
                }
                self.cur = s;
                self.drag = .drawing;
                self.needs_render = true;
            },
        }
    }

    fn updateDrawing(self: *Editor, ip: Point) !void {
        const s = &(self.cur orelse return);
        switch (s.tool) {
            .pen, .highlight => {
                const last = s.points.items[s.points.items.len - 1];
                const dx: f64 = @floatFromInt(ip.x - last.x);
                const dy: f64 = @floatFromInt(ip.y - last.y);
                const min_step = self.view.lenToImg(2.0);
                if (dx * dx + dy * dy >= min_step * min_step) {
                    try s.points.append(self.alloc, ip);
                    self.liveSegment(s, last, ip);
                }
            },
            else => s.p1 = ip,
        }
        self.needs_render = true;
    }

    /// Rasterize one new freehand segment into the live coverage mask: the
    /// stroke being drawn costs O(segment) per motion, not O(stroke).
    fn liveSegment(self: *Editor, s: *const Shape, a_img: Point, b_img: Point) void {
        if (self.live_cov.len == 0) return;
        const xf = self.view.xform();
        const a = xf.pt(a_img);
        const b = xf.pt(b_img);
        var half = @max(0.5, @as(f64, @floatFromInt(s.thickness)) * self.view.scale / 2.0);
        if (s.tool == .highlight) half *= 3.0;
        const pad: i32 = @as(i32, @intFromFloat(@ceil(half))) + 2;
        const bb = Rect.intersect(Rect.fromCorners(a, b).expand(pad), self.screenRect()) orelse return;
        const w: usize = self.win.width;
        const ax: f64 = @floatFromInt(a.x);
        const ay: f64 = @floatFromInt(a.y);
        const abx = @as(f64, @floatFromInt(b.x)) - ax;
        const aby = @as(f64, @floatFromInt(b.y)) - ay;
        const ab2 = abx * abx + aby * aby;
        var y = bb.y;
        while (y < bb.bottom()) : (y += 1) {
            var x = bb.x;
            while (x < bb.right()) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5 - ax;
                const py = @as(f64, @floatFromInt(y)) + 0.5 - ay;
                const t = if (ab2 == 0) 0.0 else std.math.clamp((px * abx + py * aby) / ab2, 0.0, 1.0);
                const dx = px - abx * t;
                const dy = py - aby * t;
                const cov = std.math.clamp(half - @sqrt(dx * dx + dy * dy) + 0.5, 0.0, 1.0);
                if (cov <= 0.003) continue;
                const cv: u8 = @intFromFloat(cov * 255.0);
                const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
                if (cv > self.live_cov[idx]) self.live_cov[idx] = cv;
            }
        }
        self.live_bbox = Rect.unite(self.live_bbox, bb);
        self.content_dirty.add(bb);
    }

    fn clearLive(self: *Editor) void {
        if (self.live_bbox.isEmpty()) return;
        const w: usize = self.win.width;
        const r = self.live_bbox;
        var y: usize = @intCast(r.y);
        while (y < @as(usize, @intCast(r.bottom()))) : (y += 1) {
            @memset(self.live_cov[y * w + @as(usize, @intCast(r.x)) ..][0..@intCast(r.w)], 0);
        }
        self.content_dirty.add(r);
        self.live_bbox = Rect.empty;
    }

    fn onRelease(self: *Editor) !void {
        const drag = self.drag;
        self.drag = .none;
        switch (drag) {
            .selecting => {
                const s = self.doc.sel.?.normalized();
                const min = self.view.lenToImg(4.0);
                self.selDirty();
                if (@as(f64, @floatFromInt(s.w)) < min or @as(f64, @floatFromInt(s.h)) < min) {
                    // a click: pick the monitor under it when there are several
                    self.doc.sel = null;
                    if (self.monitors.len > 1) {
                        const ip = self.imgAt(self.mouse);
                        for (self.monitors) |mon| {
                            const r = Rect{ .x = @intCast(mon.x), .y = @intCast(mon.y), .w = @intCast(mon.w), .h = @intCast(mon.h) };
                            if (r.contains(ip.x, ip.y)) self.doc.sel = r;
                        }
                    }
                } else {
                    self.doc.sel = s;
                }
                self.selDirty();
            },
            .moving_sel, .resizing_sel => {
                self.selDirty();
                self.doc.sel = Rect.intersect(self.doc.sel.?.normalized(), self.doc.imageRect());
                self.selDirty();
            },
            .drawing => try self.commitCur(),
            .moving_shape => |mv| {
                if (mv.applied.x == 0 and mv.applied.y == 0) self.doc.dropCheckpoint();
                try self.unlift();
            },
            .resizing_shape => |rs| {
                var orig = rs.orig;
                orig.deinit(self.alloc);
                try self.unlift();
            },
            .picking, .none => {},
        }
        self.needs_render = true;
    }

    fn commitCur(self: *Editor) !void {
        var s = self.cur orelse return;
        self.cur = null;
        self.clearLive();
        const f = s.frame();
        const min = self.view.lenToImg(3.0);
        const tiny = switch (s.tool) {
            .pen, .highlight => false,
            .line, .arrow => @abs(s.p1.x - s.p0.x) < @as(i32, @intFromFloat(min)) + 1 and @abs(s.p1.y - s.p0.y) < @as(i32, @intFromFloat(min)) + 1,
            else => @as(f64, @floatFromInt(f.w)) < min or @as(f64, @floatFromInt(f.h)) < min,
        };
        if (tiny) {
            s.deinit(self.alloc);
            self.needs_render = true;
            return;
        }
        self.doc.checkpoint() catch |e| {
            s.deinit(self.alloc);
            return e;
        };
        const i = try self.doc.add(s);
        try self.recompose(self.doc.shapes.items[i].bounds());
    }

    fn onRightClick(self: *Editor) !void {
        _ = try self.cancelOne();
    }

    /// Escape semantics: undo the innermost thing in progress. Returns
    /// false when there was nothing left to cancel.
    fn cancelOne(self: *Editor) !bool {
        self.needs_render = true;
        if (self.help_open) {
            self.help_open = false;
            return true;
        }
        if (self.picker.open) {
            self.picker.open = false;
            return true;
        }
        if (self.text != null) {
            try self.endText();
            return true;
        }
        switch (self.drag) {
            .none, .picking => {},
            .drawing => {
                if (self.cur) |*s| s.deinit(self.alloc);
                self.cur = null;
                self.clearLive();
                self.drag = .none;
                return true;
            },
            .moving_shape, .resizing_shape => {
                // put the shape back where it was
                if (self.drag == .resizing_shape) self.drag.resizing_shape.orig.deinit(self.alloc);
                self.drag = .none;
                self.lifted = null;
                try self.doc.revert();
                self.selected = null;
                try self.recomposeAll();
                return true;
            },
            .selecting, .moving_sel, .resizing_sel => {
                self.selDirty();
                self.doc.sel = null;
                self.drag = .none;
                self.selDirty();
                return true;
            },
        }
        if (self.focus != null) {
            self.focus = null;
            return true;
        }
        if (self.selected != null) {
            self.deselectShape();
            return true;
        }
        if (self.doc.sel != null) {
            self.selDirty();
            self.doc.sel = null;
            return true;
        }
        return false;
    }

    // --- shape selection, lifting ---

    fn selectShape(self: *Editor, i: usize) void {
        self.selected = i;
        const s = &self.doc.shapes.items[i];
        // the toolbar reflects the shape, so tweaks start from its values
        self.thickness = self.logicalThickness(s.thickness);
        self.custom_active = true;
        for (palette, 0..) |c, ci| {
            if (c == s.color) {
                self.color_idx = @intCast(ci);
                self.custom_active = false;
            }
        }
        if (self.custom_active) self.custom_color = s.color;
        self.styles.set(s.tool, @as(u2, @intFromBool(s.filled or s.pill)) | (@as(u2, @intFromBool(s.rounded)) << 1));
        self.needs_render = true;
    }

    fn deselectShape(self: *Editor) void {
        if (self.selected != null) self.needs_render = true;
        self.selected = null;
    }

    /// Take shape `i` out of the layer so it can change every frame.
    fn lift(self: *Editor, i: usize) !void {
        self.lifted = i;
        try self.recompose(self.doc.shapes.items[i].bounds());
    }

    fn unlift(self: *Editor) !void {
        const i = self.lifted orelse return;
        self.lifted = null;
        try self.recompose(self.doc.shapes.items[i].bounds());
    }

    // --- text ---

    fn startText(self: *Editor, i: usize, is_new: bool, ip: Point) !void {
        if (!is_new) try self.doc.checkpoint() else {
            // the empty shape was added before the checkpoint; record the
            // state without it
            var s = self.doc.shapes.pop().?;
            self.doc.checkpoint() catch |e| {
                s.deinit(self.alloc);
                return e;
            };
            self.doc.shapes.appendAssumeCapacity(s);
        }
        const s = &self.doc.shapes.items[i];
        const orig = try self.alloc.dupe(u8, s.str.items);
        self.text = .{ .idx = i, .te = .{ .caret = if (is_new) 0 else caretAt(s, ip) }, .is_new = is_new, .orig = orig };
        self.selected = null;
        if (!is_new) self.selectShape(i);
        self.selected = null;
        try self.lift(i);
        self.needs_render = true;
    }

    fn endText(self: *Editor) !void {
        const t = self.text orelse return;
        self.text = null;
        defer self.alloc.free(t.orig);
        self.win.setTextInput(false, null) catch {};
        const s = &self.doc.shapes.items[t.idx];
        const empty = std.mem.trim(u8, s.str.items, " \n").len == 0;
        const unchanged = !t.is_new and std.mem.eql(u8, s.str.items, t.orig);
        self.lifted = null;
        if (empty) {
            const r = s.bounds();
            self.doc.remove(t.idx);
            if (t.is_new) self.doc.dropCheckpoint();
            try self.recompose(r);
            return;
        }
        if (unchanged) {
            // colour or size may still have changed while editing
            const before = self.doc.undo_stack.items[self.doc.undo_stack.items.len - 1];
            const same = before.len == self.doc.shapes.items.len and before[t.idx].color == s.color and
                before[t.idx].thickness == s.thickness and before[t.idx].pill == s.pill and
                before[t.idx].p0.x == s.p0.x and before[t.idx].p0.y == s.p0.y;
            if (same) self.doc.dropCheckpoint();
        }
        try self.recompose(s.bounds());
    }

    fn onTextKey(self: *Editor, k: window.Key) !void {
        const t = &self.text.?;
        const s = &self.doc.shapes.items[t.idx];
        const buf = &s.str;
        self.needs_render = true;
        switch (k.code) {
            window.KEY_ESC => try self.endText(),
            window.KEY_ENTER, KEY_KPENTER => {
                if (k.ctrl) try self.endText() else try t.te.insert(self.alloc, buf, "\n");
            },
            window.KEY_BACKSPACE => if (k.ctrl) t.te.backspaceWord(buf) else t.te.backspace(buf),
            window.KEY_DELETE => t.te.delete(buf),
            KEY_LEFT => if (k.ctrl) t.te.wordLeft(buf.items) else t.te.left(buf.items),
            KEY_RIGHT => if (k.ctrl) t.te.wordRight(buf.items) else t.te.right(buf.items),
            KEY_UP => t.te.up(buf.items),
            KEY_DOWN => t.te.down(buf.items),
            KEY_HOME => if (k.ctrl) {
                t.te.caret = 0;
            } else t.te.home(buf.items),
            KEY_END => if (k.ctrl) {
                t.te.caret = buf.items.len;
            } else t.te.end(buf.items),
            KEY_MINUS, KEY_EQUAL => if (k.ctrl) try self.setThickness(self.thickness + @as(i32, if (k.code == KEY_EQUAL) 1 else -1)) else try self.typeText(k),
            else => try self.typeText(k),
        }
    }

    fn typeText(self: *Editor, k: window.Key) !void {
        if (k.ctrl) return;
        const t = &self.text.?;
        const txt = k.text();
        if (txt.len == 0) return;
        try t.te.insert(self.alloc, &self.doc.shapes.items[t.idx].str, txt);
    }

    // --- buttons and keys ---

    pub fn onButton(self: *Editor, kind: ui.ButtonKind) !void {
        self.needs_render = true;
        switch (kind) {
            .tool => |t| {
                try self.endText();
                self.deselectShape();
                self.tool = t;
            },
            .color => |c| {
                self.color_idx = c;
                self.custom_active = false;
                try self.applyColor();
            },
            .custom_color => {
                self.picker.open = !self.picker.open;
                if (self.picker.open) ui.pickerFrom(self, self.custom_color);
            },
            .style => try self.cycleStyle(),
            .thickness => try self.setThickness(if (self.thickness >= 16) 1 else self.thickness + 1),
            .beautify => {
                self.beautify.enabled = !self.beautify.enabled;
                self.selDirty();
                self.content_dirty.add(self.screenRect());
            },
            .background => {
                self.beautify.bg = @intCast((self.beautify.bg + 1) % doc_mod.backgrounds.len);
                self.selDirty();
            },
            .undo => try self.undo(),
            .redo => try self.redo(),
            .copy => try self.copyToClipboard(),
            .save => self.finish(.save),
            .save_as => self.finish(.save_as),
            .help => self.help_open = !self.help_open,
            .cancel => self.finish(.cancel),
        }
    }

    fn finish(self: *Editor, action: Action) void {
        self.action = action;
        self.running = false;
    }

    fn applyColor(self: *Editor) !void {
        try self.editTarget(2, struct {
            fn f(s: *Shape, c: u32) void {
                s.color = c;
            }
        }.f, self.color());
    }

    fn applyPickerColor(self: *Editor) !void {
        self.custom_color = ui.pickerColor(self);
        self.custom_active = true;
        try self.applyColor();
    }

    /// Outline -> filled -> rounded outline -> rounded filled (text: pill).
    fn cycleStyle(self: *Editor) !void {
        const target_tool = if (self.text) |t| self.doc.shapes.items[t.idx].tool else if (self.selected) |i| self.doc.shapes.items[i].tool else self.tool;
        const old = self.styles.get(target_tool);
        const style: u2 = switch (target_tool) {
            .rect => old +% 1,
            else => (old ^ 1) & 1,
        };
        self.styles.set(target_tool, style);
        self.breakCoalescing();
        try self.editTarget(3, struct {
            fn f(s: *Shape, st: u2) void {
                s.filled = (st & 1) != 0 and (s.tool == .rect or s.tool == .ellipse);
                s.rounded = (st & 2) != 0 and s.tool == .rect;
                s.pill = (st & 1) != 0 and s.tool == .text;
            }
        }.f, style);
        self.needs_render = true;
    }

    fn setTool(self: *Editor, t: Tool) !void {
        try self.endText();
        self.deselectShape();
        self.tool = t;
        self.needs_render = true;
    }

    fn onKey(self: *Editor, k: window.Key) !void {
        if (k.repeat) {
            // held keys repeat for movement, deletion and typing only
            const ok = switch (k.code) {
                KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_MINUS, KEY_EQUAL, KEY_KPMINUS, KEY_KPPLUS => true,
                window.KEY_ESC => false,
                else => self.text != null,
            };
            if (!ok) return;
        }
        self.needs_render = true;
        if (self.help_open) {
            self.help_open = false;
            return;
        }
        if (self.picker.open) {
            if (ui.pickerKey(self, k)) |changed| {
                if (changed) try self.applyPickerColor();
                return;
            }
        }
        if (self.text != null) {
            const editing_chord = switch (k.code) {
                window.KEY_ENTER, KEY_KPENTER, window.KEY_BACKSPACE, window.KEY_DELETE, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_MINUS, KEY_EQUAL => true,
                else => false,
            };
            // other Ctrl chords (copy, save, undo...) end the edit and run
            if (!k.ctrl or editing_chord) {
                try self.onTextKey(k);
                return;
            }
            try self.endText();
        }

        // fixed chords that must win over configurable binds
        if (k.ctrl and k.shift and k.code == KEY_S) return self.finish(.save_as);
        if (k.ctrl and !k.shift and k.code == KEY_Y) return self.redo();
        if (k.ctrl and k.code == KEY_D) return self.duplicateSelected();
        if (k.ctrl and k.code == KEY_RIGHTBRACE) return self.bringSelectedToFront();

        if (!k.alt) {
            for (self.binds, 0..) |b, i| {
                if (!b.matches(k.code, k.ctrl, k.shift)) continue;
                switch (@as(config.Action, @fromBackingInt(@intCast(i)))) {
                    .select => try self.setTool(.select),
                    .pen => try self.setTool(.pen),
                    .line => try self.setTool(.line),
                    .arrow => try self.setTool(.arrow),
                    .rect => try self.setTool(.rect),
                    .ellipse => try self.setTool(.ellipse),
                    .highlight => try self.setTool(.highlight),
                    // blur first; pressing again cycles pixelate and solid redaction
                    .pixelate => try self.setTool(switch (self.tool) {
                        .blur => .pixelate,
                        .pixelate => .redact,
                        else => .blur,
                    }),
                    .counter => try self.setTool(.counter),
                    .text => try self.setTool(.text),
                    .copy => try self.copyToClipboard(),
                    .save => self.finish(.save),
                    .undo => try self.undo(),
                    .redo => try self.redo(),
                }
                return;
            }
        }

        switch (k.code) {
            window.KEY_ESC => if (!try self.cancelOne()) self.finish(.cancel),
            KEY_TAB => ui.moveFocus(self, if (k.shift) -1 else 1),
            window.KEY_ENTER, KEY_KPENTER, window.KEY_SPACE => {
                if (self.focus) |f| {
                    if (f < self.buttons.items.len) try self.onButton(self.buttons.items[f].kind);
                } else if (k.code != window.KEY_SPACE) {
                    if (self.selected) |i| {
                        if (self.doc.shapes.items[i].tool == .text) return self.startText(i, false, .{ .x = std.math.maxInt(i32) / 2, .y = std.math.maxInt(i32) / 2 });
                    }
                    try self.copyToClipboard();
                }
            },
            window.KEY_DELETE, window.KEY_BACKSPACE => try self.deleteSelected(),
            KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN => try self.arrowKey(k),
            KEY_MINUS, KEY_KPMINUS => try self.setThickness(self.thickness - 1),
            KEY_EQUAL, KEY_KPPLUS => try self.setThickness(self.thickness + 1),
            KEY_F1 => self.help_open = true,
            KEY_B => if (!k.ctrl) try self.onButton(.beautify),
            KEY_F => if (!k.ctrl) try self.cycleStyle(),
            KEY_1...KEY_1 + 7 => if (!k.ctrl and !k.alt) {
                self.color_idx = @intCast(k.code - KEY_1);
                self.custom_active = false;
                try self.applyColor();
            },
            KEY_9 => if (!k.ctrl) try self.onButton(.custom_color),
            else => {
                if (std.mem.eql(u8, k.text(), "?")) self.help_open = true;
            },
        }
    }

    fn arrowKey(self: *Editor, k: window.Key) !void {
        const step: i32 = if (k.shift) 10 else 1;
        const dx: i32 = switch (k.code) {
            KEY_LEFT => -step,
            KEY_RIGHT => step,
            else => 0,
        };
        const dy: i32 = switch (k.code) {
            KEY_UP => -step,
            KEY_DOWN => step,
            else => 0,
        };
        if (self.selected != null and !k.alt) {
            try self.editTarget(4, struct {
                fn f(s: *Shape, d: [2]i32) void {
                    s.translate(d[0], d[1]);
                }
            }.f, [2]i32{ dx, dy });
            return;
        }
        if (self.doc.sel == null) return;
        self.selDirty();
        if (k.alt) self.doc.resizeSelection(dx, dy) else self.doc.moveSelection(dx, dy);
        self.selDirty();
    }

    fn deleteSelected(self: *Editor) !void {
        try self.settle();
        const i = self.selected orelse return;
        self.selected = null;
        try self.doc.checkpoint();
        const r = self.doc.shapes.items[i].bounds();
        self.doc.remove(i);
        try self.recompose(r);
    }

    fn duplicateSelected(self: *Editor) !void {
        try self.settle();
        const i = self.selected orelse return;
        try self.doc.checkpoint();
        const off: i32 = @max(4, @as(i32, @intFromFloat(@round(self.view.lenToImg(@floatFromInt(self.sc(14)))))));
        const n = try self.doc.duplicate(i, off, off);
        self.selected = n;
        try self.recompose(self.doc.shapes.items[n].bounds());
    }

    fn bringSelectedToFront(self: *Editor) !void {
        try self.settle();
        const i = self.selected orelse return;
        if (i + 1 == self.doc.shapes.items.len) return;
        try self.doc.checkpoint();
        self.selected = self.doc.bringToFront(i);
        try self.recompose(self.doc.shapes.items[self.selected.?].bounds());
    }

    /// End whatever is in progress so the document is consistent.
    fn settle(self: *Editor) !void {
        try self.endText();
        switch (self.drag) {
            .drawing => try self.commitCur(),
            .moving_shape, .resizing_shape => try self.onRelease(),
            else => {},
        }
        self.drag = .none;
    }

    fn undo(self: *Editor) !void {
        try self.settle();
        self.selected = null;
        if (try self.doc.undo()) try self.recomposeAll();
    }

    fn redo(self: *Editor) !void {
        try self.settle();
        self.selected = null;
        if (try self.doc.redo()) try self.recomposeAll();
    }

    fn copyToClipboard(self: *Editor) !void {
        self.showCopyNotice(.copying, 0);
        if (!self.win.frame_pending) {
            try self.renderFrame();
            self.needs_render = false;
        }
        const exported = try self.exportPixels();
        self.win.setClipboardImage(exported.pixels, exported.width, exported.height) catch |err| {
            self.alloc.free(exported.pixels);
            std.log.warn("copy failed: {t}", .{err});
            self.showCopyNotice(.failed, 2400);
            return;
        };
        self.showCopyNotice(.copied, 2400);
    }

    fn showCopyNotice(self: *Editor, copy_notice: CopyNotice, duration_ms: i64) void {
        self.copy_notice = copy_notice;
        self.copy_notice_hide_at_ms = if (duration_ms > 0) nowMs() + duration_ms else 0;
        self.needs_render = true;
    }

    // --- rendering ---

    fn renderFrame(self: *Editor) !void {
        if (self.viewc.len == 0) return;
        try self.ensureBeautyCache();
        try ui.layoutToolbar(self);
        self.overlays.len = 0;
        ui.collectOverlays(self, &self.overlays);
        for (&self.pending) |*p| {
            p.addAll(&self.content_dirty);
            p.addAll(&self.overlays);
        }
        self.content_dirty.len = 0;

        if (self.caretRect()) |cr| self.win.setTextInput(true, .{ .x = cr.x, .y = cr.y, .w = cr.w, .h = cr.h }) catch {};
        const px = try self.win.backBuffer();
        const bi = self.win.surfaceList()[0].cur_buf;
        const p = &self.pending[bi];
        // past ~half the screen one full pass beats many partial ones
        if (p.area() * 2 > @as(i64, self.win.width) * self.win.height) {
            self.composeRegion(px, self.screenRect());
        } else {
            for (p.slice()) |r| self.composeRegion(px, r);
        }
        var canvas = Canvas.init(px, self.win.width, self.win.height);
        canvas.mask = self.stroke_mask;
        self.drawLiveShapes(&canvas);
        ui.drawChrome(self, &canvas);
        p.len = 0;
        p.addAll(&self.overlays);
        self.last_frame = px;
        try self.win.present();
    }

    /// Paint the background for buffer rect `region`: the dimmed view, the
    /// bright selection (or its beautify frame) and the live stroke.
    fn composeRegion(self: *Editor, px: []u32, region: Rect) void {
        const r = Rect.intersect(region, self.screenRect()) orelse return;
        const w: usize = self.win.width;
        const sel = self.selBuf();
        const beauty = self.beautify.enabled and self.bcache_valid and sel != null;
        const bright: ?Rect = if (beauty) self.bcache_rect else sel;
        var y = r.y;
        while (y < r.bottom()) : (y += 1) {
            const row = @as(usize, @intCast(y)) * w;
            var x0 = r.right();
            var x1 = r.right();
            if (bright) |b| {
                if (y >= b.y and y < b.bottom()) {
                    x0 = std.math.clamp(b.x, r.x, r.right());
                    x1 = std.math.clamp(b.right(), r.x, r.right());
                }
            }
            if (x1 <= x0) {
                x0 = r.right();
                x1 = r.right();
            }
            const a: usize = @intCast(r.x);
            const sa: usize = @intCast(x0);
            const sb: usize = @intCast(x1);
            const e: usize = @intCast(r.right());
            if (sa > a) @memcpy(px[row + a .. row + sa], self.viewc_dim[row + a .. row + sa]);
            if (sb > sa) {
                if (beauty) {
                    const b = self.bcache_rect;
                    const bw: usize = @intCast(b.w);
                    const by: usize = @intCast(y - b.y);
                    const bx: usize = @intCast(x0 - b.x);
                    @memcpy(px[row + sa .. row + sb], self.bcache[by * bw + bx ..][0 .. sb - sa]);
                } else {
                    @memcpy(px[row + sa .. row + sb], self.viewc[row + sa .. row + sb]);
                }
            }
            if (e > sb) @memcpy(px[row + sb .. row + e], self.viewc_dim[row + sb .. row + e]);
        }
        // the freehand stroke being drawn
        const s = &(self.cur orelse return);
        if (s.tool != .pen and s.tool != .highlight) return;
        const lr = Rect.intersect(r, self.live_bbox) orelse return;
        const col = if (s.tool == .highlight) (s.color & 0x00FFFFFF) | 0x66000000 else s.color;
        const ca: u32 = col >> 24;
        var dimmed: [1]u32 = undefined;
        dimRow(&.{col}, &dimmed, 255 - (dim_color >> 24));
        y = lr.y;
        while (y < lr.bottom()) : (y += 1) {
            var x = lr.x;
            while (x < lr.right()) : (x += 1) {
                const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
                const cv: u32 = self.live_cov[idx];
                if (cv == 0) continue;
                const inside = if (bright) |b| b.contains(x, y) else false;
                const c = if (inside) col else dimmed[0];
                const a = (ca * cv + 127) / 255;
                px[idx] = Canvas.blendPixel(px[idx], (c & 0x00FFFFFF) | (a << 24));
            }
        }
    }

    /// The text caret on screen while editing text.
    pub fn caretRect(self: *const Editor) ?Rect {
        const t = self.text orelse return null;
        const s = &self.doc.shapes.items[t.idx];
        const fs = s.fontPx();
        const str = s.str.items;
        const ls = textedit.lineStart(str, t.te.caret);
        var line: i32 = 0;
        for (str[0..ls]) |c| line += @intFromBool(c == '\n');
        const lh = text_mod.height(fs);
        const p = Point{ .x = s.p0.x + text_mod.width(fs, str[ls..t.te.caret]), .y = s.p0.y + line * lh };
        const b = self.view.toBuf(p);
        return .{ .x = b.x, .y = b.y, .w = @max(1, self.sc(2)), .h = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(lh)) * self.view.scale)))) };
    }

    /// Shapes not in the layer: the one being drawn and the lifted one.
    fn drawLiveShapes(self: *Editor, canvas: *Canvas) void {
        const xf = self.view.xform();
        if (self.cur) |*s| {
            if (s.tool != .pen and s.tool != .highlight) shapes_mod.drawShape(canvas, self.alloc, s, xf, null);
        }
        if (self.lifted) |i| {
            const caret: ?usize = if (self.text) |t| t.te.caret else null;
            shapes_mod.drawShape(canvas, self.alloc, &self.doc.shapes.items[i], xf, caret);
        }
    }

    /// Screen footprint of the live shapes, for damage tracking.
    pub fn liveBounds(self: *const Editor) Rect {
        var r = Rect.empty;
        if (self.cur) |*s| {
            if (s.tool != .pen and s.tool != .highlight) r = Rect.unite(r, s.bounds());
        }
        if (self.lifted) |i| r = Rect.unite(r, self.doc.shapes.items[i].bounds().expand(4));
        if (r.isEmpty()) return r;
        return self.view.rectToBufOuter(r).expand(2);
    }

    // --- export ---

    fn exportPixels(self: *Editor) !doc_mod.Exported {
        try self.settle();
        return doc_mod.exportImage(self.alloc, self.layer, self.img.width, self.img.height, self.doc.exportRect(), self.beautify);
    }

    fn exportPng(self: *Editor) ![]u8 {
        const exported = try self.exportPixels();
        defer self.alloc.free(exported.pixels);
        return png.encode(self.alloc, exported.pixels, exported.width, exported.height);
    }

    // --- dev hooks: scripted input and frame dumps ---

    fn dumpAtExit(self: *Editor, prefix: []const u8) void {
        var buf: [1024]u8 = undefined;
        const frame_path = std.fmt.bufPrint(&buf, "{s}-frame.png", .{prefix}) catch return;
        self.dumpFrame(frame_path);
        var buf2: [1024]u8 = undefined;
        const export_path = std.fmt.bufPrint(&buf2, "{s}-export.png", .{prefix}) catch return;
        self.dumpExport(export_path);
    }

    fn dumpFrame(self: *Editor, path: []const u8) void {
        if (self.last_frame.len == 0) return;
        const data = png.encode(self.alloc, self.last_frame, self.win.width, self.win.height) catch return;
        defer self.alloc.free(data);
        sys.writeFile(path, data) catch |e| std.log.warn("dump {s}: {t}", .{ path, e });
    }

    fn dumpExport(self: *Editor, path: []const u8) void {
        const data = self.exportPng() catch return;
        defer self.alloc.free(data);
        sys.writeFile(path, data) catch |e| std.log.warn("dump {s}: {t}", .{ path, e });
    }

    fn scriptStep(self: *Editor) !void {
        const script = self.script.?;
        var end = std.mem.indexOfScalarPos(u8, script, self.script_pos, ';') orelse script.len;
        const cmd = std.mem.trim(u8, script[self.script_pos..end], " \n\t");
        if (end < script.len) end += 1;
        self.script_pos = end;
        if (cmd.len == 0) return;
        self.runCommand(cmd) catch |e| std.log.warn("script '{s}': {t}", .{ cmd, e });
        self.needs_render = true;
    }

    fn runCommand(self: *Editor, cmd: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const op = it.next() orelse return;
        const arg = std.mem.trim(u8, it.rest(), " ");
        const eql = std.mem.eql;
        if (eql(u8, op, "move")) {
            const p = try parsePoint(arg);
            try self.handle(.{ .pointer_motion = .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) } });
        } else if (eql(u8, op, "down") or eql(u8, op, "up")) {
            const p = try parsePoint(arg);
            try self.handle(.{ .pointer_button = .{ .button = window.BTN_LEFT, .pressed = eql(u8, op, "down"), .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) } });
        } else if (eql(u8, op, "click") or eql(u8, op, "rclick")) {
            const p = try parsePoint(arg);
            const btn = if (eql(u8, op, "click")) window.BTN_LEFT else window.BTN_RIGHT;
            const fx: f64 = @floatFromInt(p.x);
            const fy: f64 = @floatFromInt(p.y);
            try self.handle(.{ .pointer_motion = .{ .x = fx, .y = fy } });
            try self.handle(.{ .pointer_button = .{ .button = btn, .pressed = true, .x = fx, .y = fy } });
            try self.handle(.{ .pointer_button = .{ .button = btn, .pressed = false, .x = fx, .y = fy } });
        } else if (eql(u8, op, "drag")) {
            var pts = std.mem.tokenizeScalar(u8, arg, ' ');
            const a = try parsePoint(pts.next() orelse return error.BadScript);
            const b = try parsePoint(pts.next() orelse return error.BadScript);
            try self.handle(.{ .pointer_motion = .{ .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) } });
            try self.handle(.{ .pointer_button = .{ .button = window.BTN_LEFT, .pressed = true, .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) } });
            for (1..13) |i| {
                const t = @as(f64, @floatFromInt(i)) / 12.0;
                const x = @as(f64, @floatFromInt(a.x)) + @as(f64, @floatFromInt(b.x - a.x)) * t;
                const y = @as(f64, @floatFromInt(a.y)) + @as(f64, @floatFromInt(b.y - a.y)) * t + @sin(t * std.math.pi) * 20;
                try self.handle(.{ .pointer_motion = .{ .x = x, .y = y } });
            }
            try self.handle(.{ .pointer_motion = .{ .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) } });
            try self.handle(.{ .pointer_button = .{ .button = window.BTN_LEFT, .pressed = false, .x = @floatFromInt(b.x), .y = @floatFromInt(b.y) } });
        } else if (eql(u8, op, "scribble")) {
            // scribble cx,cy,r,n: a long freehand stroke, rendering a frame
            // per motion, and log the time per frame
            const v = try parseInts(4, arg);
            const t0 = nowMs();
            const n: usize = @intCast(v[3]);
            for (0..n + 1) |i| {
                const a = @as(f64, @floatFromInt(i)) * 0.05;
                const rr = @as(f64, @floatFromInt(v[2])) * (0.3 + 0.7 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
                const x = @as(f64, @floatFromInt(v[0])) + @cos(a) * rr;
                const y = @as(f64, @floatFromInt(v[1])) + @sin(a) * rr;
                try self.handle(.{ .pointer_motion = .{ .x = x, .y = y } });
                if (i == 0) try self.handle(.{ .pointer_button = .{ .button = window.BTN_LEFT, .pressed = true, .x = x, .y = y } });
                try self.renderFrame();
            }
            const t1 = nowMs();
            try self.handle(.{ .pointer_button = .{ .button = window.BTN_LEFT, .pressed = false, .x = 0, .y = 0 } });
            std.log.info("scribble: {d} frames in {d} ms, commit {d} ms", .{ n, t1 - t0, nowMs() - t1 });
        } else if (eql(u8, op, "scroll")) {
            try self.handle(.{ .pointer_axis = .{ .value = try std.fmt.parseFloat(f64, arg) } });
        } else if (eql(u8, op, "key")) {
            try self.handle(.{ .key = try parseKey(arg) });
        } else if (eql(u8, op, "type")) {
            var i: usize = 0;
            while (i < arg.len) {
                const n = std.unicode.utf8ByteSequenceLength(arg[i]) catch 1;
                var k: window.Key = .{ .code = 0, .pressed = true, .ctrl = false, .shift = false };
                const piece = arg[i..@min(arg.len, i + n)];
                if (std.mem.eql(u8, piece, "|")) {
                    k.code = window.KEY_ENTER;
                } else {
                    @memcpy(k.text_buf[0..piece.len], piece);
                    k.text_len = @intCast(piece.len);
                }
                try self.handle(.{ .key = k });
                i += n;
            }
        } else if (eql(u8, op, "sel")) {
            const v = try parseInts(4, arg);
            self.selDirty();
            const a = self.clampImg(self.imgAt(.{ .x = v[0], .y = v[1] }));
            const b = self.clampImg(self.imgAt(.{ .x = v[0] + v[2], .y = v[1] + v[3] }));
            self.doc.sel = Rect.fromCorners(a, b);
            self.selDirty();
        } else if (eql(u8, op, "tool")) {
            inline for (@typeInfo(Tool).@"enum".field_names) |name| {
                if (eql(u8, arg, name)) try self.setTool(@field(Tool, name));
            }
        } else if (eql(u8, op, "button")) {
            for (self.buttons.items) |b| {
                if (eql(u8, ui.buttonName(b.kind), arg)) {
                    const c = Point{ .x = b.rect.x + @divTrunc(b.rect.w, 2), .y = b.rect.y + @divTrunc(b.rect.h, 2) };
                    var buf: [32]u8 = undefined;
                    try self.runCommand(try std.fmt.bufPrint(&buf, "click {d},{d}", .{ c.x, c.y }));
                    return;
                }
            }
            return error.NoSuchButton;
        } else if (eql(u8, op, "render")) {
            try self.renderFrame();
        } else if (eql(u8, op, "dump")) {
            try self.renderFrame();
            self.dumpFrame(arg);
        } else if (eql(u8, op, "export")) {
            self.dumpExport(arg);
        } else if (eql(u8, op, "quit")) {
            self.finish(.cancel);
        } else return error.BadScript;
    }
};

/// US-layout key -> character, only to turn script key names into codes.
fn usKeyChar(code: u32, shift: bool) ?u8 {
    const lower = "1234567890";
    const upper = "!@#$%^&*()";
    if (code >= 2 and code <= 11) {
        const i = code - 2;
        return if (shift) upper[i] else lower[i];
    }
    const row1 = "qwertyuiop";
    if (code >= 16 and code <= 25) {
        const c = row1[code - 16];
        return if (shift) c - 32 else c;
    }
    const row2 = "asdfghjkl";
    if (code >= 30 and code <= 38) {
        const c = row2[code - 30];
        return if (shift) c - 32 else c;
    }
    const row3 = "zxcvbnm";
    if (code >= 44 and code <= 50) {
        const c = row3[code - 44];
        return if (shift) c - 32 else c;
    }
    return switch (code) {
        57 => ' ',
        12 => if (shift) @as(u8, '_') else '-',
        13 => if (shift) @as(u8, '+') else '=',
        26 => if (shift) @as(u8, '{') else '[',
        27 => if (shift) @as(u8, '}') else ']',
        39 => if (shift) @as(u8, ':') else ';',
        40 => if (shift) @as(u8, '"') else '\'',
        41 => if (shift) @as(u8, '~') else '`',
        43 => if (shift) @as(u8, '|') else '\\',
        51 => if (shift) @as(u8, '<') else ',',
        52 => if (shift) @as(u8, '>') else '.',
        53 => if (shift) @as(u8, '?') else '/',
        else => null,
    };
}

/// Thickness steps for a scroll of `value` surface units: one per wheel
/// notch (15 units; v120 wheels report 120 per notch as 15). Touchpads
/// send many small values, which accumulate in `acc` instead of each
/// stepping. Scrolling up (negative) makes strokes thicker.
pub fn scrollSteps(acc: *f64, value: f64) i32 {
    const notch = 15.0;
    if (value == 0) return 0;
    if ((value > 0) != (acc.* > 0) and acc.* != 0) acc.* = 0;
    acc.* += value;
    var steps: i32 = 0;
    while (acc.* >= notch) : (acc.* -= notch) steps -= 1;
    while (acc.* <= -notch) : (acc.* += notch) steps += 1;
    return steps;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn parseInts(comptime n: usize, s: []const u8) ![n]i32 {
    var out: [n]i32 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    for (&out) |*v| v.* = try std.fmt.parseInt(i32, std.mem.trim(u8, it.next() orelse return error.BadScript, " "), 10);
    return out;
}

fn parsePoint(s: []const u8) !Point {
    const v = try parseInts(2, s);
    return .{ .x = v[0], .y = v[1] };
}

/// "ctrl+shift+s", "alt+left", "esc", "?" ... for scripted input.
fn parseKey(spec: []const u8) !window.Key {
    var k: window.Key = .{ .code = 0, .pressed = true, .ctrl = false, .shift = false };
    var it = std.mem.splitScalar(u8, spec, '+');
    var name: []const u8 = "";
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "ctrl")) k.ctrl = true else if (std.mem.eql(u8, part, "shift")) k.shift = true else if (std.mem.eql(u8, part, "alt")) k.alt = true else name = part;
    }
    const named = [_]struct { []const u8, u32 }{
        .{ "esc", window.KEY_ESC },             .{ "enter", window.KEY_ENTER },   .{ "tab", KEY_TAB },
        .{ "backspace", window.KEY_BACKSPACE }, .{ "delete", window.KEY_DELETE }, .{ "space", window.KEY_SPACE },
        .{ "left", KEY_LEFT },                  .{ "right", KEY_RIGHT },          .{ "up", KEY_UP },
        .{ "down", KEY_DOWN },                  .{ "home", KEY_HOME },            .{ "end", KEY_END },
        .{ "f1", KEY_F1 },                      .{ "]", KEY_RIGHTBRACE },         .{ "?", KEY_SLASH },
    };
    for (named) |n| {
        if (std.mem.eql(u8, name, n[0])) k.code = n[1];
    }
    if (std.mem.eql(u8, name, "?")) k.shift = true;
    if (k.code == 0 and name.len == 1) {
        var code: u32 = 1;
        while (code < 60) : (code += 1) {
            if (usKeyChar(code, false) == name[0]) {
                k.code = code;
                break;
            }
        }
    }
    if (k.code == 0) return error.BadKey;
    if (!k.ctrl) if (usKeyChar(k.code, k.shift)) |c| {
        k.text_buf[0] = c;
        k.text_len = 1;
    };
    return k;
}

/// Byte offset in text shape `s` nearest to image point `p`.
pub fn caretAt(s: *const Shape, p: Point) usize {
    const fs = s.fontPx();
    const lh = @max(1, text_mod.height(fs));
    const str = s.str.items;
    var line_no = @divFloor(p.y - s.p0.y, lh);
    if (line_no < 0) line_no = 0;
    var start: usize = 0;
    var it = std.mem.splitScalar(u8, str, '\n');
    var i: i32 = 0;
    var line: []const u8 = "";
    while (it.next()) |l| : (i += 1) {
        line = l;
        if (i == line_no) break;
        if (it.peek() == null) break;
        start += l.len + 1;
    }
    const target = p.x - s.p0.x;
    var best: usize = 0;
    var j: usize = 0;
    while (true) {
        const wj = text_mod.width(fs, line[0..j]);
        if (wj > target) {
            const wp = text_mod.width(fs, line[0..best]);
            if (target - wp > wj - target) best = j;
            break;
        }
        best = j;
        if (j >= line.len) break;
        j = textedit.nextBoundary(line, j);
    }
    return start + best;
}

test "caret lands on the nearest character" {
    const alloc = std.testing.allocator;
    var s = Shape{ .tool = .text, .color = 0xFFFFFFFF, .thickness = 4, .p0 = .{ .x = 100, .y = 100 } };
    defer s.deinit(alloc);
    try s.str.appendSlice(alloc, "abc\ndefgh");
    try std.testing.expectEqual(@as(usize, 0), caretAt(&s, .{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(usize, 3), caretAt(&s, .{ .x = 10000, .y = 100 }));
    const lh = text_mod.height(s.fontPx());
    try std.testing.expectEqual(@as(usize, 9), caretAt(&s, .{ .x = 10000, .y = 100 + lh + 1 }));
    try std.testing.expectEqual(@as(usize, 9), caretAt(&s, .{ .x = 10000, .y = 100000 }));
    try std.testing.expectEqual(@as(usize, 4), caretAt(&s, .{ .x = 100, .y = 100 + lh + 1 }));
}

test "dirty rect list merges on overflow" {
    var l: RectList = .{};
    for (0..70) |i| l.add(.{ .x = @intCast(i), .y = 0, .w = 1, .h = 1 });
    try std.testing.expect(l.len <= 64);
    var u = Rect.empty;
    for (l.slice()) |r| u = Rect.unite(u, r);
    try std.testing.expect(u.eql(.{ .x = 0, .y = 0, .w = 70, .h = 1 }));
    l.add(Rect.empty);
    try std.testing.expect(l.len <= 64);
}

test "scroll accumulates touchpad deltas and steps once per notch" {
    var acc: f64 = 0;
    try std.testing.expectEqual(@as(i32, -1), scrollSteps(&acc, 15));
    try std.testing.expectEqual(@as(i32, 2), scrollSteps(&acc, -30));
    var small: i32 = 0;
    for (0..30) |_| small += scrollSteps(&acc, 1.0);
    try std.testing.expectEqual(@as(i32, -2), small);
    // a direction change drops the leftover
    _ = scrollSteps(&acc, 14);
    try std.testing.expectEqual(@as(i32, 0), scrollSteps(&acc, -14));
    try std.testing.expectEqual(@as(i32, 1), scrollSteps(&acc, -1));
}

test "scripted keys parse" {
    const k = try parseKey("ctrl+shift+s");
    try std.testing.expect(k.ctrl and k.shift);
    try std.testing.expectEqual(@as(u32, KEY_S), k.code);
    const q = try parseKey("?");
    try std.testing.expectEqualStrings("?", q.text());
    try std.testing.expectEqual(@as(u32, KEY_LEFT), (try parseKey("alt+left")).code);
}
