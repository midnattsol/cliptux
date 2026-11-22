//! The quick access process's state: the stack of thumbnail cards, the
//! window they live in (layer surface or plain toplevel), and the socket
//! later captures hand their entries over. Actions, input and drawing
//! live in sibling files and are reachable as methods.

const std = @import("std");
const config = @import("../config.zig");
const env_mod = @import("../env.zig");
const history = @import("../history.zig");
const keep = @import("../keep.zig");
const quick_ipc = @import("../quick_ipc.zig");
const dbus = @import("../../platform/linux/dbus.zig");
const portal = @import("../../platform/linux/portal.zig");
const sys = @import("../../platform/api.zig").sys;
const png = @import("../../gfx/png.zig");
const window = @import("../../platform/api.zig").window;
const fui = @import("../../ui/floatui.zig");
const motion = @import("../../ui/motion.zig");
const theme = @import("../../ui/theme.zig");
const layout = @import("layout.zig");
const actions = @import("actions.zig");
const input = @import("input.zig");
const card_draw = @import("card.zig");

const Env = env_mod.Env;
const Window = window.Window;
const Hit = layout.Hit;
const card_w = layout.card_w;
const pad = layout.pad;
const edge = layout.edge;
const max_cards = layout.max_cards;

pub const fade_ms = 250;
pub const fade_in_ms = 150;

pub const Card = struct {
    kept: keep.Kept,
    meta: history.Meta,
    editable: bool,
    thumb: png.Image,
    scaled: []u32 = &.{},
    scaled_w: u32 = 0,
    scaled_h: u32 = 0,
    /// when it was first drawn (0: not yet); it fades in from there
    born_ms: i64 = 0,
    deadline_ms: i64,
    /// fading out since (0: not fading)
    fade_from: i64 = 0,
    menu: bool = false,
    /// how far its hover controls show (0..1)
    hov: motion.Tween = .{ .dur_ms = theme.motion_fast },
    notice: []const u8 = "",
    notice_until: i64 = 0,

    fn deinit(self: *Card, gpa: std.mem.Allocator) void {
        self.meta.deinit(gpa);
        self.thumb.deinit(gpa);
        gpa.free(self.scaled);
    }
};

