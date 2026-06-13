//! Interactive annotation editor: freeze-frame the screenshot fullscreen,
//! drag to select a region, annotate with Flameshot-style tools, then copy
//! to clipboard or save. Pure software rendering into the window buffer.

const std = @import("std");
const window = @import("window.zig");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const png = @import("../gfx/png.zig");
const config = @import("../app/config.zig");
const shapes_mod = @import("shapes.zig");
const ui = @import("editor_ui.zig");

const Window = window.Window;
const Canvas = render.Canvas;
pub const Tool = shapes_mod.Tool;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;
const palette = shapes_mod.palette;
const drawShape = shapes_mod.drawShape;
const handleAt = shapes_mod.handleAt;
const resizeWithHandle = shapes_mod.resizeWithHandle;
const evdevToChar = shapes_mod.evdevToChar;

pub const Action = enum { cancel, save };

pub const CopyNotice = enum { none, copying, copied, failed };

pub const Result = struct {
    action: Action,
    /// encoded PNG of the selected region; null when action == .cancel
    png_data: ?[]u8 = null,
};

const dim_color: u32 = 0x8C000000;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const DragMode = union(enum) {
    none,
    selecting,
    moving_sel: struct { orig: Rect, start: Point },
    resizing_sel: struct { handle: u3, orig: Rect },
    drawing,
};

// evdev key codes
const KEY_1 = 2;
const KEY_MINUS = 12;
const KEY_EQUAL = 13;
const KEY_Y = 21;
const KEY_T = 20;
const KEY_R = 19;
const KEY_E = 18;
const KEY_A = 30;
const KEY_S = 31;
const KEY_H = 35;
const KEY_L = 38;
const KEY_Z = 44;
const KEY_X = 45;
const KEY_C = 46;
const KEY_V = 47;
const KEY_N = 49;
const KEY_P = 25;
const KEY_KPENTER = 96;

