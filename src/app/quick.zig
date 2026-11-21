//! Quick access: the floating thumbnails shown after Copy or Save
//! (`shotlet quick ROOT ID`). One process shows every thumbnail: a later
//! capture hands its entry to the running one over a unix socket in the
//! runtime directory, and the thumbnails stack in the bottom-left corner,
//! newest nearest the corner.
//!
//! Placement:
//! - with zwlr_layer_shell_v1 (KDE, wlroots): an overlay layer surface
//!   anchored bottom-left, exclusive zone 0, keyboard focus on demand
//!   only while the pointer is over it (some compositors focus on-demand
//!   surfaces as they map);
//! - on GNOME (no layer shell in mutter): a small transparent toplevel
//!   titled "shotlet:quick". The Shotlet GNOME Shell extension
//!   (gnome-extension/, `shotlet gnome-integration install`) places it
//!   bottom-left, keeps it above other windows on every workspace and
//!   gives keyboard focus back to the app the person was in. Without the
//!   extension it is an ordinary window wherever mutter puts it, with a
//!   one-line hint to enable the integration.
//!
//! In both cases only the cards take input: the shadow around them is
//! outside the input region, so clicks there reach the window below.

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const keep = @import("keep.zig");
const clock = @import("clock.zig");
const shot = @import("shot.zig");
const gnome = @import("gnome.zig");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const sys = @import("../platform/sys.zig");
const wl = @import("../platform/wayland.zig");
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const window = @import("../ui/window.zig");
const fui = @import("../ui/floatui.zig");
const Env = env_mod.Env;
const Window = window.Window;
const Canvas = fui.Canvas;
const Rect = @import("../ui/shapes.zig").Rect;

// layout, logical pixels
pub const card_w = 240;
pub const card_h = 150;
const gap = 12;
/// room for the shadow around the cards (outside the input region)
const pad = 28;
/// distance from the screen edges to the window (layer shell)
const edge = 8;
const hint_h = 52;
const max_cards = 5;
const fade_ms = 250;
const fade_in_ms = 150;

pub const Control = enum { body, close, annotate, pin, copy, save, menu, hint };

pub const menu_items = [_]struct { label: []const u8, action: Action }{
    .{ .label = "Copy", .action = .copy },
    .{ .label = "Save", .action = .save },
    .{ .label = "Save As...", .action = .save_as },
    .{ .label = "Annotate", .action = .annotate },
    .{ .label = "Pin to screen", .action = .pin },
    .{ .label = "Close", .action = .close },
};

pub const Action = enum { copy, save, save_as, annotate, pin, close };

const Card = struct {
    kept: keep.Kept,
    meta: history.Meta,
    editable: bool,
    thumb: png.Image,
    scaled: []u32 = &.{},
    scaled_w: u32 = 0,
    scaled_h: u32 = 0,
    born_ms: i64,
    deadline_ms: i64,
    /// fading out since (0: not fading)
    fade_from: i64 = 0,
    menu: bool = false,
    notice: []const u8 = "",
    notice_until: i64 = 0,

    fn deinit(self: *Card, gpa: std.mem.Allocator) void {
        self.meta.deinit(gpa);
        self.thumb.deinit(gpa);
        gpa.free(self.scaled);
    }
};

/// What is under a logical point.
pub const Hit = struct { card: usize = 0, control: Control, item: u8 = 0 };

/// Card i's rectangle (0 = newest, at the bottom) in a window of height h.
pub fn cardRect(i: usize, h: i32) Rect {
    const y = h - pad - card_h - @as(i32, @intCast(i)) * (card_h + gap);
    return .{ .x = pad, .y = y, .w = card_w, .h = card_h };
}

pub fn windowSize(n: usize, hint: bool) [2]u32 {
    const k: u32 = @intCast(@max(n, 1));
    return .{ card_w + 2 * pad, 2 * pad + k * card_h + (k - 1) * gap + if (hint) @as(u32, hint_h) else 0 };
}

