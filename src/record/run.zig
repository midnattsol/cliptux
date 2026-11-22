//! Running a recording: the area, the countdown, the recording itself
//! with its controls (the floating control, the socket for `shotlet
//! record` and the tray, the GNOME top bar's stop button), then keeping
//! it and showing its thumbnail.

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const media = @import("../platform/api.zig").record;
const env_mod = @import("../app/env.zig");
const config = @import("../app/config.zig");
const keep = @import("../app/keep.zig");
const sys = @import("../platform/api.zig").sys;
const window = @import("../platform/api.zig").window;
const settings_mod = @import("settings.zig");
const session = @import("session.zig");
const region = @import("region.zig");
const ctlsock = @import("ctlsock.zig");
const control_mod = @import("../ui/recui/control.zig");
const cli = @import("cli.zig");
const Env = env_mod.Env;

/// Record `a.area` (or the monitor for --full); `picked` is the area the
/// picker returned, when it ran.
pub fn run(gpa: std.mem.Allocator, env: Env, a: cli.Args, set: settings_mod.Settings, picked: ?region.Rect) !void {
    var bus = try desktop.connectBrief(gpa, env);
    defer bus.deinit();
    var cfg = config.load(gpa, env.home);
    var server = ctlsock.Server.listen(env.runtime_dir, env.session.tag()) catch |err| {
        std.log.warn("record: another recording is under way ({t})", .{err});
        return err;
    };
    defer server.close();
    const area = picked orelse a.area orelse try fullArea(gpa, env);
    var ctl: ?control_mod.Control = if (a.control) control_mod.Control.open(gpa, env, &bus, area) catch |err| blk: {
        std.log.warn("record: no floating control ({t})", .{err});
        break :blk null;
    } else null;
    defer if (ctl) |*c| c.close();
    if (set.countdown > 0) {
        const go = if (ctl) |*c| c.countdown(set.countdown, &server) else sleepCountdown(set.countdown);
        if (!go) {
            std.log.info("record: cancelled during the countdown", .{});
            return;
        }
    }
    // on GNOME the top bar has the stop button: no control in the picture
    if (ctl) |*c| if (c.covers_monitor and media.shellHasControls(gpa, &bus)) {
        c.close();
        ctl = null;
    };
    var rec = switch (session.Recording.begin(gpa, env, &bus, &cfg, set, .{ .area = area, .out = a.out })) {
        .ok => |r| r,
        .cancelled => {
            std.log.info("record: cancelled", .{});
            return;
        },
        .failed => |e| {
            std.log.warn("record: could not start: {t}", .{e});
            return e;
        },
    };
    media.watchStop(&bus) catch {};
    const outcome = loop(&rec, &bus, &server, if (ctl) |*c| c else null, a.seconds);
    if (ctl) |*c| c.close();
    ctl = null;
    switch (outcome) {
        .discard => rec.discard(),
        .stop => {
            const kept = rec.finish(&cfg) catch |err| {
                std.log.warn("record: could not finish: {t}", .{err});
                return err;
            };
            if (kept) |k| if (cfg.showsThumbnail(true)) showThumbnail(env, &k);
        },
    }
}

const Outcome = enum { stop, discard };

fn loop(rec: *session.Recording, bus: *desktop.Session, server: *ctlsock.Server, ctl: ?*control_mod.Control, seconds: ?u32) Outcome {
    var announced = false;
    while (true) {
        if (rec.engine.failed()) |err| {
            std.log.warn("record: the recording failed ({t})", .{err});
            return .stop;
        }
        if (!announced and rec.engine.started()) {
            announced = true;
            std.log.info("record: recording", .{});
        }
        const elapsed = rec.engine.elapsedMs();
        if (seconds) |s| if (elapsed >= @as(i64, s) * 1000) return .stop;
        if (ctl) |c| if (c.step(rec.engine)) |o| return switch (o) {
            .stop => .stop,
            .discard => .discard,
        };
        if (pollCommands(rec, server)) |o| return o;
        if (pollBus(rec, bus)) return .stop;
        waitAny(bus, server, ctl);
    }
}

fn pollCommands(rec: *session.Recording, server: *ctlsock.Server) ?Outcome {
    var conn: sys.fd_t = -1;
    const cmd = server.poll(&conn) orelse return null;
    var buf: [64]u8 = undefined;
    const status = std.fmt.bufPrint(&buf, "ok {s} {d}", .{ if (rec.engine.paused()) "paused" else "recording", rec.engine.elapsedMs() }) catch "ok";
    ctlsock.Server.reply(conn, status);
    switch (cmd) {
        .stop => return .stop,
        .discard => return .discard,
        .pause => rec.engine.pause(),
        .resume_ => rec.engine.unpause(),
        .status => {},
    }
    return null;
}

/// The GNOME top bar's stop button and the record shortcut.
fn pollBus(rec: *session.Recording, bus: *desktop.Session) bool {
    return media.pollStop(bus, rec.gpa);
}

fn waitAny(bus: *desktop.Session, server: *ctlsock.Server, ctl: ?*control_mod.Control) void {
    var fds = [_]sys.pollfd{
        .{ .fd = desktop.pollFd(bus), .events = sys.POLL.IN, .revents = 0 },
        .{ .fd = server.fd, .events = sys.POLL.IN, .revents = 0 },
        .{ .fd = if (ctl) |c| c.fd() else -1, .events = sys.POLL.IN, .revents = 0 },
    };
    if (desktop.hasPending(bus)) return;
    const timeout: i32 = if (ctl) |c| c.waitMs() else 100;
    _ = sys.poll(&fds, timeout) catch {};
}

fn sleepCountdown(seconds: u32) bool {
    sys.sleepMs(@as(u64, seconds) * 1000);
    return true;
}

/// The whole monitor: the first one the compositor lists (the picker
/// knows better; this is for `--full` from a script).
fn fullArea(gpa: std.mem.Allocator, env: Env) !region.Rect {
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    for (win.outputList()) |o| {
        if (o.id == 0) continue;
        const r = o.logicalRect();
        if (r.w > 0 and r.h > 0) return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }
    return error.NoMonitor;
}

/// The floating thumbnail of the recording (`shotlet quick-video`).
fn showThumbnail(env: Env, k: *const keep.Kept) void {
    var rb: [1100]u8 = undefined;
    var ib: [40]u8 = undefined;
    const root = std.fmt.bufPrintSentinel(&rb, "{s}", .{k.root()}, 0) catch return;
    const id = std.fmt.bufPrintSentinel(&ib, "{s}", .{k.id.slice()}, 0) catch return;
    keep.spawnSelf(env, &.{ "quick-video", root.ptr, id.ptr });
}
