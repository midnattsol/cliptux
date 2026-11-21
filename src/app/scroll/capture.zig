//! The scrolling capture: pick a region on the frozen capture, then
//! frames of it as the content scrolls (Shotlet turning the wheel where
//! it can, else the person scrolling), stitched (stitch.zig) while the
//! control (ui/scroll_hud.zig) shows the image growing. Stop, the end of
//! the page or the maximum height ends it; the tall image goes to the
//! editor.

const std = @import("std");
const capture = @import("../capture.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/sys.zig");
const gnome = @import("../gnome.zig");
const geom = @import("../modes/geom.zig");
const flow = @import("../modes/flow.zig");
const settings = @import("../modes/settings.zig");
const shell_bus = @import("../modes/shell_bus.zig");
const region_pick = @import("../../ui/region_pick.zig");
const hud_mod = @import("../../ui/scroll_hud.zig");
const stitch = @import("stitch.zig");
const source = @import("source.zig");

fn sleepMs(ms: u64) void {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Null when cancelled.
pub fn run(c: flow.Ctx, cap: *const capture.Capture, s: settings.Settings) !?png.Image {
    std.log.info("scrolling capture: pick a region", .{});
    const region = switch (try region_pick.pick(c.gpa, c.win, cap, .{ .region = .{ .label = "Start scrolling capture" } })) {
        .region => |r| r,
        else => return null,
    };
    std.log.info("scrolling capture: region {d}x{d} at {d},{d}", .{ region.w, region.h, region.x, region.y });
    const shell = gnome.isGnome() and gnome.extensionActive(c.conn);
    var hud = try hud_mod.Hud.open(c.win);
    defer c.win.closeWindow();
    try showHud(c, &hud, cap, region, shell);
    var src = try source.open(c.gpa, c.env, c.conn, cap, region, shell, s.scroll_auto);
    defer src.deinit();
    std.log.info("scrolling capture: {s}, {s}", .{ @tagName(src), if (src.scrolls()) "Shotlet scrolls" else "the person scrolls" });
    var session: Session = .{ .c = c, .hud = &hud, .src = &src, .max_height = s.scroll_max_height };
    return session.collect();
}

/// Map the control, beside the region on GNOME, and let the overlay go.
fn showHud(c: flow.Ctx, hud: *hud_mod.Hud, cap: *const capture.Capture, region: geom.Rect, shell: bool) !void {
    const deadline = sys.monoMs() + 1500;
    var placed = !shell;
    while (sys.monoMs() < deadline) {
        try hud.draw(null);
        _ = try hud.poll(50);
        if (!placed) if (besideRegion(cap, region)) |p| {
            placed = shell_bus.place(c.gpa, c.conn, hud_mod.title, p[0], p[1]);
        };
        if (placed and sys.monoMs() + 1000 > deadline) break;
    }
}

/// Where the control goes (logical): right of the region, else left,
/// else the monitor's top-right corner.
fn besideRegion(cap: *const capture.Capture, region: geom.Rect) ?[2]i32 {
    const l = (geom.imageToLogical(cap.monitors, region) orelse return null).rect;
    const m = cap.monitors[geom.monitorAt(cap.monitors, .{ l.x + @divTrunc(l.w, 2), l.y + @divTrunc(l.h, 2) })].logical orelse return null;
    const gap = 16;
    const w = hud_mod.width;
    const h = hud_mod.height;
    const right = m.x + @as(i32, @intCast(m.w));
    const y = std.math.clamp(l.y, m.y + gap, m.y + @as(i32, @intCast(m.h)) - h - gap);
    if (l.x + l.w + gap + w <= right) return .{ l.x + l.w + gap, y };
    if (l.x - gap - w >= m.x) return .{ l.x - gap - w, y };
    return .{ right - w - gap, m.y + gap };
}

const Session = struct {
    c: flow.Ctx,
    hud: *hud_mod.Hud,
    src: *source.Source,
    max_height: u32,
    st: ?stitch.Stitcher = null,
    /// wheel notches per step, adapted to land about half a view further
    clicks: i32 = 3,
    still: u32 = 0,

    fn rowOf(ctx: *const anyopaque, y: u32) []const u32 {
        const st: *const stitch.Stitcher = @ptrCast(@alignCast(ctx));
        return st.row(y);
    }

    fn preview(self: *const Session) ?hud_mod.Source {
        const st = if (self.st) |*s| s else return null;
        return .{ .ctx = st, .width = st.width, .height = st.totalHeight(), .row = rowOf };
    }

    fn grab(self: *Session, clicks: i32) !png.Image {
        return self.src.grab(self.c.gpa, self.c.env, self.c.conn, clicks);
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

    fn collect(self: *Session) !?png.Image {
        var first = try self.settled();
        defer first.deinit(self.c.gpa);
        self.st = try stitch.Stitcher.init(self.c.gpa, .{ .pixels = first.pixels, .width = first.width, .height = first.height }, self.max_height);
        defer self.st.?.deinit();
        const auto = self.src.scrolls();
        self.hud.setStatus(if (auto) "Scrolling\u{2026}" else "Scroll the page now", first.height);
        while (true) {
            try self.hud.draw(self.preview());
            if (try self.hud.poll(if (auto) 10 else 120)) |a| switch (a) {
                .stop => break,
                .cancel => return null,
            };
            if (try self.step(auto)) break;
        }
        const out = try self.st.?.result();
        std.log.info("scrolling capture: {d}x{d}", .{ out.width, out.height });
        return .{ .width = out.width, .height = out.height, .pixels = @constCast(out.pixels) };
    }

    /// One frame; true when the capture is complete.
    fn step(self: *Session, auto: bool) !bool {
        var f = try self.grab(if (auto) self.clicks else 0);
        defer f.deinit(self.c.gpa);
        const st = &self.st.?;
        const r = st.push(.{ .pixels = f.pixels, .width = f.width, .height = f.height }) catch |err| {
            std.log.warn("scrolling capture: {t}", .{err});
            return true;
        };
        switch (r) {
            .appended => |d| {
                self.still = 0;
                if (auto) self.adapt(d, f.height);
                self.hud.setStatus(if (auto) "Scrolling\u{2026}" else "Keep scrolling, or Stop", st.totalHeight());
            },
            .unchanged => {
                // the app may not have painted the scroll yet
                if (auto and try self.recheck()) return false;
                self.still += 1;
                if (auto and self.still >= 2) {
                    std.log.info("scrolling capture: reached the end", .{});
                    return true;
                }
            },
            .no_overlap => {
                // a frame caught mid-repaint: look again before giving up
                if (auto and try self.recheck()) return false;
                std.log.info("scrolling capture: moved too far ({d} notches)", .{self.clicks});
                if (auto and self.clicks == 1) return true;
                self.clicks = @max(1, @divTrunc(self.clicks, 2));
                self.hud.setStatus(if (auto) "Scrolling\u{2026}" else "Scroll more slowly", st.totalHeight());
            },
            .full => {
                std.log.info("scrolling capture: reached the maximum height", .{});
                return true;
            },
        }
        return false;
    }

    /// The region again, without scrolling: true when it lines up now.
    fn recheck(self: *Session) !bool {
        sleepMs(150);
        var f = try self.settled();
        defer f.deinit(self.c.gpa);
        const r = try self.st.?.push(.{ .pixels = f.pixels, .width = f.width, .height = f.height });
        return r == .appended;
    }

    fn adapt(self: *Session, d: u32, h: u32) void {
        const per_click = @max(1, @divTrunc(@as(i32, @intCast(d)), self.clicks));
        self.clicks = std.math.clamp(@divTrunc(@as(i32, @intCast(h / 2)), per_click), 1, 10);
    }
};
