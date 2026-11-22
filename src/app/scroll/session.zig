//! One scrolling capture, from the first frame to the tall image: frames
//! are grabbed (after a scroll when Shotlet turns the wheel) and stitched
//! while the control (ui/scroll_hud.zig) shows the image growing. Every
//! stop has a reason (stop.zig), logged and shown in plain words:
//!
//! - natural (the end of the page, the height limit, Stop): the image is
//!   complete; the control says why for a moment, then the editor opens;
//! - short (the page didn't move, the next part didn't line up, the
//!   frames stopped coming): it pauses with Continue, Finish and Cancel.
//!   Continue picks up from where it stopped, keeping what is stitched:
//!   it tries the wheel again, lets the person scroll back until the
//!   parts line up, or starts the frame source over.

const std = @import("std");
const capture = @import("../capture.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/linux/sys.zig");
const geom = @import("../modes/geom.zig");
const flow = @import("../modes/flow.zig");
const hud_mod = @import("../../ui/scroll_hud.zig");
const stitch = @import("stitch.zig");
const stop = @import("stop.zig");
const source = @import("../../platform/linux/capture/scroll_source.zig");

/// How long a natural stop's reason stays up before the editor opens.
const done_hold_ms = 900;

fn sleepMs(ms: u64) void {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// What (re)opens the frame source.
pub const Opener = struct {
    cap: *const capture.Capture,
    region: geom.Rect,
    shell: bool,
    auto: bool,
};

pub const Session = struct {
    c: flow.Ctx,
    hud: *hud_mod.Hud,
    opener: Opener,
    max_height: u32,
    src: ?source.Source = null,
    st: ?stitch.Stitcher = null,
    watch: stop.Watch,
    /// wheel notches per step, adapted to land about half a view further
    clicks: i32 = 3,
    /// after Continue from no_match: the person scrolls back (no wheel)
    /// until the parts line up again
    realign: bool = false,
    /// a warning is up (the person scrolled past what lines up)
    warned: bool = false,

    pub fn init(c: flow.Ctx, hud: *hud_mod.Hud, opener: Opener, max_height: u32) !Session {
        var self: Session = .{ .c = c, .hud = hud, .opener = opener, .max_height = max_height, .watch = .{ .auto = false } };
        const src = try self.open();
        self.watch.auto = src.scrolls();
        std.log.info("scrolling capture: {s}, {s}", .{ @tagName(src.*), if (src.scrolls()) "Shotlet scrolls" else "the person scrolls" });
        return self;
    }

    pub fn deinit(self: *Session) void {
        if (self.src) |*s| s.deinit();
        self.src = null;
    }

    fn open(self: *Session) !*source.Source {
        const o = self.opener;
        self.src = try source.open(self.c.gpa, self.c.env, self.c.conn, o.cap, o.region, o.shell, o.auto);
        return &self.src.?;
    }

    /// The source over again (its session timed out, it failed).
    fn reopen(self: *Session) !*source.Source {
        self.deinit();
        return self.open();
    }

    /// Shotlet turns the wheel now.
    fn wheel(self: *const Session) bool {
        return !self.realign and self.opener.auto and if (self.src) |*s| s.scrolls() else false;
    }

    fn rowOf(ctx: *const anyopaque, y: u32) []const u32 {
        const st: *const stitch.Stitcher = @ptrCast(@alignCast(ctx));
        return st.row(y);
    }

    fn preview(self: *const Session) ?hud_mod.Source {
        const st = if (self.st) |*s| s else return null;
        return .{ .ctx = st, .width = st.width, .height = st.totalHeight(), .row = rowOf };
    }

    fn total(self: *const Session) u32 {
        return if (self.st) |*s| s.totalHeight() else 0;
    }

    /// A frame; when the source fails, once more from a new source (the
    /// extension ends a session left idle).
    fn grab(self: *Session, clicks: i32) !png.Image {
        const c = self.c;
        if (self.src) |*s| {
            if (s.grab(c.gpa, c.env, c.conn, clicks)) |f| return f else |err| std.log.info("scrolling capture: no frame ({t}), starting the source again", .{err});
        }
        const s = try self.reopen();
        return s.grab(c.gpa, c.env, c.conn, 0);
    }

    /// The region once nothing moves in it any more (the picker's fade,
    /// a repaint under load), at most about two seconds on.
    fn settled(self: *Session) !png.Image {
        var a = try self.grab(0);
        for (0..12) |_| {
            sleepMs(60);
            const b = try self.grab(0);
            const same = std.mem.eql(u32, a.pixels, b.pixels);
            a.deinit(self.c.gpa);
            a = b;
            if (same) break;
        }
        return a;
    }

    /// The tall image; null when cancelled.
    pub fn collect(self: *Session) !?png.Image {
        var first = try self.settled();
        defer first.deinit(self.c.gpa);
        self.st = try stitch.Stitcher.init(self.c.gpa, .{ .pixels = first.pixels, .width = first.width, .height = first.height }, self.max_height);
        defer self.st.?.deinit();
        self.showRunning();
        _ = (try self.until()) orelse return null;
        const out = try self.st.?.result();
        std.log.info("scrolling capture: {d}x{d}", .{ out.width, out.height });
        return .{ .width = out.width, .height = out.height, .pixels = @constCast(out.pixels) };
    }

    /// Scroll, pause and continue until the capture is complete: why it
    /// ended, or null when cancelled.
    fn until(self: *Session) !?stop.Reason {
        while (true) {
            const why = (try self.scrolling()) orelse return cancelled();
            var buf: [96]u8 = undefined;
            const msg = why.message(&buf, self.max_height);
            std.log.info("scrolling capture: stopped: {t} ({s}) at {d} px", .{ why, msg, self.total() });
            if (why.natural()) {
                if (why != .user_stopped and !(try self.hold(msg))) return cancelled();
                return why;
            }
            switch (try self.paused(msg)) {
                .finish => {
                    std.log.info("scrolling capture: finished after {t}", .{why});
                    return why;
                },
                .cancel => return cancelled(),
                .@"continue" => self.carryOn(why),
            }
        }
    }

    fn cancelled() ?stop.Reason {
        std.log.info("scrolling capture: cancelled", .{});
        return null;
    }

    /// Frames until something stops it; null when cancelled.
    fn scrolling(self: *Session) !?stop.Reason {
        while (true) {
            try self.hud.draw(self.preview());
            if (try self.hud.poll(if (self.wheel()) 10 else 120)) |a| switch (a) {
                .finish => return .user_stopped,
                .cancel => return null,
                .@"continue" => {},
            };
            if (try self.step()) |why| return why;
        }
    }

    /// Paused: wait for Continue, Finish or Cancel.
    fn paused(self: *Session, msg: []const u8) !hud_mod.Action {
        self.hud.showMessage(.paused, msg, self.total());
        while (true) {
            try self.hud.draw(self.preview());
            if (try self.hud.poll(100)) |a| return a;
        }
    }

    /// A natural stop: its reason for a moment (Finish skips the wait).
    /// False when cancelled meanwhile.
    fn hold(self: *Session, msg: []const u8) !bool {
        self.hud.showMessage(.done, msg, self.total());
        const until_ms = sys.monoMs() + done_hold_ms;
        while (sys.monoMs() < until_ms) {
            try self.hud.draw(self.preview());
            if (try self.hud.poll(30)) |a| return a != .cancel;
        }
        return true;
    }

    /// Continue after a short stop, keeping what is stitched.
    fn carryOn(self: *Session, why: stop.Reason) void {
        std.log.info("scrolling capture: continuing after {t}", .{why});
        self.watch.restart();
        switch (why) {
            .didnt_move => self.clicks = 3,
            .no_match => if (self.opener.auto) {
                self.realign = true;
            },
            .lost => if (self.reopen()) |_| {} else |err| std.log.warn("scrolling capture: {t}", .{err}),
            else => {},
        }
        self.watch.auto = self.wheel();
        self.showRunning();
    }

    fn showRunning(self: *Session) void {
        const h = self.total();
        if (self.realign) return self.hud.show(.warning, "Scroll back up a little", "It carries on once the parts line up", h);
        if (self.wheel()) return self.hud.show(.running, "Scrolling\u{2026}", "", h);
        const moved = self.watch.moved;
        self.hud.show(.running, if (moved) "Keep scrolling" else "Scroll the page now", "Stop when you reach the end", h);
    }

    /// One frame: why it stops, or null to go on.
    fn step(self: *Session) !?stop.Reason {
        const clicks: i32 = if (self.wheel()) self.clicks else 0;
        var f = self.grab(clicks) catch |err| {
            std.log.warn("scrolling capture: no frame: {t}", .{err});
            return .lost;
        };
        defer f.deinit(self.c.gpa);
        const st = &self.st.?;
        var r = st.push(.{ .pixels = f.pixels, .width = f.width, .height = f.height }) catch |err| {
            std.log.warn("scrolling capture: {t}", .{err});
            return .lost;
        };
        // the app may not have painted the scroll yet, or a frame caught
        // it mid-repaint: look again before counting it
        if (clicks > 0 and (r == .unchanged or r == .no_overlap)) r = self.recheck(r) catch return .lost;
        switch (self.watch.feed(r, clicks)) {
            .go => {},
            .slower => {
                std.log.info("scrolling capture: moved too far ({d} notches)", .{clicks});
                self.clicks = @max(1, @divTrunc(clicks, 2));
            },
            .warn => |why| if (!self.warned and !self.realign) {
                self.warned = true;
                var buf: [96]u8 = undefined;
                const msg = why.message(&buf, self.max_height);
                std.log.info("scrolling capture: warning: {t} ({s})", .{ why, msg });
                self.hud.showMessage(.warning, msg, st.totalHeight());
            },
            .stop => |why| return why,
        }
        if (r == .appended) self.appended(r.appended, f.height);
        return null;
    }

    /// The region again, without scrolling: what it does now (`was` when
    /// it still has not moved).
    fn recheck(self: *Session, was: stitch.Push) !stitch.Push {
        sleepMs(150);
        var f = try self.settled();
        defer f.deinit(self.c.gpa);
        const r = try self.st.?.push(.{ .pixels = f.pixels, .width = f.width, .height = f.height });
        return if (r == .unchanged) was else r;
    }

    fn appended(self: *Session, d: u32, h: u32) void {
        if (self.warned or self.realign) std.log.info("scrolling capture: lined up again", .{});
        self.warned = false;
        if (self.realign) {
            // lined up again: back to the wheel, carefully
            self.realign = false;
            self.clicks = 1;
            self.watch.auto = self.wheel();
        } else if (self.wheel()) {
            const per_click = @max(1, @divTrunc(@as(i32, @intCast(d)), self.clicks));
            self.clicks = std.math.clamp(@divTrunc(@as(i32, @intCast(h / 2)), per_click), 1, 10);
        }
        self.showRunning();
    }
};
