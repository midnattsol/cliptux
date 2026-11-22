//! `shotlet quick-video ROOT ID`: the floating thumbnail of a finished
//! recording, in the bottom-left corner like the screenshot thumbnail
//! (a layer-shell surface, or a "shotlet:quick" window the GNOME Shell
//! extension places). Hovering plays the filmstrip; Copy puts the file on
//! the clipboard (text/uri-list, and the video itself as video/mp4 or
//! image/gif); Save as… copies it elsewhere; the scissors open the trim
//! window; dragging it drops the file into another app. It fades in and
//! stays until closed: a recording is not glanced at like a screenshot.

const std = @import("std");
const transfer = @import("../ui/transfer.zig");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("../app/env.zig");
const history = @import("../app/history.zig");
const keep = @import("../app/keep.zig");
const sys = @import("../platform/api.zig").sys;
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const card = @import("../ui/recui/vidcard.zig");
const keepvid = @import("keepvid.zig");
const files = @import("files.zig");
const Env = env_mod.Env;

const fade_ms = 250;
const fade_in_ms = 150;
const frame_ms = 160;

const Quick = struct {
    gpa: std.mem.Allocator,
    env: Env,
    win: window.Window,
    root: []const u8,
    id: []const u8,
    info: keepvid.Info,
    thumb: png.Image,
    strip: ?png.Image,
    strip_n: u32 = 0,
    hover: ?card.Control = null,
    pressed: ?card.Control = null,
    press_at: [2]f64 = .{ 0, 0 },
    /// first drawn (0: not yet); it fades in from there
    born: i64 = 0,
    fade_from: i64 = 0,
    notice: []const u8 = "",
    notice_until: i64 = 0,
    play_from: i64 = 0,
    dirty: bool = true,
    dragging: bool = false,
    done: bool = false,

    fn scale(self: *const Quick) f64 {
        return @as(f64, @floatFromInt(self.win.scale120)) / 120.0;
    }

    /// The picture to show now: a strip picture while hovered.
    fn picture(self: *const Quick, now: i64) struct { px: []const u32, w: u32, h: u32 } {
        if (self.hover != null and self.strip_n > 1) if (self.strip) |s| {
            const pw = s.width / self.strip_n;
            const i: u32 = @intCast(@mod(@divTrunc(now - self.play_from, frame_ms), self.strip_n));
            return .{ .px = stripPic(s, pw, i, &pic_buf), .w = pw, .h = s.height };
        };
        return .{ .px = self.thumb.pixels, .w = self.thumb.width, .h = self.thumb.height };
    }

    var pic_buf: [strip_max_px]u32 = undefined;
    const strip_max_px = 256 * 256;

    fn stripPic(s: png.Image, pw: u32, i: u32, buf: *[strip_max_px]u32) []const u32 {
        const n = @min(@as(usize, pw) * s.height, buf.len);
        for (0..s.height) |y| {
            if ((y + 1) * pw > n) break;
            @memcpy(buf[y * pw ..][0..pw], s.pixels[y * s.width + i * pw ..][0..pw]);
        }
        return buf[0..n];
    }

    fn render(self: *Quick) !void {
        const now = sys.monoMs();
        if (self.hover != null and self.strip_n > 1) self.dirty = true;
        if (!self.dirty or self.win.frame_pending or self.win.width == 0) return;
        self.dirty = false;
        const px = try self.win.backBuffer();
        @memset(px, 0);
        const pic = self.picture(now);
        if (self.born == 0) self.born = now;
        var alpha: f64 = @min(1, @as(f64, @floatFromInt(now - self.born)) / fade_in_ms);
        if (self.fade_from != 0) alpha = @max(0, 1 - @as(f64, @floatFromInt(now - self.fade_from)) / fade_ms);
        if (self.dragging) alpha = 0.5;
        card.paint(self.gpa, px, self.win.width, self.win.height, self.scale(), &.{
            .pic = pic.px,
            .pic_w = pic.w,
            .pic_h = pic.h,
            .duration_ms = self.info.duration_ms,
            .gif = self.info.format == .gif,
            .hover = self.hover,
            .hovered = self.hover != null,
            .notice = if (now < self.notice_until) self.notice else "",
            .alpha = alpha,
        });
        fui.premultiply(px, self.win.width, self.win.height, .{ .x = 0, .y = 0, .w = @intCast(self.win.width), .h = @intCast(self.win.height) });
        try self.win.present();
    }

    fn say(self: *Quick, s: []const u8) void {
        self.notice = s;
        self.notice_until = sys.monoMs() + 1200;
        self.dirty = true;
    }

    fn onEvent(self: *Quick, ev: window.InputEvent) void {
        const k = self.scale();
        switch (ev) {
            .resize, .frame_done => self.dirty = true,
            .close => self.done = true,
            .pointer_motion => |m| {
                const h = card.hit(@intFromFloat(m.x / k), @intFromFloat(m.y / k));
                if (h != null and self.hover == null) self.play_from = sys.monoMs();
                if (h != self.hover) self.dirty = true;
                self.hover = h;
                if (self.pressed == .body and !self.dragging) {
                    const dx = (m.x - self.press_at[0]) / k;
                    const dy = (m.y - self.press_at[1]) / k;
                    if (dx * dx + dy * dy > 36) self.startDrag() catch |err| std.log.warn("quick video: drag failed: {t}", .{err});
                }
            },
            .pointer_button => |b| if (b.button == .left) {
                const h = card.hit(@intFromFloat(b.x / k), @intFromFloat(b.y / k));
                if (b.pressed) {
                    self.pressed = h;
                    self.press_at = .{ b.x, b.y };
                } else {
                    const p = self.pressed;
                    self.pressed = null;
                    if (p != null and p == h) self.act(h.?);
                }
            },
            else => {},
        }
    }

    fn act(self: *Quick, c: card.Control) void {
        self.actInner(c) catch |err| {
            std.log.warn("quick video: {t} failed: {t}", .{ c, err });
            self.say("Failed");
        };
    }

    fn actInner(self: *Quick, c: card.Control) !void {
        switch (c) {
            .close => self.fade_from = sys.monoMs(),
            .copy => {
                try files.copyToClipboard(self.gpa, &self.win, self.info.path);
                std.log.info("quick video: copied {s}", .{self.info.path});
                self.say("Copied");
            },
            .save_as => {
                var bus = try desktop.connect(self.gpa, self.env);
                defer bus.deinit();
                const saved = (try files.saveAs(self.gpa, self.env, &bus, self.info.path)) orelse return;
                defer self.gpa.free(saved);
                std.log.info("quick video: saved to {s}", .{saved});
                self.say("Saved");
            },
            .trim => {
                var rb: [1100]u8 = undefined;
                var ib: [40]u8 = undefined;
                const r = try std.fmt.bufPrintSentinel(&rb, "{s}", .{self.root}, 0);
                const i = try std.fmt.bufPrintSentinel(&ib, "{s}", .{self.id}, 0);
                keep.spawnSelf(self.env, &.{ "trim", r.ptr, i.ptr });
                self.done = true;
            },
            .body => {},
        }
    }

    fn startDrag(self: *Quick) !void {
        self.pressed = null;
        const uri = try transfer.fileUriList(self.gpa, self.info.path);
        errdefer self.gpa.free(uri);
        var pbuf: [1200]u8 = undefined;
        const poster = try sys.readFileAlloc(self.gpa, try history.entryPath(&pbuf, self.root, self.id, "thumb.png"), 64 * 1024 * 1024);
        try self.win.startDrag(0, poster, uri, null);
        self.dragging = true;
        self.dirty = true;
        std.log.info("quick video: dragging {s}", .{self.info.path});
    }

    fn checkDrag(self: *Quick) void {
        if (!self.dragging) return;
        switch (self.win.drag_state) {
            .finished => {
                self.win.endDrag();
                self.dragging = false;
                self.done = true;
            },
            .cancelled => {
                self.win.endDrag();
                self.dragging = false;
                self.dirty = true;
            },
            else => {},
        }
    }

    fn tick(self: *Quick) void {
        const now = sys.monoMs();
        if (self.born == 0 or now - self.born < fade_in_ms) self.dirty = true;
        if (self.fade_from != 0) {
            self.dirty = true;
            if (now - self.fade_from >= fade_ms) self.done = true;
        }
        if (self.notice_until != 0 and now >= self.notice_until) {
            self.notice_until = 0;
            self.dirty = true;
        }
    }

    fn open(self: *Quick) !void {
        const sz = card.windowSize();
        if (self.win.hasLayerShell()) {
            try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1], .layer = .{
                .anchor = .{ .bottom = true, .left = true },
                .width = sz[0],
                .height = sz[1],
                .margin = .{ 0, 0, 8, 8 },
                .keyboard = .none,
                .namespace = "shotlet-quick-video",
            } });
        } else {
            try self.win.open("shotlet:quick", .{ .fullscreen = false, .transparent = true, .width = sz[0], .height = sz[1] });
        }
        self.win.report_leave = true;
        self.win.setCursor(.arrow) catch {};
        const p = card.pad;
        try self.win.setInputRegion(0, &.{.{ .x = p, .y = p, .w = card.card_w, .h = card.card_h }});
    }
};

