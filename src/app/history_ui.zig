//! "Recent captures" (`shotlet history`, and the tray menu): a small
//! panel listing the kept captures as a two-column grid of thumbnails
//! with relative times. Click one to pick it, then Copy, Save, Annotate,
//! Pin or Delete it (Enter copies, Delete removes, Esc closes). When
//! Tesseract is installed the captures are read in the background and a
//! search field filters them by their text; without it there is no field.

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const keep = @import("keep.zig");
const clock = @import("clock.zig");
const shot = @import("shot.zig");
const dbus = @import("../platform/dbus.zig");
const ocr = @import("../platform/ocr.zig");
const sys = @import("../platform/sys.zig");
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const window = @import("../ui/window.zig");
const shapes = @import("../ui/shapes.zig");
const fui = @import("../ui/floatui.zig");
const Env = env_mod.Env;
const Rect = shapes.Rect;
const Canvas = fui.Canvas;

// layout, logical pixels (the mockup's panel)
pub const panel_w = 300;
const pad = 18; // shadow room around the panel
const inset = 14;
const header_h = 20;
const field_h = 32;
const col_gap = 10;
const thumb_h = 82;
const label_h = 18;
const row_gap = 10;
const actions_h = 40;
const max_panel_h = 620;
const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "Just now", "4 min ago", "Today 11:02", "Yesterday", "Wed", "Nov 3".
/// Both times are local seconds (UTC plus the zone's offset).
pub fn relTime(buf: []u8, now: i64, then: i64) []const u8 {
    const d = now - then;
    if (d < 60) return "Just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(d, 60)}) catch "";
    const day_now = @divFloor(now, 86400);
    const day_then = @divFloor(then, 86400);
    const lt = clock.breakDown(then);
    if (day_now == day_then) return std.fmt.bufPrint(buf, "Today {d:0>2}:{d:0>2}", .{ lt.hour, lt.minute }) catch "";
    if (day_now - day_then == 1) return "Yesterday";
    if (day_now - day_then < 7) return weekdays[@intCast(@mod(day_then, 7))];
    return std.fmt.bufPrint(buf, "{s} {d}", .{ months[lt.month - 1], lt.day }) catch "";
}

test "relative capture times" {
    var b: [32]u8 = undefined;
    const now: i64 = 1763740953; // Fri 2025-11-21 16:02:33
    try std.testing.expectEqualStrings("Just now", relTime(&b, now, now - 5));
    try std.testing.expectEqualStrings("4 min ago", relTime(&b, now, now - 4 * 60 - 10));
    try std.testing.expectEqualStrings("Today 11:02", relTime(&b, now, now - 5 * 3600));
    try std.testing.expectEqualStrings("Yesterday", relTime(&b, now, now - 86400));
    try std.testing.expectEqualStrings("Wed", relTime(&b, now, now - 2 * 86400));
    try std.testing.expectEqualStrings("Nov 3", relTime(&b, now, now - 18 * 86400));
}

pub const Action = enum { copy, save, annotate, pin, delete };
const action_icons = [_]fui.Icon{ .copy, .save, .pencil, .pin, .trash };
const action_names = [_][]const u8{ "Copy", "Save", "Annotate", "Pin", "Delete" };

const Item = struct {
    entry: history.Entry,
    thumb: ?png.Image,
    scaled: []u32 = &.{},
    sw: u32 = 0,
    sh: u32 = 0,
};

/// Background OCR of entries that were never read.
const Ocr = struct {
    mutex: ocr.SpinLock = .{},
    /// ids whose text was just written to their meta
    done: std.ArrayList(history.Id) = .empty,
    finished: bool = false,
    thread: ?std.Thread = null,
    stop: bool = false,

    fn worker(self: *Ocr, gpa: std.mem.Allocator, root: []const u8, ids: []history.Id) void {
        defer gpa.free(ids);
        for (ids) |id| {
            if (@atomicLoad(bool, &self.stop, .acquire)) break;
            readOne(gpa, root, id.slice()) catch |err| std.log.info("ocr of {s} failed: {t}", .{ id.slice(), err });
            self.mutex.lock();
            self.done.append(gpa, id) catch {};
            self.mutex.unlock();
        }
        self.mutex.lock();
        self.finished = true;
        self.mutex.unlock();
    }

    fn readOne(gpa: std.mem.Allocator, root: []const u8, id: []const u8) !void {
        var pbuf: [1200]u8 = undefined;
        const data = try sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, "image.png"), 512 * 1024 * 1024);
        defer gpa.free(data);
        var img = try png.decode(gpa, data);
        defer img.deinit(gpa);
        const t = ocr.recognize(gpa, img.pixels, img.width, img.height) orelse "";
        defer if (t.len > 0) gpa.free(t);
        var meta = try history.readMeta(gpa, root, id);
        defer meta.deinit(gpa);
        if (meta.ocr) |o| gpa.free(o);
        meta.ocr = try gpa.dupe(u8, t);
        try history.writeMeta(gpa, root, id, &meta);
    }
};

