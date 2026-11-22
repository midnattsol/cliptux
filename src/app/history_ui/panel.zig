//! The "Recent captures" panel's state: the kept captures, the search
//! filter, hover and selection, and what the action bar does with the
//! picked capture. Layout, input, drawing and OCR live in sibling files
//! and are reachable as methods.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const config = @import("../config.zig");
const env_mod = @import("../env.zig");
const history = @import("../history.zig");
const keep = @import("../keep.zig");
const shot = @import("../shot.zig");
const ocr_search = @import("../../ocr/search.zig");
const sys = @import("../../platform/api.zig").sys;
const png = @import("../../gfx/png.zig");
const window = @import("../../platform/api.zig").window;
const fui = @import("../../ui/floatui.zig");
const layout = @import("layout.zig");
const ocr_scan = @import("ocr_scan.zig");
const events = @import("events.zig");
const render_mod = @import("render.zig");

const Env = env_mod.Env;
const Action = layout.Action;

pub const Item = struct {
    entry: history.Entry,
    thumb: ?png.Image,
    scaled: []u32 = &.{},
    sw: u32 = 0,
    sh: u32 = 0,
};

pub const Panel = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: config.Config,
    win: window.Window,
    bus: ?desktop.Session = null,
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    items: std.ArrayList(Item) = .empty,
    /// indexes into items that match the search
    shown: std.ArrayList(usize) = .empty,
    selected: ?usize = null,
    hover_item: ?usize = null,
    hover_action: ?usize = null,
    hover_clear: bool = false,
    /// "Clear N captures?" is showing, and which of its buttons is hovered
    confirm_clear: bool = false,
    hover_confirm: ?layout.Confirm = null,
    hover_close: bool = false,
    pressed: ?u32 = null,
    scroll: i32 = 0,
    search: std.ArrayList(u8) = .empty,
    searchable: bool = false,
    notice: []const u8 = "",
    notice_until: i64 = 0,
    dirty: bool = true,
    ocr_state: ocr_scan.Ocr = .{},
    theme: fui.Theme = fui.Theme.dark,

    pub const searchTop = layout.searchTop;
    pub const gridTop = layout.gridTop;
    pub const contentH = layout.contentH;
    pub const panelH = layout.panelH;
    pub const gridViewH = layout.gridViewH;
    pub const itemRect = layout.itemRect;
    pub const actionRect = layout.actionRect;
    pub const clearRect = layout.clearRect;
    pub const confirmRect = layout.confirmRect;
    pub const closeRect = layout.closeRect;
    pub const resize = layout.resize;
    pub const startOcr = ocr_scan.startOcr;
    pub const pollOcr = ocr_scan.pollOcr;
    pub const onEvent = events.onEvent;
    pub const render = render_mod.render;

    pub fn root(self: *const Panel) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    /// Display scale.
    pub fn k(self: *const Panel) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    pub fn deinit(self: *Panel) void {
        self.ocr_state.deinit(self.gpa);
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

    /// (Re)load the kept captures and their thumbnails.
    pub fn load(self: *Panel) !void {
        self.freeItems();
        const list = try history.list(self.gpa, self.root());
        defer self.gpa.free(list);
        for (list) |e| {
            try self.items.append(self.gpa, .{ .entry = e, .thumb = self.loadThumb(e.id.slice()) });
        }
        self.filter();
        std.log.info("history: {d} captures", .{self.items.items.len});
    }

    fn loadThumb(self: *Panel, id: []const u8) ?png.Image {
        var pbuf: [1200]u8 = undefined;
        const p = history.entryPath(&pbuf, self.root(), id, "thumb.png") catch return null;
        const data = sys.readFileAlloc(self.gpa, p, 16 * 1024 * 1024) catch return null;
        defer self.gpa.free(data);
        return png.decode(self.gpa, data) catch null;
    }

    /// Show the captures whose text matches the search (all without one).
    pub fn filter(self: *Panel) void {
        self.shown.clearRetainingCapacity();
        for (self.items.items, 0..) |it, i| {
            if (self.search.items.len > 0) {
                const t = it.entry.meta.ocr orelse continue;
                if (!ocr_search.matches(t, self.search.items)) continue;
            }
            self.shown.append(self.gpa, i) catch {};
        }
        if (self.search.items.len > 0) std.log.info("history: search '{s}': {d} shown", .{ self.search.items, self.shown.items.len });
        if (self.selected) |s| if (std.mem.indexOfScalar(usize, self.shown.items, s) == null) {
            self.selected = null;
        };
        self.scroll = 0;
        self.dirty = true;
    }

    // --- actions ---

    pub fn bus_(self: *Panel) ?*desktop.Session {
        if (self.bus == null) self.bus = desktop.connect(self.gpa, self.env) catch return null;
        return &self.bus.?;
    }

    fn say(self: *Panel, s: []const u8) void {
        self.notice = s;
        self.notice_until = sys.monoMs() + 1500;
        self.dirty = true;
    }

    /// Clear the notice once its time is up.
    pub fn expireNotice(self: *Panel) void {
        if (self.notice_until != 0 and sys.monoMs() > self.notice_until) {
            self.notice = "";
            self.notice_until = 0;
            self.dirty = true;
        }
    }

    /// Apply an action to the picked capture.
    pub fn act(self: *Panel, a: Action) void {
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
            .copy => try self.copy(id, image),
            .save => try self.save(it, image),
            .annotate => {
                if (!it.entry.editable) return;
                try self.annotate(id);
            },
            .pin => {
                const p = try self.gpa.dupeSentinel(u8, image, 0);
                defer self.gpa.free(p);
                keep.spawnPin(self.env, p, it.entry.meta.at);
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

    fn copy(self: *Panel, id: []const u8, image: []const u8) !void {
        const data = try sys.readFileAlloc(self.gpa, image, 512 * 1024 * 1024);
        self.win.setClipboardPng(data) catch |err| {
            self.gpa.free(data);
            return err;
        };
        std.log.info("history: copied {s}", .{id});
        self.say("Copied");
    }

    /// Save to the save folder and remember where in the entry's meta.
    fn save(self: *Panel, it: *Item, image: []const u8) !void {
        const data = try sys.readFileAlloc(self.gpa, image, 512 * 1024 * 1024);
        defer self.gpa.free(data);
        const path = try shot.savePng(self.gpa, self.env, &self.cfg, data);
        defer self.gpa.free(path);
        self.gpa.free(it.entry.meta.saved);
        it.entry.meta.saved = &.{};
        it.entry.meta.saved = try self.gpa.dupe(u8, path);
        history.writeMeta(self.gpa, self.root(), it.entry.id.slice(), &it.entry.meta) catch {};
        std.log.info("history: saved to {s}", .{path});
        self.say("Saved");
    }

    /// Open the capture in the editor (a new process).
    fn annotate(self: *Panel, id: []const u8) !void {
        const r = try self.gpa.dupeSentinel(u8, self.root(), 0);
        defer self.gpa.free(r);
        const idz = try self.gpa.dupeSentinel(u8, id, 0);
        defer self.gpa.free(idz);
        keep.spawnSelf(self.env, &.{ "edit", r.ptr, idz.ptr });
    }

    pub fn clearAll(self: *Panel) !void {
        self.confirm_clear = false;
        history.clear(self.root());
        std.log.info("history: cleared", .{});
        self.selected = null;
        try self.load();
        try self.resize();
    }
};