pub const Quick = struct {
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
    accent: u32 = theme.accentFill(theme.default_accent),
    /// told once the first frame is committed (see quick.run)
    ready_fd: sys.fd_t = -1,

    pub const act = actions.act;
    pub const notice = actions.notice;
    pub const imagePath = actions.imagePath;
    pub const activate = actions.activate;
    pub const startDrag = actions.startDrag;
    pub const checkDrag = actions.checkDrag;
    pub const onEvent = input.onEvent;
    pub const tick = input.tick;
    pub const nextWakeMs = input.nextWakeMs;
    pub const render = card_draw.render;

    /// Display scale.
    pub fn f(self: *const Quick) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    pub fn bus_(self: *Quick) ?*dbus.Connection {
        if (self.bus == null) self.bus = portal.connectApp(self.gpa, self.env.bus_addr) catch return null;
        return &self.bus.?;
    }

    /// The first frame is committed: let the editor go.
    pub fn signalReady(self: *Quick) void {
        if (self.ready_fd < 0) return;
        sys.writeAll(self.ready_fd, "1") catch {};
        sys.close(self.ready_fd);
        self.ready_fd = -1;
    }

    pub fn deinit(self: *Quick) void {
        self.signalReady();
        for (self.cards.items) |*c| c.deinit(self.gpa);
        self.cards.deinit(self.gpa);
        self.stopListening();
        self.win.deinit();
        if (self.bus) |*b| b.deinit();
    }

    // --- the hand-off socket ---

    pub fn listen(self: *Quick) bool {
        const path = quick_ipc.socketPath(&self.sock_path_buf, self.env) catch return false;
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

    pub fn stopListening(self: *Quick) void {
        if (self.listen_fd < 0) return;
        sys.close(self.listen_fd);
        self.listen_fd = -1;
        sys.unlink(self.sock_path_buf[0..self.sock_path_len]) catch {};
    }

    /// Show the entries newcomers hand over, answering "ok" to each.
    pub fn acceptClients(self: *Quick) void {
        while (sys.accept(self.listen_fd) catch null) |fd| {
            defer sys.close(fd);
            var buf: [1300]u8 = undefined;
            const a = quick_ipc.parseAdd(readLine(fd, &buf)) orelse continue;
            self.add(a.root, a.id) catch |err| {
                std.log.warn("quick access: cannot show {s}: {t}", .{ a.id, err });
                continue;
            };
            std.log.info("quick access: added {s}", .{a.id});
            sys.writeAll(fd, "ok\n") catch {};
        }
    }

    /// A client's request line (up to half a second).
    fn readLine(fd: sys.fd_t, buf: []u8) []const u8 {
        var n: usize = 0;
        const deadline = sys.monoMs() + 500;
        while (n < buf.len) {
            if (!(sys.waitReadable(fd, deadline) catch false)) break;
            const k = sys.read(fd, buf[n..]) catch break;
            if (k == 0) break;
            n += k;
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
        }
        return buf[0..n];
    }

    // --- the cards ---

    /// Put the entry's card at the bottom of the stack (replacing an
    /// older card of the same capture).
    pub fn add(self: *Quick, root: []const u8, id: []const u8) !void {
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
        self.dropCardOf(id);
        const now = sys.monoMs();
        try self.cards.insert(self.gpa, 0, .{
            .kept = kept,
            .meta = meta,
            .editable = editable,
            .thumb = thumb,
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

    fn dropCardOf(self: *Quick, id: []const u8) void {
        for (self.cards.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.kept.id.slice(), id)) {
                var old = self.cards.orderedRemove(i);
                old.deinit(self.gpa);
                break;
            }
        }
    }

    pub fn remove(self: *Quick, i: usize) void {
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

    // --- the window ---

    /// Open the window on the first card; resize it to the stack later.
    fn fitWindow(self: *Quick) !void {
        const sz = layout.windowSize(self.cards.items.len, self.hint);
        if (!self.opened) {
            try self.openWindow(sz);
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

    fn openWindow(self: *Quick, sz: [2]u32) !void {
        if (self.win.hasLayerShell()) {
            self.layer = true;
            // keyboard only while the pointer is over it (see the
            // .pointer_motion event): typing stays in the person's app
            try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1], .layer = .{
                .layer = .overlay,
                .anchor = .{ .bottom = true, .left = true },
                .width = sz[0],
                .height = sz[1],
                .margin = .{ 0, 0, edge, edge },
                .keyboard = .none,
            } });
        } else {
            try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1] });
        }
        self.win.report_leave = true;
        self.win.setCursor(.arrow) catch {};
        self.opened = true;
    }

    /// Only the cards (and the hint) take input, not their shadows.
    fn updateInputRegion(self: *Quick) !void {
        var rects: [max_cards + 1]window.Rect = undefined;
        const h: i32 = @intCast(self.size[1]);
        const n = self.cards.items.len;
        for (0..n) |i| {
            const r = layout.cardRect(i, h);
            rects[i] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        }
        var k = n;
        if (self.hint) {
            rects[k] = .{ .x = pad, .y = pad, .w = card_w, .h = layout.hint_h - layout.gap };
            k += 1;
        }
        try self.win.setInputRegion(0, rects[0..k]);
    }

    fn menus(self: *const Quick, buf: []bool) []bool {
        const n = @min(buf.len, self.cards.items.len);
        for (self.cards.items[0..n], 0..) |c, i| buf[i] = c.menu;
        return buf[0..n];
    }

    /// What is under a point in buffer coordinates.
    pub fn hitAt(self: *const Quick, bx: f64, by: f64) ?Hit {
        if (bx < 0 or by < 0) return null;
        const k = self.f();
        var mb: [max_cards]bool = undefined;
        return layout.hitTest(@intFromFloat(bx / k), @intFromFloat(by / k), @intCast(self.size[1]), self.cards.items.len, self.menus(&mb), self.hint);
    }

    /// The card actions and shortcuts apply to: focused, hovered, newest.
    pub fn current(self: *const Quick) ?usize {
        if (self.cards.items.len == 0) return null;
        if (self.focus) |fo| return fo.card;
        if (self.hover) |h| if (h.control != .hint) return h.card;
        return 0;
    }
};