const Panel = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: config.Config,
    win: window.Window,
    bus: ?dbus.Connection = null,
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    items: std.ArrayList(Item) = .empty,
    /// indexes into items that match the search
    shown: std.ArrayList(usize) = .empty,
    selected: ?usize = null,
    hover_item: ?usize = null,
    hover_action: ?usize = null,
    hover_clear: bool = false,
    hover_close: bool = false,
    pressed: ?u32 = null,
    scroll: i32 = 0,
    search: std.ArrayList(u8) = .empty,
    searchable: bool = false,
    notice: []const u8 = "",
    notice_until: i64 = 0,
    dirty: bool = true,
    ocr_state: Ocr = .{},
    theme: fui.Theme = fui.Theme.dark,

    fn root(self: *const Panel) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    fn k(self: *const Panel) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    fn deinit(self: *Panel) void {
        if (self.ocr_state.thread) |t| {
            @atomicStore(bool, &self.ocr_state.stop, true, .release);
            t.join();
        }
        self.ocr_state.done.deinit(self.gpa);
        self.freeItems();
        self.items.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        self.search.deinit(self.gpa);
        self.win.deinit();
        if (self.bus) |*b| b.deinit();
    }

    fn freeItems(self: *Panel) void {
        for (self.items.items) |*it| {
            it.entry.deinit(self.gpa);
            if (it.thumb) |*t| t.deinit(self.gpa);
            self.gpa.free(it.scaled);
        }
        self.items.clearRetainingCapacity();
    }

    fn load(self: *Panel) !void {
        self.freeItems();
        const list = try history.list(self.gpa, self.root());
        defer self.gpa.free(list);
        for (list) |e| {
            var pbuf: [1200]u8 = undefined;
            const thumb: ?png.Image = blk: {
                const p = history.entryPath(&pbuf, self.root(), e.id.slice(), "thumb.png") catch break :blk null;
                const data = sys.readFileAlloc(self.gpa, p, 16 * 1024 * 1024) catch break :blk null;
                defer self.gpa.free(data);
                break :blk png.decode(self.gpa, data) catch null;
            };
            try self.items.append(self.gpa, .{ .entry = e, .thumb = thumb });
        }
        self.filter();
        std.log.info("history: {d} captures", .{self.items.items.len});
    }

    fn filter(self: *Panel) void {
        self.shown.clearRetainingCapacity();
        for (self.items.items, 0..) |it, i| {
            if (self.search.items.len > 0) {
                const t = it.entry.meta.ocr orelse continue;
                if (!ocr.matches(t, self.search.items)) continue;
            }
            self.shown.append(self.gpa, i) catch {};
        }
        if (self.selected) |s| if (std.mem.indexOfScalar(usize, self.shown.items, s) == null) {
            self.selected = null;
        };
        self.scroll = 0;
        self.dirty = true;
    }

    fn startOcr(self: *Panel) void {
        if (!self.searchable) return;
        var ids: std.ArrayList(history.Id) = .empty;
        for (self.items.items) |it| if (it.entry.meta.ocr == null) ids.append(self.gpa, it.entry.id) catch {};
        if (ids.items.len == 0) {
            ids.deinit(self.gpa);
            return;
        }
        const owned = ids.toOwnedSlice(self.gpa) catch return;
        self.ocr_state.thread = std.Thread.spawn(.{}, Ocr.worker, .{ &self.ocr_state, self.gpa, self.root(), owned }) catch {
            self.gpa.free(owned);
            return;
        };
    }

    /// Pick up text the OCR thread wrote.
    fn pollOcr(self: *Panel) void {
        self.ocr_state.mutex.lock();
        defer self.ocr_state.mutex.unlock();
        if (self.ocr_state.done.items.len == 0) return;
        for (self.ocr_state.done.items) |id| {
            for (self.items.items) |*it| {
                if (!std.mem.eql(u8, it.entry.id.slice(), id.slice())) continue;
                var m = history.readMeta(self.gpa, self.root(), id.slice()) catch continue;
                it.entry.meta.deinit(self.gpa);
                it.entry.meta = m;
                m = .{};
            }
        }
        self.ocr_state.done.clearRetainingCapacity();
        if (self.search.items.len > 0) self.filter();
    }

    // --- layout (logical, relative to the panel's top-left) ---

    fn searchTop(self: *const Panel) i32 {
        _ = self;
        return inset + header_h + 10;
    }

    fn gridTop(self: *const Panel) i32 {
        return self.searchTop() + if (self.searchable) @as(i32, field_h + 12) else 0;
    }

    fn colW() i32 {
        return @divTrunc(panel_w - 2 * inset - col_gap, 2);
    }

    fn itemH() i32 {
        return thumb_h + 6 + label_h;
    }

    fn contentH(self: *const Panel) i32 {
        const rows: i32 = @intCast((self.shown.items.len + 1) / 2);
        return @max(60, rows * itemH() + @max(0, rows - 1) * row_gap);
    }

    fn panelH(self: *const Panel) i32 {
        const h = self.gridTop() + self.contentH() + inset + actions_h;
        return @min(h, max_panel_h);
    }

    fn gridViewH(self: *const Panel) i32 {
        return self.panelH() - self.gridTop() - inset - actions_h;
    }

    /// Item n of `shown` (grid order), in panel coordinates (scrolled).
    fn itemRect(self: *const Panel, n: usize) Rect {
        const col: i32 = @intCast(n % 2);
        const row: i32 = @intCast(n / 2);
        return .{ .x = inset + col * (colW() + col_gap), .y = self.gridTop() + row * (itemH() + row_gap) - self.scroll, .w = colW(), .h = itemH() };
    }

    fn actionRect(self: *const Panel, i: usize) Rect {
        const w = @divTrunc(panel_w - 2 * inset, @as(i32, action_names.len));
        return .{ .x = inset + @as(i32, @intCast(i)) * w, .y = self.panelH() - actions_h - 4, .w = w, .h = actions_h };
    }

    fn clearRect(self: *const Panel) Rect {
        _ = self;
        return .{ .x = panel_w - inset - 26 - 44, .y = inset - 3, .w = 44, .h = header_h + 6 };
    }

    fn closeRect(self: *const Panel) Rect {
        _ = self;
        return .{ .x = panel_w - inset - 22, .y = inset - 1, .w = 22, .h = 22 };
    }

    fn resize(self: *Panel) !void {
        const w: u32 = panel_w + 2 * pad;
        const h: u32 = @intCast(self.panelH() + 2 * pad);
        try self.win.resizeTo(0, w, h);
        try self.win.setWindowGeometry(0, .{ .x = pad, .y = pad, .w = panel_w, .h = @intCast(h - 2 * pad) });
        try self.win.setInputRegion(0, &.{.{ .x = pad, .y = pad, .w = panel_w, .h = @intCast(h - 2 * pad) }});
    }

    // --- actions ---

    fn bus_(self: *Panel) ?*dbus.Connection {
        if (self.bus == null) self.bus = dbus.Connection.connectSession(self.gpa, self.env.bus_addr) catch return null;
        return &self.bus.?;
    }

    fn say(self: *Panel, s: []const u8) void {
        self.notice = s;
        self.notice_until = sys.monoMs() + 1500;
        self.dirty = true;
    }

    fn act(self: *Panel, a: Action) void {
        const i = self.selected orelse return;
        self.actInner(i, a) catch |err| {
            std.log.warn("history: {t} failed: {t}", .{ a, err });
            self.say("Failed");
        };
    }

    fn actInner(self: *Panel, i: usize, a: Action) !void {
        const it = &self.items.items[i];
        const id = it.entry.id.slice();
        var pbuf: [1200]u8 = undefined;
        const image = try history.entryPath(&pbuf, self.root(), id, "image.png");
        switch (a) {
            .copy => {
                const data = try sys.readFileAlloc(self.gpa, image, 512 * 1024 * 1024);
                self.win.setClipboardPng(data) catch |err| {
                    self.gpa.free(data);
                    return err;
                };
                std.log.info("history: copied {s}", .{id});
                self.say("Copied");
            },
            .save => {
                const data = try sys.readFileAlloc(self.gpa, image, 512 * 1024 * 1024);
                defer self.gpa.free(data);
                const path = try shot.savePng(self.gpa, self.env, &self.cfg, data);
                defer self.gpa.free(path);
                self.gpa.free(it.entry.meta.saved);
                it.entry.meta.saved = &.{};
                it.entry.meta.saved = try self.gpa.dupe(u8, path);
                history.writeMeta(self.gpa, self.root(), id, &it.entry.meta) catch {};
                std.log.info("history: saved to {s}", .{path});
                self.say("Saved");
            },
            .annotate => {
                if (!it.entry.editable) return;
                const r = try self.gpa.dupeSentinel(u8, self.root(), 0);
                defer self.gpa.free(r);
                const idz = try self.gpa.dupeSentinel(u8, id, 0);
                defer self.gpa.free(idz);
                keep.spawnSelf(self.env, &.{ "edit", r.ptr, idz.ptr });
            },
            .pin => {
                const p = try self.gpa.dupeSentinel(u8, image, 0);
                defer self.gpa.free(p);
                keep.spawnSelf(self.env, &.{ "pin", p.ptr });
            },
            .delete => {
                try history.remove(self.root(), id);
                std.log.info("history: deleted {s}", .{id});
                self.selected = null;
                try self.load();
                try self.resize();
            },
        }
        self.dirty = true;
    }

    fn clearAll(self: *Panel) !void {
        history.clear(self.root());
        std.log.info("history: cleared", .{});
        self.selected = null;
        try self.load();
        try self.resize();
    }

    // --- input ---

    fn hitItem(self: *const Panel, x: i32, y: i32) ?usize {
        if (y < self.gridTop() or y >= self.gridTop() + self.gridViewH()) return null;
        for (self.shown.items, 0..) |idx, n| {
            if (self.itemRect(n).contains(x, y)) return idx;
        }
        return null;
    }

    fn hitAction(self: *const Panel, x: i32, y: i32) ?usize {
        if (self.selected == null) return null;
        for (0..action_names.len) |i| if (self.actionRect(i).contains(x, y)) return i;
        return null;
    }

    fn onMotion(self: *Panel, bx: f64, by: f64) void {
        const kk = self.k();
        const x: i32 = @intFromFloat(bx / kk - pad);
        const y: i32 = @intFromFloat(by / kk - pad);
        const inside = bx >= 0;
        const hi = if (inside) self.hitItem(x, y) else null;
        const ha = if (inside) self.hitAction(x, y) else null;
        const hc = inside and self.clearRect().contains(x, y) and self.items.items.len > 0;
        const hx = inside and self.closeRect().contains(x, y);
        if (hi != self.hover_item or ha != self.hover_action or hc != self.hover_clear or hx != self.hover_close) self.dirty = true;
        self.hover_item = hi;
        self.hover_action = ha;
        self.hover_clear = hc;
        self.hover_close = hx;
    }

    /// Returns false to close the panel.
    fn onEvent(self: *Panel, ev: window.InputEvent) !bool {
        switch (ev) {
            .close => return false,
            .resize, .frame_done => self.dirty = true,
            .pointer_motion => |m| self.onMotion(m.x, m.y),
            .pointer_button => |b| {
                self.onMotion(b.x, b.y);
                if (b.button != window.BTN_LEFT) return true;
                const kk = self.k();
                const y: i32 = @intFromFloat(b.y / kk - pad);
                if (!b.pressed) return true;
                if (self.hover_close) return false;
                if (self.hover_clear) {
                    try self.clearAll();
                } else if (self.hover_action) |a| {
                    self.act(@fromBackingInt(@intCast(a)));
                } else if (self.hover_item) |i| {
                    self.selected = if (self.selected == i) null else i;
                    self.dirty = true;
                } else if (y < inset + header_h + 4) {
                    try self.win.startMoveOf(0);
                }
            },
            .pointer_axis => |a| {
                const maxs = @max(0, self.contentH() - self.gridViewH());
                self.scroll = std.math.clamp(self.scroll + @as(i32, @intFromFloat(a.value * 4)), 0, maxs);
                self.dirty = true;
            },
            .key => |key| {
                if (!key.pressed) return true;
                switch (key.code) {
                    window.KEY_ESC => {
                        if (self.search.items.len > 0) {
                            self.search.clearRetainingCapacity();
                            self.filter();
                        } else if (self.selected != null) {
                            self.selected = null;
                        } else return false;
                    },
                    window.KEY_DELETE => self.act(.delete),
                    window.KEY_ENTER, window.KEY_KPENTER => self.act(.copy),
                    window.KEY_BACKSPACE => if (self.search.items.len > 0) {
                        var n = self.search.items.len - 1;
                        while (n > 0 and (self.search.items[n] & 0xC0) == 0x80) n -= 1;
                        self.search.shrinkRetainingCapacity(n);
                        self.filter();
                    },
                    window.KEY_LEFT, window.KEY_RIGHT, window.KEY_UP, window.KEY_DOWN, window.KEY_TAB => self.moveSelection(key.code, key.shift),
                    else => if (key.ctrl and key.code == 46) {
                        self.act(.copy);
                    } else if (key.ctrl and key.code == 31) {
                        self.act(.save);
                    } else if (self.searchable and key.text().len > 0 and !key.ctrl) {
                        self.search.appendSlice(self.gpa, key.text()) catch {};
                        self.filter();
                    },
                }
                self.dirty = true;
            },
        }
        return true;
    }

    fn moveSelection(self: *Panel, code: u32, shift: bool) void {
        if (self.shown.items.len == 0) return;
        const n = self.shown.items.len;
        var pos: usize = if (self.selected) |s| std.mem.indexOfScalar(usize, self.shown.items, s) orelse 0 else n - 1;
        const step: usize = switch (code) {
            window.KEY_UP => n - @min(n, 2),
            window.KEY_DOWN => 2,
            window.KEY_LEFT => n - 1,
            window.KEY_TAB => if (shift) n - 1 else 1,
            else => 1,
        };
        if (self.selected == null) pos = if (code == window.KEY_LEFT or (code == window.KEY_TAB and shift)) 0 else n - 1;
        pos = (pos + step) % n;
        self.selected = self.shown.items[pos];
        // keep it in view
        const r = self.itemRect(pos);
        if (r.y < self.gridTop()) self.scroll -= self.gridTop() - r.y;
        if (r.bottom() > self.gridTop() + self.gridViewH()) self.scroll += r.bottom() - self.gridTop() - self.gridViewH();
    }

    // --- drawing ---

    fn render(self: *Panel) !void {
        if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
        self.dirty = false;
        const kk = self.k();
        const px = try self.win.backBuffer();
        const bw = self.win.width;
        const bh = self.win.height;
        @memset(px, 0);
        const pw: u32 = @intFromFloat(@round(panel_w * kk));
        const ph_l = self.panelH();
        const ph: u32 = @min(bh -| @as(u32, @intFromFloat(@round(2 * pad * kk))), @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(ph_l)) * kk))));
        if (ph == 0 or pw == 0) return;
        const panel = try self.gpa.alloc(u32, @as(usize, pw) * ph);
        defer self.gpa.free(panel);
        const th = self.theme;
        @memset(panel, th.panel);
        var cv = Canvas.init(panel, pw, ph);
        const s = struct {
            fn s(v: i32, f: f64) i32 {
                return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * f));
            }
        }.s;

        // header
        text.drawStyled(&cv, s(inset, kk), s(inset, kk), 14 * kk, th.fg, .bold, "Recent captures");
        if (self.items.items.len > 0) {
            const cr = self.clearRect();
            fui.textCentered(&cv, .{ .x = s(cr.x, kk), .y = s(cr.y, kk), .w = s(cr.w, kk), .h = s(cr.h, kk) }, 12 * kk, if (self.hover_clear) th.accent else th.muted, .regular, "Clear");
        }
        const xr = self.closeRect();
        const xcx = (@as(f64, @floatFromInt(xr.x)) + 11) * kk;
        const xcy = (@as(f64, @floatFromInt(xr.y)) + 11) * kk;
        if (self.hover_close) cv.fillCircleAA(xcx, xcy, 11 * kk, th.field);
        fui.icon(&cv, .close, xcx, xcy, 14 * kk, th.muted);

        // search field
        if (self.searchable) {
            const y = s(self.searchTop(), kk);
            cv.fillRoundRectAA(s(inset, kk), y, s(panel_w - 2 * inset, kk), s(field_h, kk), 8 * kk, th.field);
            fui.icon(&cv, .search, @as(f64, @floatFromInt(inset + 17)) * kk, @as(f64, @floatFromInt(y)) + 16 * kk, 14 * kk, th.muted);
            const ty = y + @divTrunc(s(field_h, kk) - text.height(13 * kk), 2);
            if (self.search.items.len == 0) {
                text.draw(&cv, s(inset + 32, kk), ty, 13 * kk, th.muted, "Search text in captures");
            } else {
                text.draw(&cv, s(inset + 32, kk), ty, 13 * kk, th.fg, self.search.items);
            }
        }

        // grid, clipped to its band
        const top = s(self.gridTop(), kk);
        const view_h = s(self.gridViewH(), kk);
        const grid = try self.gpa.alloc(u32, @as(usize, pw) * @as(usize, @intCast(@max(1, view_h))));
        defer self.gpa.free(grid);
        @memset(grid, th.panel);
        var gc = Canvas.init(grid, pw, @intCast(@max(1, view_h)));
        if (self.shown.items.len == 0) {
            const msg = if (!self.cfg.history) "History is off (history=false)" else if (self.search.items.len > 0) "No capture has that text" else "Nothing copied or saved yet";
            fui.textCentered(&gc, .{ .x = 0, .y = 0, .w = @intCast(pw), .h = @min(view_h, s(60, kk)) }, 13 * kk, th.muted, .regular, msg);
        }
        var now_local: i64 = 0;
        const now = sys.realtimeSec();
        now_local = now + clock.utcOffset(self.gpa, self.env.tz, now);
        for (self.shown.items, 0..) |idx, n| {
            const r = self.itemRect(n);
            const rx = s(r.x, kk);
            const ry = s(r.y, kk) - top;
            const rw = s(r.w, kk);
            const rh = s(thumb_h, kk);
            if (ry + s(itemH(), kk) < 0 or ry > view_h) continue;
            const it = &self.items.items[idx];
            const tw: u32 = @intCast(rw);
            const tth: u32 = @intCast(rh);
            if (it.sw != tw or it.sh != tth) {
                self.gpa.free(it.scaled);
                it.scaled = &.{};
                it.scaled = try self.gpa.alloc(u32, @as(usize, tw) * tth);
                it.sw = tw;
                it.sh = tth;
                if (it.thumb) |t| {
                    const cov = try coverScaled(self.gpa, t, tw, tth);
                    defer self.gpa.free(cov.pixels);
                    fui.drawImageFill(it.scaled, tw, tth, cov.pixels, cov.width, cov.height);
                } else @memset(it.scaled, fui.card_bg);
            }
            // a rounded thumbnail with a hairline
            const rr = self.gpa.alloc(u32, @as(usize, tw) * tth) catch continue;
            defer self.gpa.free(rr);
            @memcpy(rr, it.scaled);
            blitRoundedClipped(grid, pw, @intCast(view_h), rr, tw, tth, rx, ry, @intFromFloat(8 * kk));
            const sel = self.selected == idx;
            const hov = self.hover_item == idx;
            if (sel or hov) {
                shapes.roundRectRing(&gc, .{ .x = rx - s(2, kk), .y = ry - s(2, kk), .w = rw + s(4, kk), .h = rh + s(4, kk) }, 10 * kk, if (sel) 2.5 * kk else 1.5 * kk, if (sel) th.accent else th.line);
            }
            var tb: [32]u8 = undefined;
            const then = @divFloor(it.entry.meta.time_ms, 1000);
            const when = relTime(&tb, now_local, then + clock.utcOffset(self.gpa, self.env.tz, then));
            text.draw(&gc, rx, ry + rh + s(6, kk), 11 * kk, th.muted, when);
            if (it.entry.meta.saved.len > 0) {
                const w2 = text.width(11 * kk, when);
                text.draw(&gc, rx + w2 + s(6, kk), ry + rh + s(6, kk), 11 * kk, th.muted, "· saved");
            }
        }
        for (0..@intCast(view_h)) |row| {
            const dy = @as(usize, @intCast(top)) + row;
            if (dy >= ph) break;
            @memcpy(panel[dy * pw ..][0..pw], grid[row * pw ..][0..pw]);
        }

        // actions for the picked capture
        if (self.selected) |si| {
            const it = &self.items.items[si];
            const ay = s(self.actionRect(0).y, kk);
            cv.fillRect(s(inset, kk), ay - s(2, kk), s(panel_w - 2 * inset, kk), @max(1, s(1, kk)), th.line);
            for (action_names, 0..) |name, i| {
                const r = self.actionRect(i);
                const cx = (@as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) / 2) * kk;
                const dim = i == 2 and !it.entry.editable;
                const color = if (dim) th.line else if (self.hover_action == i) th.accent else th.fg;
                fui.icon(&cv, action_icons[i], cx, (@as(f64, @floatFromInt(r.y)) + 13) * kk, 16 * kk, color);
                fui.textCentered(&cv, .{ .x = s(r.x, kk), .y = s(r.y + 24, kk), .w = s(r.w, kk), .h = s(14, kk) }, 10 * kk, if (dim) th.line else th.muted, .regular, name);
            }
        }
        if (self.notice.len > 0) {
            const nw = text.widthStyled(13 * kk, .bold, self.notice) + s(28, kk);
            const nh = s(30, kk);
            const nr: Rect = .{ .x = @divTrunc(@as(i32, @intCast(pw)) - nw, 2), .y = @as(i32, @intCast(ph)) - nh - s(actions_h + 12, kk), .w = nw, .h = nh };
            cv.fillRoundRectAA(nr.x, nr.y, nr.w, nr.h, 15 * kk, 0xE6000000);
            fui.textCentered(&cv, nr, 13 * kk, fui.white, .bold, self.notice);
        }

        const o: i32 = @intFromFloat(@round(pad * kk));
        fui.placeCard(px, bw, bh, panel, pw, ph, o, o, @intFromFloat(14 * kk), @intFromFloat(14 * kk));
        fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
        try self.win.present();
    }
};