fn loadPng(gpa: std.mem.Allocator, root: []const u8, id: []const u8, name: []const u8) !png.Image {
    var pbuf: [1200]u8 = undefined;
    const data = try sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, name), 64 * 1024 * 1024);
    defer gpa.free(data);
    return png.decode(gpa, data);
}

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    const vi = keepvid.read(gpa, root, id) orelse return error.NotARecording;
    defer gpa.free(vi.buf);
    var thumb = try loadPng(gpa, root, id, "thumb.png");
    defer thumb.deinit(gpa);
    var strip: ?png.Image = loadPng(gpa, root, id, "strip.png") catch null;
    defer if (strip) |*s| s.deinit(gpa);
    var n_pics: u32 = 0;
    if (vi.info.strip.len > 0) n_pics = @intCast(std.mem.count(u8, vi.info.strip, ",") + 1);
    text.init(gpa);
    defer text.deinit();
    var q: Quick = .{
        .gpa = gpa,
        .env = env,
        .win = try window.Window.init(gpa, env),
        .root = root,
        .id = id,
        .info = vi.info,
        .thumb = thumb,
        .strip = strip,
        .strip_n = n_pics,
    };
    defer q.win.deinit();
    try q.open();
    std.log.info("quick video: showing {s} ({d} ms)", .{ id, vi.info.duration_ms });
    while (!q.done) {
        try q.win.flush();
        var fds = [_]sys.pollfd{.{ .fd = q.win.pollFd(), .events = sys.POLL.IN, .revents = 0 }};
        _ = try sys.poll(&fds, q.win.pollTimeoutMs(if (q.hover != null or q.fade_from != 0 or sys.monoMs() - q.born < fade_in_ms) 16 else 200));
        while (try q.win.nextEventTimeout(0)) |ev| q.onEvent(ev);
        q.checkDrag();
        q.tick();
        try q.render();
    }
    q.win.closeWindow();
    if (q.win.hasClipboard()) try q.win.serveClipboard();
}
