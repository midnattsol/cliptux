//! Capture through the ScreenCast portal and PipeWire: one frame from
//! every monitor, stitched.

const std = @import("std");
const capture = @import("../capture.zig");
const config = @import("../config.zig");
const dbus = @import("../../platform/linux/dbus.zig");
const portal = @import("../../platform/linux/portal.zig");
const pw = @import("../../platform/linux/pw.zig");
const Env = @import("../env.zig").Env;
const nowMs = @import("../shot.zig").nowMs;

/// ScreenCast + PipeWire: one frame from every monitor, stitched. Errors
/// after the portal said yes count as "unavailable" so the caller can fall
/// back to the Screenshot portal.
pub fn screencast(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config) portal.Result(capture.Capture) {
    return screencastInner(gpa, env, conn, cfg) catch |err| {
        std.log.info("screencast capture failed ({t})", .{err});
        return .unavailable;
    };
}

fn screencastInner(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config) !portal.Result(capture.Capture) {
    const Res = portal.Result(capture.Capture);
    const ts0 = nowMs();

    const session_path = switch (try portal.scCreateSession(gpa, conn)) {
        .granted => |p| p,
        else => |o| return passOn(Res, o),
    };
    defer gpa.free(session_path);
    // the session must be closed on every path, and as early as possible:
    // GNOME's screen-sharing indicator must only blink during the grab
    var open = true;
    defer if (open) portal.closeSession(gpa, conn, session_path);

    var started = switch (try portal.scSelectAndStart(gpa, conn, session_path, cfg.scToken())) {
        .granted => |st| st,
        else => |o| return passOn(Res, o),
    };
    defer started.deinit(gpa);
    if (started.restore_token) |t| rememberToken(gpa, env, cfg, t);

    for (started.streams) |st| std.log.debug("screencast stream: node {d} position {?any} size {?any}", .{ st.node_id, st.position, st.size });
    const fd = try portal.scOpenRemote(gpa, conn, session_path);
    const streams = started.streams[0..@min(started.streams.len, pw.max_nodes)];
    var node_ids: [pw.max_nodes]u32 = undefined;
    for (streams, 0..) |st, i| node_ids[i] = st.node_id;

    const ts1 = nowMs();
    var frames: [pw.max_nodes]pw.Frame = undefined;
    try pw.grabFrames(fd, node_ids[0..streams.len], frames[0..streams.len], 5000);
    defer for (frames[0..streams.len]) |*f| f.deinit();
    const ts2 = nowMs();
    portal.closeSession(gpa, conn, session_path);
    open = false;

    const cap = try stitchStreams(gpa, streams, frames[0..streams.len]);
    std.log.info("  capture detail: monitors={d} session={d} grab={d} close+stitch={d}ms", .{
        streams.len, ts1 - ts0, ts2 - ts1, nowMs() - ts2,
    });
    return .{ .granted = cap };
}

/// Keeps a new restore token so the next capture skips the dialog.
fn rememberToken(gpa: std.mem.Allocator, env: Env, cfg: *config.Config, t: []const u8) void {
    cfg.setScToken(t);
    // only this key: never write back a stale snapshot of the rest
    config.saveScreencastToken(gpa, env.home, t) catch |err|
        std.log.warn("could not store the screencast token: {t}", .{err});
}

/// Stitches one grabbed frame per stream, placed where the portal says
/// each monitor is (when it says).
pub fn stitchStreams(gpa: std.mem.Allocator, streams: []const portal.Stream, frames: []const pw.Frame) !capture.Capture {
    var parts: [pw.max_nodes]capture.Part = undefined;
    for (streams, frames, 0..) |st, f, i| {
        parts[i] = .{ .pixels = f.pixels, .width = f.width, .height = f.height };
        if (st.position != null and st.size != null) {
            parts[i].logical = .{
                .x = st.position.?[0],
                .y = st.position.?[1],
                .w = @intCast(st.size.?[0]),
                .h = @intCast(st.size.?[1]),
            };
        }
    }
    return capture.stitch(gpa, parts[0..streams.len]);
}

fn passOn(comptime R: type, o: anytype) R {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}