/// blitRounded onto an opaque buffer, clipped (rows may fall outside).
fn blitRoundedClipped(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, radius: u32) void {
    effects.blitRounded(dst, dw, dh, src, sw, sh, x, y, radius);
}

fn coverScaled(gpa: std.mem.Allocator, t: png.Image, w: u32, h: u32) !keep.Pixels {
    const fw = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(t.width));
    const fh = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(t.height));
    const ratio = fw / fh;
    const s = if (ratio > 0.7 and ratio < 1.4) @max(fw, fh) else @min(fw, fh);
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.width)) * s))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.height)) * s))));
    const out = try gpa.alloc(u32, @as(usize, dw) * dh);
    keep.scaleInto(t.pixels, t.width, t.height, out, dw, dh);
    return .{ .pixels = out, .width = dw, .height = dh };
}

pub fn run(gpa: std.mem.Allocator, env: Env, smoke_ms: i64) !void {
    text.init(gpa);
    defer text.deinit();
    var p: Panel = .{
        .gpa = gpa,
        .env = env,
        .cfg = config.load(gpa, env.home),
        .win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display),
    };
    defer p.deinit();
    p.root_len = (try history.historyRoot(&p.root_buf, env.home)).len;
    if (p.bus_()) |b| p.theme = fui.Theme.fromPrefs(@import("../ui/theme.zig").readPrefs(b, 1000));
    try p.load();
    p.searchable = ocr.available();
    std.log.info("history: text search {s}", .{if (p.searchable) "on (tesseract)" else "off (no libtesseract)"});
    const w: u32 = panel_w + 2 * pad;
    const h: u32 = @intCast(p.panelH() + 2 * pad);
    try p.win.open("Recent captures", .{ .fullscreen = false, .transparent = true, .width = w, .height = h });
    p.win.report_leave = true;
    p.win.setCursor(.arrow) catch {};
    try p.resize();
    p.startOcr();
    const end = if (smoke_ms > 0) sys.monoMs() + smoke_ms else 0;
    while (true) {
        if (end != 0 and sys.monoMs() > end) break;
        try p.render();
        const ev = (try p.win.nextEventTimeout(250)) orelse {
            p.pollOcr();
            if (p.notice_until != 0 and sys.monoMs() > p.notice_until) {
                p.notice = "";
                p.notice_until = 0;
                p.dirty = true;
            }
            continue;
        };
        if (!try p.onEvent(ev)) break;
        while (try p.win.nextEventTimeout(0)) |e2| if (!try p.onEvent(e2)) break;
        p.pollOcr();
    }
    p.win.closeWindow();
    if (p.win.hasClipboard()) try p.win.serveClipboard();
}