/// Controls inside a card, relative to its top-left.
pub fn controlRect(c: Control) Rect {
    const pw = (card_w - 16 - 6) / 2;
    return switch (c) {
        .close => .{ .x = 8, .y = 8, .w = 26, .h = 26 },
        .annotate => .{ .x = card_w - 8 - 26 - 6 - 26, .y = 8, .w = 26, .h = 26 },
        .pin => .{ .x = card_w - 8 - 26, .y = 8, .w = 26, .h = 26 },
        .copy => .{ .x = 8, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .save => .{ .x = 8 + pw + 6, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        else => .{ .x = 0, .y = 0, .w = card_w, .h = card_h },
    };
}

const menu_row = 22;

fn menuTop() i32 {
    return @divTrunc(card_h - @as(i32, menu_items.len) * menu_row, 2);
}

/// Hit test at logical x, y with n cards (menu: whether each card shows
/// its menu).
pub fn hitTest(x: i32, y: i32, h: i32, n: usize, menus: []const bool, hint: bool) ?Hit {
    for (0..n) |i| {
        const r = cardRect(i, h);
        if (!r.contains(x, y)) continue;
        const lx = x - r.x;
        const ly = y - r.y;
        if (i < menus.len and menus[i]) {
            const row = @divFloor(ly - menuTop(), menu_row);
            if (row >= 0 and row < menu_items.len) return .{ .card = i, .control = .menu, .item = @intCast(row) };
            return .{ .card = i, .control = .body };
        }
        for ([_]Control{ .close, .annotate, .pin, .copy, .save }) |c| {
            if (controlRect(c).contains(lx, ly)) return .{ .card = i, .control = c };
        }
        return .{ .card = i, .control = .body };
    }
    if (hint) {
        const r: Rect = .{ .x = pad, .y = pad, .w = card_w, .h = hint_h - gap };
        if (r.contains(x, y)) return .{ .control = .hint };
    }
    return null;
}

test "layout: newest card in the corner, controls where the mockup has them" {
    const t = std.testing;
    const sz = windowSize(2, false);
    try t.expectEqual([2]u32{ 240 + 2 * pad, 2 * pad + 2 * 150 + 12 }, sz);
    const h: i32 = @intCast(sz[1]);
    try t.expectEqual(@as(i32, h - pad - 150), cardRect(0, h).y);
    try t.expect(cardRect(1, h).y < cardRect(0, h).y);
    const none = [_]bool{ false, false };
    // close top-left, pin top-right, copy and save at the bottom
    const r0 = cardRect(0, h);
    try t.expectEqual(Control.close, hitTest(r0.x + 12, r0.y + 12, h, 2, &none, false).?.control);
    try t.expectEqual(Control.pin, hitTest(r0.x + card_w - 14, r0.y + 14, h, 2, &none, false).?.control);
    try t.expectEqual(Control.copy, hitTest(r0.x + 20, r0.y + card_h - 20, h, 2, &none, false).?.control);
    try t.expectEqual(Control.save, hitTest(r0.x + card_w - 20, r0.y + card_h - 20, h, 2, &none, false).?.control);
    try t.expectEqual(Control.body, hitTest(r0.x + 120, r0.y + 70, h, 2, &none, false).?.control);
    try t.expectEqual(@as(usize, 1), hitTest(r0.x + 120, cardRect(1, h).y + 70, h, 2, &none, false).?.card);
    // the shadow margin is not a card
    try t.expect(hitTest(4, h - 4, h, 2, &none, false) == null);
    // a card's menu takes its clicks
    const menus = [_]bool{ true, false };
    const m = hitTest(r0.x + 50, r0.y + menuTop() + menu_row * 2 + 5, h, 2, &menus, false).?;
    try t.expectEqual(Control.menu, m.control);
    try t.expectEqual(Action.save_as, menu_items[m.item].action);
}

// --- single instance ---

fn socketPath(buf: []u8, env: Env) ![]u8 {
    const d = env.wayland_display;
    const base = if (std.mem.lastIndexOfScalar(u8, d, '/')) |i| d[i + 1 ..] else d;
    return std.fmt.bufPrint(buf, "{s}/shotlet-quick-{s}.sock", .{ env.runtime_dir, base });
}

/// Hand an entry to a running quick-access process; false when none
/// answered.
fn handOff(env: Env, root: []const u8, id: []const u8) bool {
    var pbuf: [512]u8 = undefined;
    const path = socketPath(&pbuf, env) catch return false;
    const fd = sys.socketUnixStream() catch return false;
    defer sys.close(fd);
    sys.connectUnix(fd, path) catch return false;
    var lbuf: [1200]u8 = undefined;
    const line = std.fmt.bufPrint(&lbuf, "add {s}\t{s}\n", .{ root, id }) catch return false;
    sys.writeAll(fd, line) catch return false;
    var ans: [8]u8 = undefined;
    if (!(sys.waitReadable(fd, sys.monoMs() + 2000) catch false)) return false;
    const n = sys.read(fd, &ans) catch return false;
    return n >= 2 and std.mem.eql(u8, ans[0..2], "ok");
}

/// Parse "add ROOT\tID\n".
pub fn parseAdd(line: []const u8) ?struct { root: []const u8, id: []const u8 } {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, l, "add ")) return null;
    const rest = l[4..];
    const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const root = rest[0..tab];
    const id = rest[tab + 1 ..];
    if (root.len == 0 or root[0] != '/' or !history.Id.valid(id)) return null;
    return .{ .root = root, .id = id };
}

test "hand-off lines are checked" {
    const a = parseAdd("add /home/u/.local/state/shotlet/history\t1763740953123-0a1b2c3d\n").?;
    try std.testing.expectEqualStrings("/home/u/.local/state/shotlet/history", a.root);
    try std.testing.expectEqualStrings("1763740953123-0a1b2c3d", a.id);
    try std.testing.expect(parseAdd("add relative\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r\t../../x") == null);
    try std.testing.expect(parseAdd("del /r\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r 1763740953123-0a1b2c3d") == null);
}

// --- the process ---

