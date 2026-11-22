//! What the quick access thumbnails do: copy, save, save as, annotate,
//! pin and close a card, enable the GNOME integration from the hint, and
//! drag a card's capture out into other apps.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const env_mod = @import("../env.zig");
const history = @import("../history.zig");
const keep = @import("../keep.zig");
const clock = @import("../clock.zig");
const shot = @import("../shot.zig");
const gnome = @import("../../platform/linux/gnome.zig");
const sys = @import("../../platform/api.zig").sys;
const effects = @import("../../gfx/effects.zig");
const window = @import("../../platform/api.zig").window;
const fui = @import("../../ui/floatui.zig");
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Action = layout.Action;
const Control = layout.Control;
const Hit = layout.Hit;

pub fn act(self: *Quick, i: usize, a: Action) void {
    if (i >= self.cards.items.len) return;
    actInner(self, i, a) catch |err| {
        std.log.warn("quick access: {t} failed: {t}", .{ a, err });
        notice(self, i, "Failed");
    };
}

/// A short word over card i ("Copied"); the card stays a while for it.
pub fn notice(self: *Quick, i: usize, s: []const u8) void {
    const c = &self.cards.items[i];
    c.notice = s;
    c.notice_until = sys.monoMs() + 1200;
    c.deadline_ms = @max(c.deadline_ms, c.notice_until + 1500);
    self.dirty = true;
}

pub fn imagePath(self: *Quick, i: usize, buf: []u8) ![]u8 {
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
            const data = try sys.readFileAlloc(self.gpa, try imagePath(self, i, &pbuf), 512 * 1024 * 1024);
            self.win.setClipboardPng(data) catch |err| {
                self.gpa.free(data);
                return err;
            };
            std.log.info("quick access: copied {s}", .{c.kept.id.slice()});
            notice(self, i, "Copied");
        },
        .save, .save_as => try save(self, i, a == .save_as),
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
            const p = try self.gpa.dupeSentinel(u8, try imagePath(self, i, &pbuf), 0);
            defer self.gpa.free(p);
            keep.spawnSelf(self.env, &.{ "pin", p.ptr });
            self.remove(i);
        },
        .show_in_files => {
            if (c.meta.saved.len == 0) return;
            const b = self.bus_() orelse return error.NoBus;
            try desktop.revealFile(self.gpa, b, c.meta.saved);
            std.log.info("quick access: showing {s} in the file manager", .{c.meta.saved});
        },
        .close => {
            std.log.info("quick access: closed {s}", .{c.kept.id.slice()});
            if (c.fade_from == 0) c.fade_from = sys.monoMs() - stack.fade_ms / 2;
        },
    }
}

/// Save card i (to the save folder, or where the chooser says) and
/// remember where in its meta.
fn save(self: *Quick, i: usize, ask: bool) !void {
    var pbuf: [1200]u8 = undefined;
    const data = try sys.readFileAlloc(self.gpa, try imagePath(self, i, &pbuf), 512 * 1024 * 1024);
    defer self.gpa.free(data);
    const saved: ?[]u8 = if (!ask)
        try shot.savePng(self.gpa, self.env, &self.cfg, data)
    else blk: {
        const b = self.bus_() orelse return error.NoBus;
        break :blk try shot.saveAs(self.gpa, self.env, b, &self.cfg, data, null);
    };
    const path = saved orelse return; // chooser cancelled
    defer self.gpa.free(path);
    const card = &self.cards.items[i];
    self.gpa.free(card.meta.saved);
    card.meta.saved = &.{};
    card.meta.saved = try self.gpa.dupe(u8, path);
    history.writeMeta(self.gpa, card.kept.root(), card.kept.id.slice(), &card.meta) catch {};
    std.log.info("quick access: saved to {s}", .{path});
    notice(self, i, "Saved");
}