pub const Editor = struct {
    alloc: std.mem.Allocator,
    win: *Window,
    img: *const png.Image,

    // display mapping: image blitted at (off_x, off_y) scaled by `fit` (<= 1)
    base: []u32 = &.{}, // pre-composited background at buffer size
    flat: []u32 = &.{}, // base + committed shapes (rebuilt on undo/redo/commit)
    flat_dim: []u32 = &.{}, // flat, pre-darkened (avoids per-frame blending)
    flat_dirty: bool = true,
    stroke_mask: []u8 = &.{}, // scratch buffer for fast stroke rendering
    fit: f64 = 1.0,
    off_x: i32 = 0,
    off_y: i32 = 0,

    shapes: std.ArrayList(Shape) = .empty,
    redo_stack: std.ArrayList(Shape) = .empty,
    cur: ?Shape = null,
    text_edit: ?Shape = null,

    tool: Tool = .select,
    color_idx: u3 = 0,
    thickness: i32 = 4,
    next_number: u32 = 1,

    sel: ?Rect = null,
    drag: DragMode = .none,
    mouse: Point = .{ .x = 0, .y = 0 },

    buttons: std.ArrayList(ui.Button) = .empty,
    toolbar_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    needs_render: bool = true,
    running: bool = true,
    action: Action = .cancel,
    ui_init: bool = false,
    hover_btn: i32 = -1, // toolbar button under the cursor (-1 = none)
    smoke_deadline_ms: i64 = 0, // dev: auto-cancel timestamp (0 = off)
    cfg_thickness: i32 = 3, // logical default, scaled at first layout
    binds: [config.n_actions]config.Bind = config.default_binds,
    copy_notice: CopyNotice = .none,
    copy_notice_hide_at_ms: i64 = 0,

    pub fn init(alloc: std.mem.Allocator, win: *Window, img: *const png.Image) Editor {
        return .{ .alloc = alloc, .win = win, .img = img };
    }

    /// Dev helper: start with a selection already in place.
    pub fn presetSelection(self: *Editor, sel: ?[4]i32) void {
        if (sel) |v| self.sel = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
    }

    pub fn deinit(self: *Editor) void {
        for (self.shapes.items) |*s| s.deinit(self.alloc);
        self.shapes.deinit(self.alloc);
        for (self.redo_stack.items) |*s| s.deinit(self.alloc);
        self.redo_stack.deinit(self.alloc);
        if (self.cur) |*s| s.deinit(self.alloc);
        if (self.text_edit) |*s| s.deinit(self.alloc);
        self.buttons.deinit(self.alloc);
        self.alloc.free(self.base);
        self.alloc.free(self.flat);
        self.alloc.free(self.flat_dim);
        self.alloc.free(self.stroke_mask);
    }

    /// Free the large pixel caches. Call after the editing session ends but
    /// while the process stays alive (e.g. serving the clipboard).
    pub fn releaseCaches(self: *Editor) void {
        self.alloc.free(self.base);
        self.base = &.{};
        self.alloc.free(self.flat);
        self.flat = &.{};
        self.alloc.free(self.flat_dim);
        self.flat_dim = &.{};
        self.alloc.free(self.stroke_mask);
        self.stroke_mask = &.{};
        self.flat_dirty = true;
    }

    pub fn color(self: *const Editor) u32 {
        return palette[self.color_idx];
    }

    /// UI scale factor from the window's fractional scale (1.0 at 100%).
    pub fn uf(self: *const Editor) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    /// Scale a logical UI length to physical pixels.
    pub fn sc(self: *const Editor, v: f64) i32 {
        return @intFromFloat(@round(v * self.uf()));
    }

    /// Run the editor; returns the user's chosen action and exported PNG.
    pub fn run(self: *Editor) !Result {
        while (self.running) {
            const now = nowMs();
            if (self.smoke_deadline_ms != 0) {
                if (now > self.smoke_deadline_ms) {
                    self.action = .cancel;
                    break;
                }
            }
            if (self.copy_notice_hide_at_ms != 0 and now >= self.copy_notice_hide_at_ms) {
                self.copy_notice = .none;
                self.copy_notice_hide_at_ms = 0;
                self.needs_render = true;
            }
            if (try self.win.nextEventTimeout(100)) |ev| {
                try self.handle(ev);
                // drain whatever else is queued before rendering
                while (self.win.queue.items.len > 0) {
                    try self.handle(try self.win.nextEvent());
                }
            }
            if (self.needs_render and !self.win.frame_pending) {
                try self.renderFrame();
                self.needs_render = false;
            }
        }
        if (self.action == .cancel) return .{ .action = .cancel };
        return .{ .action = self.action, .png_data = try self.exportPng() };
    }

    // --- layout ---

    fn rebuildBase(self: *Editor) !void {
        if (!self.ui_init) {
            self.ui_init = true;
            self.thickness = @max(2, self.sc(@floatFromInt(self.cfg_thickness)));
        }
        const w: i32 = @intCast(self.win.width);
        const h: i32 = @intCast(self.win.height);
        self.alloc.free(self.base);
        self.base = try self.alloc.alloc(u32, @intCast(w * h));
        @memset(self.base, 0xFF101010);

        const iw: f64 = @floatFromInt(self.img.width);
        const ih: f64 = @floatFromInt(self.img.height);
        const fw: f64 = @floatFromInt(w);
        const fh: f64 = @floatFromInt(h);
        self.fit = @min(1.0, @min(fw / iw, fh / ih));
        const dw: i32 = @intFromFloat(iw * self.fit);
        const dh: i32 = @intFromFloat(ih * self.fit);
        self.off_x = @divTrunc(w - dw, 2);
        self.off_y = @divTrunc(h - dh, 2);

        var y: i32 = 0;
        while (y < dh) : (y += 1) {
            const sy: usize = if (self.fit == 1.0) @intCast(y) else @intFromFloat(@as(f64, @floatFromInt(y)) / self.fit);
            const src_row = self.img.pixels[sy * self.img.width ..][0..self.img.width];
            const dst_row = self.base[@intCast((y + self.off_y) * w + self.off_x)..][0..@intCast(dw)];
            if (self.fit == 1.0) {
                @memcpy(dst_row, src_row[0..@intCast(dw)]);
            } else {
                for (dst_row, 0..) |*p, x| {
                    const sx: usize = @intFromFloat(@as(f64, @floatFromInt(x)) / self.fit);
                    p.* = src_row[@min(sx, src_row.len - 1)];
                }
            }
        }

        self.alloc.free(self.flat);
        self.flat = try self.alloc.alloc(u32, self.base.len);
        self.alloc.free(self.flat_dim);
        self.flat_dim = try self.alloc.alloc(u32, self.base.len);
        self.alloc.free(self.stroke_mask);
        self.stroke_mask = try self.alloc.alloc(u8, self.base.len);
        @memset(self.stroke_mask, 0);
        self.flat_dirty = true;
    }

    /// Recompose base + committed shapes (and the dimmed copy). Runs only
    /// when shapes change, so per-frame work stays at two row-memcpys.
    fn ensureFlat(self: *Editor) void {
        if (!self.flat_dirty) return;
        @memcpy(self.flat, self.base);
        var canvas = Canvas.init(self.flat, self.win.width, self.win.height);
        canvas.mask = self.stroke_mask;
        for (self.shapes.items) |*s| drawShape(&canvas, s, false);
        dimCopy(self.flat, self.flat_dim);
        self.flat_dirty = false;
    }

    /// flat_dim = flat darkened by dim_color (fixed alpha). Bit-trick blend:
    /// two multiplies per pixel instead of a full per-channel src-over.
    fn dimCopy(src: []const u32, dst: []u32) void {
        @setRuntimeSafety(false);
        const keep: u32 = 255 - (dim_color >> 24); // remaining brightness
        for (src, dst) |p, *d| {
            const rb = ((p & 0x00FF00FF) * keep >> 8) & 0x00FF00FF;
            const g = ((p & 0x0000FF00) * keep >> 8) & 0x0000FF00;
            d.* = 0xFF000000 | rb | g;
        }
    }

    // --- event handling ---

    fn handle(self: *Editor, ev: window.InputEvent) !void {
        switch (ev) {
            .resize => {
                try self.rebuildBase();
                self.needs_render = true;
            },
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
            .pointer_motion => |m| {
                self.mouse = .{ .x = @intFromFloat(m.x), .y = @intFromFloat(m.y) };
                try self.onMotion();
            },
            .pointer_button => |b| {
                self.mouse = .{ .x = @intFromFloat(b.x), .y = @intFromFloat(b.y) };
                if (b.button == window.BTN_LEFT) {
                    if (b.pressed) try self.onPress() else try self.onRelease();
                } else if (b.button == window.BTN_RIGHT and b.pressed) {
                    try self.onRightClick();
                }
            },
            .pointer_axis => |a| {
                const delta: i32 = if (a.value > 0) -1 else 1;
                self.thickness = std.math.clamp(self.thickness + delta, 1, 32);
                self.needs_render = true;
            },
            .key => |k| {
                if (k.pressed) try self.onKey(k.code, k.ctrl, k.shift);
            },
        }
    }

    fn onMotion(self: *Editor) !void {
        const m = self.mouse;
        switch (self.drag) {
            .none => {
                const cursor: window.Cursor = blk: {
                    if (self.toolbar_rect.contains(m.x, m.y)) break :blk .arrow;
                    if (self.tool == .select) {
                        if (self.sel) |sel| {
                            const n = sel.normalized();
                            if (handleAt(n, m)) |hi| break :blk switch (hi) {
                                0, 4 => .resize_nwse, // nw / se corners
                                2, 6 => .resize_nesw, // ne / sw corners
                                1, 5 => .resize_ns, // n / s edges
                                else => .resize_ew, // e / w edges
                            };
                            if (n.contains(m.x, m.y)) break :blk .move;
                        }
                    }
                    if (self.tool == .text) break :blk .text;
                    break :blk .crosshair;
                };
                try self.win.setCursor(cursor);
                // hover highlight: redraw only when the hovered button changes
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
            },
            .selecting => {
                self.sel.?.w = m.x - self.sel.?.x;
                self.sel.?.h = m.y - self.sel.?.y;
                self.needs_render = true;
            },
            .moving_sel => |mv| {
                self.sel = .{
                    .x = mv.orig.x + (m.x - mv.start.x),
                    .y = mv.orig.y + (m.y - mv.start.y),
                    .w = mv.orig.w,
                    .h = mv.orig.h,
                };
                self.needs_render = true;
            },
            .resizing_sel => |rs| {
                self.sel = resizeWithHandle(rs.orig, rs.handle, m);
                self.needs_render = true;
            },
            .drawing => {
                if (self.cur) |*s| {
                    switch (s.tool) {
                        .pen, .highlight => {
                            const last = s.points.items[s.points.items.len - 1];
                            const dx = m.x - last.x;
                            const dy = m.y - last.y;
                            if (dx * dx + dy * dy >= 4) try s.points.append(self.alloc, m);
                        },
                        else => s.p1 = m,
                    }
                    self.needs_render = true;
                }
            },
        }
    }

    fn onPress(self: *Editor) !void {
        const m = self.mouse;

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

        // commit pending text edit when clicking elsewhere
        if (self.text_edit != null) {
            try self.commitText();
            self.needs_render = true;
        }

        if (self.sel == null or self.tool == .select) {
            if (self.sel) |s| {
                const n = s.normalized();
                if (handleAt(n, m)) |h| {
                    self.drag = .{ .resizing_sel = .{ .handle = h, .orig = n } };
                    return;
                }
                if (n.contains(m.x, m.y)) {
                    self.drag = .{ .moving_sel = .{ .orig = n, .start = m } };
                    return;
                }
            }
            self.sel = .{ .x = m.x, .y = m.y, .w = 0, .h = 0 };
            self.drag = .selecting;
            self.needs_render = true;
            return;
        }

        // annotation tools
        switch (self.tool) {
            .counter => {
                var s = Shape{
                    .tool = .counter,
                    .color = self.color(),
                    .thickness = self.thickness,
                    .p0 = m,
                    .number = self.next_number,
                };
                self.next_number += 1;
                try self.pushShape(&s);
                self.needs_render = true;
            },
            .text => {
                var s = Shape{
                    .tool = .text,
                    .color = self.color(),
                    .thickness = self.thickness,
                    .p0 = m,
                };
                errdefer s.deinit(self.alloc);
                self.text_edit = s;
                self.needs_render = true;
            },
            else => {
                var s = Shape{
                    .tool = self.tool,
                    .color = self.color(),
                    .thickness = self.thickness,
                    .p0 = m,
                    .p1 = m,
                };
                errdefer s.deinit(self.alloc);
                if (self.tool == .pen or self.tool == .highlight) {
                    try s.points.append(self.alloc, m);
                }
                self.cur = s;
                self.drag = .drawing;
            },
        }
    }

    fn onRelease(self: *Editor) !void {
        switch (self.drag) {
            .selecting => {
                const s = self.sel.?.normalized();
                if (s.w < 4 or s.h < 4) {
                    self.sel = null; // treat as a stray click
                } else {
                    self.sel = s;
                }
                self.needs_render = true;
            },
            .moving_sel, .resizing_sel => {
                self.sel = self.sel.?.normalized();
                self.needs_render = true;
            },
            .drawing => {
                if (self.cur) |*s| {
                    var owned = s.*;
                    self.cur = null;
                    try self.pushShape(&owned);
                    self.needs_render = true;
                }
            },
            .none => {},
        }
        self.drag = .none;
    }

    fn onRightClick(self: *Editor) !void {
        if (self.text_edit) |*s| {
            s.deinit(self.alloc);
            self.text_edit = null;
        } else if (self.cur) |*s| {
            s.deinit(self.alloc);
            self.cur = null;
            self.drag = .none;
        } else if (self.sel != null) {
            self.sel = null;
        }
        self.needs_render = true;
    }

    fn onButton(self: *Editor, kind: ui.ButtonKind) !void {
        if (self.text_edit != null) try self.commitText();
        switch (kind) {
            .tool => |t| self.tool = t,
            .color => |c| self.color_idx = c,
            .undo => self.undo(),
            .redo => self.redoOne(),
            .copy => try self.copyToClipboard(),
            .save => {
                self.action = .save;
                self.running = false;
            },
            .cancel => {
                self.action = .cancel;
                self.running = false;
            },
        }
        self.needs_render = true;
    }

    fn onKey(self: *Editor, code: u32, ctrl: bool, shift: bool) !void {
        // text editing captures most keys
        if (self.text_edit != null) {
            try self.onTextKey(code, ctrl, shift);
            return;
        }

        // configurable bindings first
        for (self.binds, 0..) |b, i| {
            if (!b.matches(code, ctrl, shift)) continue;
            switch (@as(config.Action, @enumFromInt(i))) {
                .select => self.tool = .select,
                .pen => self.tool = .pen,
                .line => self.tool = .line,
                .arrow => self.tool = .arrow,
                .rect => self.tool = .rect,
                .ellipse => self.tool = .ellipse,
                .highlight => self.tool = .highlight,
                .pixelate => self.tool = .pixelate,
                .counter => self.tool = .counter,
                .text => self.tool = .text,
                .copy => try self.copyToClipboard(),
                .save => {
                    self.ensureSelection();
                    self.action = .save;
                    self.running = false;
                },
                .undo => self.undo(),
                .redo => self.redoOne(),
            }
            self.needs_render = true;
            return;
        }

        // fixed keys
        switch (code) {
            window.KEY_ESC => {
                if (self.cur != null) {
                    self.cur.?.deinit(self.alloc);
                    self.cur = null;
                    self.drag = .none;
                } else {
                    self.action = .cancel;
                    self.running = false;
                }
            },
            window.KEY_ENTER, KEY_KPENTER => try self.copyToClipboard(),
            KEY_Y => if (ctrl) self.redoOne(),
            KEY_MINUS => self.thickness = @max(1, self.thickness - 1),
            KEY_EQUAL => self.thickness = @min(32, self.thickness + 1),
            KEY_1...KEY_1 + 7 => if (!ctrl) {
                self.color_idx = @intCast(code - KEY_1);
            },
            else => return,
        }
        self.needs_render = true;
    }

    fn onTextKey(self: *Editor, code: u32, ctrl: bool, shift: bool) !void {
        const s = &self.text_edit.?;
        switch (code) {
            window.KEY_ESC => {
                s.deinit(self.alloc);
                self.text_edit = null;
            },
            window.KEY_ENTER, KEY_KPENTER => try self.commitText(),
            window.KEY_BACKSPACE => {
                if (s.str.items.len > 0) _ = s.str.pop();
            },
            else => {
                if (ctrl) return;
                if (evdevToChar(code, shift)) |c| {
                    try s.str.append(self.alloc, c);
                }
            },
        }
        self.needs_render = true;
    }

    fn commitText(self: *Editor) !void {
        if (self.text_edit) |*s| {
            if (s.str.items.len == 0) {
                s.deinit(self.alloc);
            } else {
                var owned = s.*;
                try self.pushShape(&owned);
            }
            self.text_edit = null;
        }
    }

    fn copyToClipboard(self: *Editor) !void {
        if (self.text_edit != null) try self.commitText();

        self.showCopyNotice(.copying, 0);
        try self.renderFrame();
        self.needs_render = false;

        const png_data = try self.exportPng();
        self.win.setClipboardPng(png_data) catch |err| {
            self.alloc.free(png_data);
            std.log.warn("copy failed: {t}", .{err});
            self.showCopyNotice(.failed, 1200);
            return;
        };
        self.showCopyNotice(.copied, 1200);
    }

    fn showCopyNotice(self: *Editor, copy_notice: CopyNotice, duration_ms: i64) void {
        self.copy_notice = copy_notice;
        self.copy_notice_hide_at_ms = if (duration_ms > 0) nowMs() + duration_ms else 0;
        self.needs_render = true;
    }

    fn ensureSelection(self: *Editor) void {
        if (self.sel == null) {
            self.sel = .{ .x = 0, .y = 0, .w = @intCast(self.win.width), .h = @intCast(self.win.height) };
        }
    }

    fn pushShape(self: *Editor, s: *Shape) !void {
        errdefer s.deinit(self.alloc);
        for (self.redo_stack.items) |*r| r.deinit(self.alloc);
        self.redo_stack.clearRetainingCapacity();
        try self.shapes.append(self.alloc, s.*);
        self.flat_dirty = true;
    }

    fn undo(self: *Editor) void {
        if (self.shapes.items.len == 0) return;
        const s = self.shapes.pop().?;
        if (s.tool == .counter and self.next_number > 1) self.next_number -= 1;
        self.redo_stack.append(self.alloc, s) catch {};
        self.flat_dirty = true;
    }

    fn redoOne(self: *Editor) void {
        if (self.redo_stack.items.len == 0) return;
        const s = self.redo_stack.pop().?;
        if (s.tool == .counter) self.next_number += 1;
        self.shapes.append(self.alloc, s) catch {};
        self.flat_dirty = true;
    }

    // --- rendering ---

    fn renderFrame(self: *Editor) !void {
        self.ensureFlat();
        const px = try self.win.backBuffer();
        var canvas = Canvas.init(px, self.win.width, self.win.height);
        canvas.mask = self.stroke_mask;
        self.composeBackground(px);

        // committed shapes live in the flat cache; draw only what is pending
        if (self.cur) |*s| drawShape(&canvas, s, false);
        if (self.text_edit) |*s| drawShape(&canvas, s, true);
        ui.drawSelectionChrome(self, &canvas);
        try ui.layoutToolbar(self);
        ui.drawToolbar(self, &canvas);
        if (self.copy_notice != .none) ui.drawCopyNotice(self, &canvas);
        try self.win.present();
    }

    /// Fill the frame with dimmed background outside the selection and the
    /// bright capture inside it, using row memcpys only.
    fn composeBackground(self: *Editor, px: []u32) void {
        const w: usize = self.win.width;
        const h: usize = self.win.height;
        const sel = if (self.sel) |s| s.normalized() else {
            @memcpy(px[0..self.flat_dim.len], self.flat_dim);
            return;
        };
        const sx: usize = @intCast(std.math.clamp(sel.x, 0, @as(i32, @intCast(w))));
        const sy: usize = @intCast(std.math.clamp(sel.y, 0, @as(i32, @intCast(h))));
        const ex: usize = @intCast(std.math.clamp(sel.x + sel.w, 0, @as(i32, @intCast(w))));
        const ey: usize = @intCast(std.math.clamp(sel.y + sel.h, 0, @as(i32, @intCast(h))));

        // rows fully above/below the selection
        if (sy > 0) @memcpy(px[0 .. sy * w], self.flat_dim[0 .. sy * w]);
        if (ey < h) @memcpy(px[ey * w ..], self.flat_dim[ey * w ..]);
        // rows crossing the selection
        var y = sy;
        while (y < ey) : (y += 1) {
            const row = y * w;
            if (sx > 0) @memcpy(px[row .. row + sx], self.flat_dim[row .. row + sx]);
            if (ex > sx) @memcpy(px[row + sx .. row + ex], self.flat[row + sx .. row + ex]);
            if (ex < w) @memcpy(px[row + ex .. row + w], self.flat_dim[row + ex .. row + w]);
        }
    }

    // --- export ---

    fn exportPng(self: *Editor) ![]u8 {
        self.ensureSelection();
        const sel = self.sel.?.normalized();

        // include uncommitted text, then use the flat cache (base + shapes)
        if (self.text_edit != null) try self.commitText();
        self.ensureFlat();
        const w: i32 = @intCast(self.win.width);
        const h: i32 = @intCast(self.win.height);
        const px = self.flat;

        const cx = std.math.clamp(sel.x, 0, w - 1);
        const cy = std.math.clamp(sel.y, 0, h - 1);
        const cw = std.math.clamp(sel.w, 1, w - cx);
        const ch = std.math.clamp(sel.h, 1, h - cy);

        const crop = try self.alloc.alloc(u32, @intCast(cw * ch));
        defer self.alloc.free(crop);
        var y: i32 = 0;
        while (y < ch) : (y += 1) {
            const src = px[@intCast((cy + y) * w + cx)..][0..@intCast(cw)];
            @memcpy(crop[@intCast(y * cw)..][0..@intCast(cw)], src);
        }
        return png.encode(self.alloc, crop, @intCast(cw), @intCast(ch));
    }
};