const Quick = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: config.Config,
    win: Window,
    bus: ?dbus.Connection = null,
    cards: std.ArrayList(Card) = .empty,
    listen_fd: sys.fd_t = -1,
    sock_path_buf: [512]u8 = undefined,
    sock_path_len: usize = 0,
    layer: bool = false,
    /// GNOME without the extension: say how to keep it above
    hint: bool = false,
    hint_text: []const u8 = "Keep it above other windows:",
    hint_link: []const u8 = "Enable GNOME integration",
    opened: bool = false,
    size: [2]u32 = .{ 0, 0 },
    hover: ?Hit = null,
    pressed: ?Hit = null,
    press_x: f64 = 0,
    press_y: f64 = 0,
    /// keyboard focus: card index and control
    focus: ?Hit = null,
    dirty: bool = true,
    dragging: ?usize = null,
    /// the desktop's accent, for keyboard focus rings
    accent: u32 = fui.accent,

    fn f(self: *const Quick) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    fn bus_(self: *Quick) ?*dbus.Connection {
        if (self.bus == null) self.bus = portal.connectApp(self.gpa, self.env.bus_addr) catch return null;
        return &self.bus.?;
    }

    fn deinit(self: *Quick) void {
        for (self.cards.items) |*c| c.deinit(self.gpa);
        self.cards.deinit(self.gpa);
        self.stopListening();
        self.win.deinit();
        if (self.bus) |*b| b.deinit();
    }

    fn listen(self: *Quick) bool {
        const path = socketPath(&self.sock_path_buf, self.env) catch return false;
        self.sock_path_len = path.len;
        self.listen_fd = sys.listenUnix(path) catch |err| switch (err) {
            error.AddressInUse => blk: {
                // nobody answered the hand-off: a stale socket file
                sys.unlink(path) catch {};
                break :blk sys.listenUnix(path) catch return false;
            },
            else => return false,
        };
        return true;
    }

    fn stopListening(self: *Quick) void {
        if (self.listen_fd < 0) return;
        sys.close(self.listen_fd);
        self.listen_fd = -1;
        sys.unlink(self.sock_path_buf[0..self.sock_path_len]) catch {};
    }

    fn acceptClients(self: *Quick) void {
        while (sys.accept(self.listen_fd) catch null) |fd| {
            defer sys.close(fd);
            var buf: [1300]u8 = undefined;
            var n: usize = 0;
            const deadline = sys.monoMs() + 500;
            while (n < buf.len) {
                if (!(sys.waitReadable(fd, deadline) catch false)) break;
                const k = sys.read(fd, buf[n..]) catch break;
                if (k == 0) break;
                n += k;
                if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
            }
            const a = parseAdd(buf[0..n]) orelse continue;
            self.add(a.root, a.id) catch |err| {
                std.log.warn("quick access: cannot show {s}: {t}", .{ a.id, err });
                continue;
            };
            std.log.info("quick access: added {s}", .{a.id});
            sys.writeAll(fd, "ok\n") catch {};
        }
    }

    fn add(self: *Quick, root: []const u8, id: []const u8) !void {
        var kept: keep.Kept = .{ .id = history.Id.fromSlice(id) orelse return error.BadId };
        if (root.len > kept.root_buf.len) return error.PathTooLong;
        @memcpy(kept.root_buf[0..root.len], root);
        kept.root_len = root.len;
        var meta = try history.readMeta(self.gpa, root, id);
        errdefer meta.deinit(self.gpa);
        var pbuf: [1200]u8 = undefined;
        const thumb_data = try sys.readFileAlloc(self.gpa, try history.entryPath(&pbuf, root, id, "thumb.png"), 16 * 1024 * 1024);
        defer self.gpa.free(thumb_data);
        var thumb = try png.decode(self.gpa, thumb_data);
        errdefer thumb.deinit(self.gpa);
        const editable = (sys.fileSize(try history.entryPath(&pbuf, root, id, "doc")) catch null) != null;
        // the same capture again (edited): replace it
        for (self.cards.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.kept.id.slice(), id)) {
                var old = self.cards.orderedRemove(i);
                old.deinit(self.gpa);
                break;
            }
        }
        const now = sys.monoMs();
        try self.cards.insert(self.gpa, 0, .{
            .kept = kept,
            .meta = meta,
            .editable = editable,
            .thumb = thumb,
            .born_ms = now,
            .deadline_ms = now + @as(i64, self.cfg.quick_access_seconds) * 1000,
        });
        while (self.cards.items.len > max_cards) {
            var c = self.cards.pop().?;
            c.deinit(self.gpa);
        }
        self.focus = null;
        self.dirty = true;
        try self.fitWindow();
    }

    fn remove(self: *Quick, i: usize) void {
        var c = self.cards.orderedRemove(i);
        c.deinit(self.gpa);
        self.hover = null;
        self.pressed = null;
        if (self.focus) |fo| {
            if (fo.card >= self.cards.items.len) self.focus = null;
        }
        self.dirty = true;
        if (self.cards.items.len > 0) self.fitWindow() catch {};
    }

    fn fitWindow(self: *Quick) !void {
        const sz = windowSize(self.cards.items.len, self.hint);
        if (!self.opened) {
            if (self.win.hasLayerShell()) {
                self.layer = true;
                // keyboard only while the pointer is over it (see the
                // .pointer_motion event): typing stays in the person's app
                try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1], .layer = .{
                    .layer = wl.zwlr_layer_shell_v1.layer_overlay,
                    .anchor = wl.zwlr_layer_surface_v1.anchor_bottom | wl.zwlr_layer_surface_v1.anchor_left,
                    .width = sz[0],
                    .height = sz[1],
                    .margin = .{ 0, 0, edge, edge },
                    .keyboard = wl.zwlr_layer_surface_v1.keyboard_none,
                } });
            } else {
                try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1] });
            }
            self.win.report_leave = true;
            self.win.setCursor(.arrow) catch {};
            self.opened = true;
        } else if (sz[0] != self.size[0] or sz[1] != self.size[1]) {
            if (self.layer) {
                try self.win.setLayerPlacement(0, sz[0], sz[1], .{ 0, 0, edge, edge });
            } else {
                try self.win.resizeTo(0, sz[0], sz[1]);
            }
        }
        self.size = sz;
        try self.updateInputRegion();
    }

    fn updateInputRegion(self: *Quick) !void {
        var rects: [max_cards + 1]window.Rect = undefined;
        const h: i32 = @intCast(self.size[1]);
        const n = self.cards.items.len;
        for (0..n) |i| {
            const r = cardRect(i, h);
            rects[i] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        }
        var k = n;
        if (self.hint) {
            rects[k] = .{ .x = pad, .y = pad, .w = card_w, .h = hint_h - gap };
            k += 1;
        }
        try self.win.setInputRegion(0, rects[0..k]);
    }

    fn menus(self: *const Quick, buf: []bool) []bool {
        const n = @min(buf.len, self.cards.items.len);
        for (self.cards.items[0..n], 0..) |c, i| buf[i] = c.menu;
        return buf[0..n];
    }

    fn hitAt(self: *const Quick, bx: f64, by: f64) ?Hit {
        if (bx < 0 or by < 0) return null;
        const k = self.f();
        var mb: [max_cards]bool = undefined;
        return hitTest(@intFromFloat(bx / k), @intFromFloat(by / k), @intCast(self.size[1]), self.cards.items.len, self.menus(&mb), self.hint);
    }

    /// The card actions and shortcuts apply to: focused, hovered, newest.
    fn current(self: *const Quick) ?usize {
        if (self.cards.items.len == 0) return null;
        if (self.focus) |fo| return fo.card;
        if (self.hover) |h| if (h.control != .hint) return h.card;
        return 0;
    }

    // --- actions ---

    fn act(self: *Quick, i: usize, a: Action) void {
        if (i >= self.cards.items.len) return;
        self.actInner(i, a) catch |err| {
            std.log.warn("quick access: {t} failed: {t}", .{ a, err });
            self.notice(i, "Failed");
        };
    }

    fn notice(self: *Quick, i: usize, s: []const u8) void {
        const c = &self.cards.items[i];
        c.notice = s;
        c.notice_until = sys.monoMs() + 1200;
        c.deadline_ms = @max(c.deadline_ms, c.notice_until + 1500);
        self.dirty = true;
    }

    fn imagePath(self: *Quick, i: usize, buf: []u8) ![]u8 {
        const c = &self.cards.items[i];
        return history.entryPath(buf, c.kept.root(), c.kept.id.slice(), "image.png");
    }

    fn actInner(self: *Quick, i: usize, a: Action) !void {
        const c = &self.cards.items[i];
        c.menu = false;
        self.dirty = true;
        var pbuf: [1200]u8 = undefined;
        switch (a) {
            .copy => {
                const data = try sys.readFileAlloc(self.gpa, try self.imagePath(i, &pbuf), 512 * 1024 * 1024);
                self.win.setClipboardPng(data) catch |err| {
                    self.gpa.free(data);
                    return err;
                };
                std.log.info("quick access: copied {s}", .{c.kept.id.slice()});
                self.notice(i, "Copied");
            },
            .save, .save_as => {
                const data = try sys.readFileAlloc(self.gpa, try self.imagePath(i, &pbuf), 512 * 1024 * 1024);
                defer self.gpa.free(data);
                const saved: ?[]u8 = if (a == .save)
                    try shot.savePng(self.gpa, self.env, &self.cfg, data)
                else blk: {
                    const b = self.bus_() orelse return error.NoBus;
                    break :blk try shot.saveAs(self.gpa, self.env, b, &self.cfg, data);
                };
                const path = saved orelse return; // chooser cancelled
                defer self.gpa.free(path);
                const card = &self.cards.items[i];
                self.gpa.free(card.meta.saved);
                card.meta.saved = &.{};
                card.meta.saved = try self.gpa.dupe(u8, path);
                history.writeMeta(self.gpa, card.kept.root(), card.kept.id.slice(), &card.meta) catch {};
                std.log.info("quick access: saved to {s}", .{path});
                self.notice(i, "Saved");
            },
            .annotate => {
                if (!c.editable) return;
                const root = try self.gpa.dupeSentinel(u8, c.kept.root(), 0);
                defer self.gpa.free(root);
                const id = try self.gpa.dupeSentinel(u8, c.kept.id.slice(), 0);
                defer self.gpa.free(id);
                keep.spawnSelf(self.env, &.{ "edit", root.ptr, id.ptr });
                self.remove(i);
            },
            .pin => {
                const p = try self.gpa.dupeSentinel(u8, try self.imagePath(i, &pbuf), 0);
                defer self.gpa.free(p);
                keep.spawnSelf(self.env, &.{ "pin", p.ptr });
                self.remove(i);
            },
            .close => {
                std.log.info("quick access: closed {s}", .{c.kept.id.slice()});
                if (c.fade_from == 0) c.fade_from = sys.monoMs() - fade_ms / 2;
            },
        }
    }

    fn controlAction(c: Control) ?Action {
        return switch (c) {
            .close => .close,
            .annotate => .annotate,
            .pin => .pin,
            .copy => .copy,
            .save => .save,
            else => null,
        };
    }

    fn activate(self: *Quick, h: Hit) void {
        switch (h.control) {
            .menu => self.act(h.card, menu_items[h.item].action),
            .hint => {
                const res = gnome.install(self.gpa, self.env, self.bus_(), .yes);
                self.hint_text = switch (res) {
                    .active => "GNOME integration is on.",
                    .installed_relogin => "Installed. Log out and in once",
                    .failed => "Could not install; see the log",
                };
                self.hint_link = switch (res) {
                    .active => "Next thumbnails stay above",
                    .installed_relogin => "to finish (GNOME needs it).",
                    .failed => "shotlet gnome-integration",
                };
                self.dirty = true;
            },
            else => if (controlAction(h.control)) |a| self.act(h.card, a),
        }
    }

    // --- drag out ---

    fn startDrag(self: *Quick, i: usize) !void {
        const c = &self.cards.items[i];
        var pbuf: [1200]u8 = undefined;
        const data = try sys.readFileAlloc(self.gpa, try self.imagePath(i, &pbuf), 512 * 1024 * 1024);
        errdefer self.gpa.free(data);
        // a file for apps that take paths: the saved one, else a copy
        // with a readable name in the cache
        var file_buf: [1200]u8 = undefined;
        const file: []const u8 = if (c.meta.saved.len > 0 and (sys.fileSize(c.meta.saved) catch null) != null) c.meta.saved else blk: {
            var dir_buf: [1024]u8 = undefined;
            const cache = try env_mod.cacheDir(&dir_buf, self.env.home);
            var drag_dir_buf: [1100]u8 = undefined;
            const drag_dir = try std.fmt.bufPrint(&drag_dir_buf, "{s}/drag", .{cache});
            sys.mkdirAll(drag_dir, 0o700);
            const lt = clock.localTime(self.gpa, self.env.tz, @divFloor(c.meta.time_ms, 1000));
            const p = try std.fmt.bufPrint(&file_buf, "{s}/shotlet-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.png", .{ drag_dir, lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second });
            try sys.writeFile(p, data);
            break :blk p;
        };
        const uri = try window.fileUriList(self.gpa, file);
        errdefer self.gpa.free(uri);
        // the icon: the card's picture, smaller, rounded and a bit see-through
        const k: i32 = @max(1, @as(i32, @intCast((self.win.scale120 + 119) / 120)));
        const iw: u32 = @intCast(160 * k);
        const ih: u32 = @intCast(100 * k);
        const icon_px = try self.gpa.alloc(u32, @as(usize, iw) * ih);
        defer self.gpa.free(icon_px);
        @memset(icon_px, 0);
        const pic = try self.gpa.alloc(u32, @as(usize, iw) * ih);
        defer self.gpa.free(pic);
        const cov = coverScaled(self.gpa, c.thumb, iw, ih) catch null;
        defer if (cov) |p| self.gpa.free(p.pixels);
        if (cov) |p| fui.drawImageFill(pic, iw, ih, p.pixels, p.width, p.height) else @memset(pic, fui.card_bg);
        effects.blitRounded(icon_px, iw, ih, pic, iw, ih, 0, 0, @intCast(10 * k));
        fui.fadeAlpha(icon_px, 0.92);
        fui.premultiply(icon_px, iw, ih, .{ .x = 0, .y = 0, .w = @intCast(iw), .h = @intCast(ih) });
        try self.win.startDrag(0, data, uri, .{ .pixels = icon_px, .width = iw, .height = ih, .scale = k });
        self.dragging = i;
        std.log.info("quick access: dragging {s} (file {s})", .{ c.kept.id.slice(), file });
    }

    fn checkDrag(self: *Quick) void {
        const i = self.dragging orelse return;
        switch (self.win.drag_state) {
            .finished => {
                std.log.info("quick access: dropped", .{});
                self.win.endDrag();
                self.dragging = null;
                if (i < self.cards.items.len) self.remove(i);
            },
            .cancelled => {
                std.log.info("quick access: drag cancelled", .{});
                self.win.endDrag();
                self.dragging = null;
                self.dirty = true;
            },
            else => {},
        }
    }

    // --- input ---

    fn onEvent(self: *Quick, ev: window.InputEvent) void {
        switch (ev) {
            .resize, .frame_done => self.dirty = true,
            .close => {
                for (self.cards.items) |*c| if (c.fade_from == 0) {
                    c.fade_from = sys.monoMs();
                };
            },
            .pointer_motion => |m| {
                if (self.layer) self.win.setLayerKeyboard(0, self.win.pointer_in) catch {};
                const h = self.hitAt(m.x, m.y);
                if (!std.meta.eql(h, self.hover)) self.dirty = true;
                self.hover = h;
                if (self.pressed) |p| if (p.control == .body and self.dragging == null) {
                    const k = self.f();
                    const dx = (m.x - self.press_x) / k;
                    const dy = (m.y - self.press_y) / k;
                    if (dx * dx + dy * dy > 36) {
                        self.pressed = null;
                        self.startDrag(p.card) catch |err| std.log.warn("quick access: drag failed: {t}", .{err});
                    }
                };
            },
            .pointer_button => |b| {
                const h = self.hitAt(b.x, b.y);
                self.hover = h;
                self.dirty = true;
                if (b.button == window.BTN_RIGHT and b.pressed) {
                    if (h) |hh| if (hh.control != .hint) {
                        const c = &self.cards.items[hh.card];
                        c.menu = !c.menu;
                    };
                } else if (b.button == window.BTN_LEFT) {
                    if (b.pressed) {
                        self.pressed = h;
                        self.press_x = b.x;
                        self.press_y = b.y;
                        self.focus = null;
                    } else {
                        const p = self.pressed;
                        self.pressed = null;
                        if (p != null and h != null and std.meta.eql(p.?, h.?)) self.activate(h.?);
                    }
                }
            },
            .pointer_axis => {},
            .key => |k| if (k.pressed) {
                // a layer surface has the keyboard only while the pointer
                // is over it, but KWin keeps it focused after that: keys
                // then belong to whatever the person went back to typing
                // in, not to the thumbnail's shortcuts
                if (self.layer and !self.win.pointer_in) {
                    std.log.debug("quick access: key ignored, the pointer is elsewhere", .{});
                } else self.onKey(k);
            },
        }
    }

    const focus_order = [_]Control{ .copy, .save, .annotate, .pin, .close };

    fn onKey(self: *Quick, k: window.Key) void {
        self.dirty = true;
        const cur = self.current() orelse return;
        const card = &self.cards.items[cur];
        switch (k.code) {
            window.KEY_ESC => {
                if (card.menu) card.menu = false else self.act(cur, .close);
            },
            window.KEY_TAB, window.KEY_RIGHT, window.KEY_LEFT => {
                const back = k.shift or k.code == window.KEY_LEFT;
                const n = self.cards.items.len * focus_order.len;
                var idx: usize = 0;
                if (self.focus) |fo| {
                    const pos = std.mem.indexOfScalar(Control, &focus_order, fo.control) orelse 0;
                    idx = fo.card * focus_order.len + pos;
                    idx = if (back) (idx + n - 1) % n else (idx + 1) % n;
                }
                self.focus = .{ .card = idx / focus_order.len, .control = focus_order[idx % focus_order.len] };
            },
            window.KEY_UP, window.KEY_DOWN => {
                const n = self.cards.items.len;
                const c: usize = if (k.code == window.KEY_UP) (cur + 1) % n else (cur + n - 1) % n;
                self.focus = .{ .card = c, .control = if (self.focus) |fo| fo.control else .copy };
            },
            window.KEY_ENTER, window.KEY_KPENTER, window.KEY_SPACE => {
                if (self.focus) |fo| self.activate(fo) else self.act(cur, .copy);
            },
            window.KEY_DELETE => self.act(cur, .close),
            46 => if (k.ctrl) self.act(cur, .copy), // C
            31 => if (k.ctrl) self.act(cur, if (k.shift) .save_as else .save), // S
            18, 30 => if (!k.ctrl) self.act(cur, .annotate), // E, A
            25 => if (!k.ctrl) self.act(cur, .pin), // P
            else => {},
        }
    }

    // --- time ---

    fn tick(self: *Quick) void {
        const now = sys.monoMs();
        const keep_alive = self.win.pointer_in or self.dragging != null;
        var i: usize = 0;
        while (i < self.cards.items.len) {
            const c = &self.cards.items[i];
            if (c.menu or (keep_alive and c.fade_from == 0)) c.deadline_ms = @max(c.deadline_ms, now + 2000);
            if (c.fade_from == 0 and now >= c.deadline_ms) c.fade_from = now;
            if (c.notice_until != 0 and now >= c.notice_until) {
                c.notice_until = 0;
                c.notice = "";
                self.dirty = true;
            }
            if (c.fade_from != 0 or now - c.born_ms < fade_in_ms) self.dirty = true;
            if (c.fade_from != 0 and now - c.fade_from >= fade_ms) {
                self.remove(i);
                continue;
            }
            i += 1;
        }
    }

    fn nextWakeMs(self: *const Quick) i32 {
        var wait: i64 = 1000;
        const now = sys.monoMs();
        for (self.cards.items) |c| {
            if (c.fade_from != 0 or now - c.born_ms < fade_in_ms) return 16;
            wait = @min(wait, c.deadline_ms - now);
            if (c.notice_until != 0) wait = @min(wait, c.notice_until - now);
        }
        return @intCast(std.math.clamp(wait, 5, 1000));
    }

    // --- drawing ---

    fn render(self: *Quick) !void {
        if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
        self.dirty = false;
        const px = try self.win.backBuffer();
        const bw = self.win.width;
        const bh = self.win.height;
        @memset(px, 0);
        const k = self.f();
        const now = sys.monoMs();
        const lh: i32 = @intCast(self.size[1]);
        var i = self.cards.items.len;
        while (i > 0) {
            i -= 1;
            const r = cardRect(i, lh);
            try self.drawCard(px, bw, bh, i, .{
                .x = sc(r.x, k),
                .y = sc(r.y, k),
                .w = sc(card_w, k),
                .h = sc(card_h, k),
            }, now);
        }
        if (self.hint) self.drawHint(px, bw, bh);
        fui.premultiply(px, bw, bh, .{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) });
        try self.win.present();
    }

    fn drawHint(self: *Quick, px: []u32, bw: u32, bh: u32) void {
        const k = self.f();
        const r: Rect = .{ .x = sc(pad, k), .y = sc(pad, k), .w = sc(card_w, k), .h = sc(hint_h - gap, k) };
        var tmp: [1]u32 = undefined;
        _ = &tmp;
        // an opaque pill drawn through a card buffer
        const w: u32 = @intCast(r.w);
        const h: u32 = @intCast(r.h);
        const buf = self.gpa.alloc(u32, @as(usize, w) * h) catch return;
        defer self.gpa.free(buf);
        @memset(buf, 0xF0202024);
        var cv = Canvas.init(buf, w, h);
        const hovered = if (self.hover) |hv| hv.control == .hint else false;
        text.draw(&cv, sc(10, k), sc(5, k), 12 * k, 0xFFD0D0D6, self.hint_text);
        text.drawStyled(&cv, sc(10, k), sc(21, k), 12 * k, if (hovered) 0xFF64B0FF else 0xFF409CFF, .bold, self.hint_link);
        fui.placeCard(px, bw, bh, buf, w, h, r.x, r.y, @intCast(sc(10, k)), @intCast(sc(8, k)));
    }

    fn drawCard(self: *Quick, px: []u32, bw: u32, bh: u32, i: usize, r: Rect, now: i64) !void {
        const c = &self.cards.items[i];
        const k = self.f();
        const cw: u32 = @intCast(r.w);
        const ch: u32 = @intCast(r.h);
        if (c.scaled_w != cw or c.scaled_h != ch) {
            self.gpa.free(c.scaled);
            c.scaled = &.{};
            c.scaled = try self.gpa.alloc(u32, @as(usize, cw) * ch);
            c.scaled_w = cw;
            c.scaled_h = ch;
            const cov = try coverScaled(self.gpa, c.thumb, cw, ch);
            defer self.gpa.free(cov.pixels);
            fui.drawImageFill(c.scaled, cw, ch, cov.pixels, cov.width, cov.height);
        }
        const card = try self.gpa.alloc(u32, @as(usize, cw) * ch);
        defer self.gpa.free(card);
        @memcpy(card, c.scaled);
        var cv = Canvas.init(card, cw, ch);
        const hovered = if (self.hover) |h| h.card == i and h.control != .hint else false;
        const focused = if (self.focus) |fo| fo.card == i else false;
        const dragged = self.dragging == i;
        if (c.menu) {
            cv.fillRect(0, 0, r.w, r.h, 0xB8000000);
            const top = sc(menuTop(), k);
            for (menu_items, 0..) |item, j| {
                const row: Rect = .{ .x = sc(8, k), .y = top + sc(@as(i32, @intCast(j)) * menu_row, k), .w = sc(card_w - 16, k), .h = sc(menu_row, k) };
                const on = if (self.hover) |h| h.card == i and h.control == .menu and h.item == j else false;
                if (on) cv.fillRoundRectAA(row.x, row.y, row.w, row.h, 5 * k, 0x40FFFFFF);
                const dim = item.action == .annotate and !c.editable;
                text.draw(&cv, row.x + sc(10, k), row.y + @divTrunc(row.h - text.height(12.5 * k), 2), 12.5 * k, if (dim) 0x80FFFFFF else fui.white, item.label);
            }
        } else if ((hovered or focused) and !dragged) {
            cv.fillRect(0, 0, r.w, r.h, fui.veil);
            const fo: ?Control = if (focused) self.focus.?.control else null;
            const hv: ?Control = if (hovered) self.hover.?.control else null;
            for ([_]Control{ .close, .annotate, .pin }) |ctl| {
                const cr = controlRect(ctl);
                const cx = (@as(f64, @floatFromInt(cr.x)) + 13) * k;
                const cy = (@as(f64, @floatFromInt(cr.y)) + 13) * k;
                const dim = ctl == .annotate and !c.editable;
                cv.fillCircleAA(cx, cy, 13 * k, if (hv == ctl and !dim) fui.btn_round_hover else fui.btn_round);
                const ic: fui.Icon = switch (ctl) {
                    .close => .close,
                    .annotate => .pencil,
                    else => .pin,
                };
                fui.icon(&cv, ic, cx, cy, 14 * k, if (dim) 0x80FFFFFF else fui.white);
                if (fo == ctl) cv.ringAA(cx, cy, 15 * k, 2 * k, self.accent);
            }
            for ([_]Control{ .copy, .save }) |ctl| {
                const cr = controlRect(ctl);
                const rr: Rect = .{ .x = sc(cr.x, k), .y = sc(cr.y, k), .w = sc(cr.w, k), .h = sc(cr.h, k) };
                cv.fillRoundRectAA(rr.x, rr.y, rr.w, rr.h, 8 * k, if (hv == ctl) fui.pill_hover else fui.pill);
                fui.textCentered(&cv, rr, 13 * k, fui.pill_text, .bold, if (ctl == .copy) "Copy" else "Save");
                if (fo == ctl) @import("../ui/shapes.zig").roundRectRing(&cv, .{ .x = rr.x - sc(2, k), .y = rr.y - sc(2, k), .w = rr.w + sc(4, k), .h = rr.h + sc(4, k) }, 10 * k, 2 * k, self.accent);
            }
        }
        if (c.notice.len > 0) {
            const tw = text.widthStyled(13 * k, .bold, c.notice) + sc(28, k);
            const nh = sc(30, k);
            const nr: Rect = .{ .x = @divTrunc(r.w - tw, 2), .y = @divTrunc(r.h - nh, 2), .w = tw, .h = nh };
            cv.fillRoundRectAA(nr.x, nr.y, nr.w, nr.h, 15 * k, 0xE6000000);
            fui.textCentered(&cv, nr, 13 * k, fui.white, .bold, c.notice);
        }
        // shadow and card into a scratch layer so it can fade as a whole
        const sp: i32 = sc(pad, k);
        const tw: u32 = cw + @as(u32, @intCast(2 * sp));
        const th: u32 = ch + @as(u32, @intCast(2 * sp));
        const layer = try self.gpa.alloc(u32, @as(usize, tw) * th);
        defer self.gpa.free(layer);
        @memset(layer, 0);
        fui.placeCard(layer, tw, th, card, cw, ch, sp, sp, @intCast(sc(12, k)), @intCast(sc(20, k)));
        var alpha: f64 = 1;
        if (now - c.born_ms < fade_in_ms) alpha = @as(f64, @floatFromInt(now - c.born_ms)) / fade_in_ms;
        if (c.fade_from != 0) alpha = @min(alpha, 1 - @as(f64, @floatFromInt(now - c.fade_from)) / fade_ms);
        if (dragged) alpha = @min(alpha, 0.5);
        fui.fadeAlpha(layer, @max(0, alpha));
        fui.blitOver(px, bw, bh, layer, tw, th, r.x - sp, r.y - sp);
    }
};

fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

/// The thumbnail box-filtered to the size it is drawn at in a w x h box
/// (cover, or contain for very different shapes: see drawImageFill).
fn coverScaled(gpa: std.mem.Allocator, t: png.Image, w: u32, h: u32) !keep.Pixels {
    const ar_src = @as(f64, @floatFromInt(t.width)) / @as(f64, @floatFromInt(t.height));
    const ar_dst = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const ratio = ar_src / ar_dst;
    const cover = ratio > 0.7 and ratio < 1.4;
    const fw = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(t.width));
    const fh = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(t.height));
    const s = if (cover) @max(fw, fh) else @min(fw, fh);
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.width)) * s))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(t.height)) * s))));
    const out = try gpa.alloc(u32, @as(usize, dw) * dh);
    keep.scaleInto(t.pixels, t.width, t.height, out, dw, dh);
    return .{ .pixels = out, .width = dw, .height = dh };
}

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    // another thumbnail stack is up: join it
    if (handOff(env, root, id)) return;

    text.init(gpa);
    defer text.deinit();
    var q: Quick = .{
        .gpa = gpa,
        .env = env,
        .cfg = config.load(gpa, env.home),
        .win = try Window.init(gpa, env.runtime_dir, env.wayland_display),
    };
    defer q.deinit();
    if (!q.listen()) {
        // lost a race with another newcomer: it shows ours too
        if (handOff(env, root, id)) return;
    }
    if (!q.cfg.history) {
        var cb: [1024]u8 = undefined;
        if (history.cacheRoot(&cb, env.home)) |cache| {
            _ = history.prune(gpa, cache, 30, 512 * 1024 * 1024) catch 0;
        } else |_| {}
    }
    if (q.bus_()) |b| q.accent = @import("../ui/theme.zig").readPrefs(b, 500).theme().accent;
    if (!q.win.hasLayerShell() and gnome.isGnome()) {
        q.hint = if (q.bus_()) |b| !gnome.extensionActive(b) else true;
        if (q.hint) std.log.info("quick access: no Shotlet GNOME Shell extension; the thumbnail is an ordinary window", .{});
    }
    // an image dropped on a thumbnail opens in the editor
    q.win.accept_mimes = &@import("clipimg.zig").drop_mimes;
    try q.add(root, id);
    std.log.info("quick access: showing {s} ({s})", .{ id, if (q.layer) "layer shell" else if (q.hint) "plain window" else "window placed by the GNOME extension" });

    while (q.cards.items.len > 0) {
        try q.win.conn.flush();
        var fds = [_]sys.pollfd{
            .{ .fd = q.win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = q.listen_fd, .events = sys.POLL.IN, .revents = 0 },
        };
        const nfds: usize = if (q.listen_fd >= 0) 2 else 1;
        _ = try sys.poll(fds[0..nfds], q.win.pollTimeoutMs(q.nextWakeMs()));
        while (try q.win.nextEventTimeout(0)) |ev| q.onEvent(ev);
        if (nfds == 2 and fds[1].revents != 0) q.acceptClients();
        q.checkDrag();
        @import("clipimg.zig").takeDrop(gpa, env, &q.win);
        q.tick();
        if (q.cards.items.len == 0) break;
        try q.render();
    }
    // newcomers start their own stack from here on
    q.stopListening();
    q.win.closeWindow();
    if (q.win.hasClipboard()) {
        std.log.info("quick access: serving the clipboard", .{});
        try q.win.serveClipboard();
    }
}