/// What control `c` of card i does.
fn controlAction(self: *const Quick, i: usize, c: Control) ?Action {
    const pills = layout.pillActions(self.cards.items[i].meta.saved.len > 0);
    return switch (c) {
        .close => .close,
        .annotate => .annotate,
        .pin => .pin,
        .primary => pills[0],
        .secondary => pills[1],
        else => null,
    };
}

pub fn activate(self: *Quick, h: Hit) void {
    switch (h.control) {
        .menu => act(self, h.card, layout.menu_items[h.item].action),
        .hint => enableGnome(self),
        else => if (h.card < self.cards.items.len) if (controlAction(self, h.card, h.control)) |a| act(self, h.card, a),
    }
}

/// The hint's link: install the GNOME integration and say how it went.
fn enableGnome(self: *Quick) void {
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
}

// --- drag out ---

pub fn startDrag(self: *Quick, i: usize) !void {
    const c = &self.cards.items[i];
    var pbuf: [1200]u8 = undefined;
    const data = try sys.readFileAlloc(self.gpa, try imagePath(self, i, &pbuf), 512 * 1024 * 1024);
    errdefer self.gpa.free(data);
    var file_buf: [1200]u8 = undefined;
    const file = try dragFile(self, c, data, &file_buf);
    const uri = try window.fileUriList(self.gpa, file);
    errdefer self.gpa.free(uri);
    // the icon: the card's picture, smaller, rounded and a bit see-through
    const k: i32 = @max(1, @as(i32, @intCast((self.win.scale120 + 119) / 120)));
    const iw: u32 = @intCast(160 * k);
    const ih: u32 = @intCast(100 * k);
    const icon_px = try self.gpa.alloc(u32, @as(usize, iw) * ih);
    defer self.gpa.free(icon_px);
    try dragIcon(self, c, icon_px, iw, ih, k);
    try self.win.startDrag(0, data, uri, .{ .pixels = icon_px, .width = iw, .height = ih, .scale = k });
    self.dragging = i;
    std.log.info("quick access: dragging {s} (file {s})", .{ c.kept.id.slice(), file });
}

/// A file for apps that take paths: the saved one, else a copy with a
/// readable name in the cache.
fn dragFile(self: *Quick, c: *const stack.Card, data: []const u8, file_buf: []u8) ![]const u8 {
    if (c.meta.saved.len > 0 and (sys.fileSize(c.meta.saved) catch null) != null) return c.meta.saved;
    var dir_buf: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&dir_buf, self.env.home);
    var drag_dir_buf: [1100]u8 = undefined;
    const drag_dir = try std.fmt.bufPrint(&drag_dir_buf, "{s}/drag", .{cache});
    sys.mkdirAll(drag_dir, 0o700);
    const lt = clock.localTime(self.gpa, self.env.tz, @divFloor(c.meta.time_ms, 1000));
    const p = try std.fmt.bufPrint(file_buf, "{s}/shotlet-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.png", .{ drag_dir, lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second });
    try sys.writeFile(p, data);
    return p;
}

/// The drag icon into icon_px (iw x ih, premultiplied).
fn dragIcon(self: *Quick, c: *const stack.Card, icon_px: []u32, iw: u32, ih: u32, k: i32) !void {
    @memset(icon_px, 0);
    const pic = try self.gpa.alloc(u32, @as(usize, iw) * ih);
    defer self.gpa.free(pic);
    fui.drawImageFill(self.gpa, pic, iw, ih, c.thumb.pixels, c.thumb.width, c.thumb.height);
    effects.blitRounded(icon_px, iw, ih, pic, iw, ih, 0, 0, @intCast(10 * k));
    fui.fadeAlpha(icon_px, 0.92);
    fui.premultiply(icon_px, iw, ih, .{ .x = 0, .y = 0, .w = @intCast(iw), .h = @intCast(ih) });
}

/// A finished drag removes the card; a cancelled one keeps it.
pub fn checkDrag(self: *Quick) void {
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
