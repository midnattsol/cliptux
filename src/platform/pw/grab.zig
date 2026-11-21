//! Connection to the PipeWire daemon over the portal fd, and the one-shot
//! frame grab: one capture stream per node, run concurrently.

const std = @import("std");
const sys = @import("../sys.zig");
const abi = @import("abi.zig");
const pod = @import("pod.zig");
const capture = @import("capture.zig");
const pw = @import("../pw.zig");

const Ctx = capture.Ctx;
const Frame = capture.Frame;

/// Pre-established PipeWire connection (handshake done, no stream yet).
pub const Pre = struct {
    loop: ?*anyopaque = null,
    context: ?*anyopaque = null,
    core: ?*anyopaque = null,
};

/// Connect to the PipeWire daemon over the portal fd. Always takes
/// ownership of fd: it is either handed to PipeWire or closed here, on
/// every path, so callers never close it themselves.
/// Safe to run on a separate thread (no shared allocator use).
pub fn preconnect(fd: i32) !Pre {
    if (!pw.available()) {
        _ = std.os.linux.close(fd);
        return error.PipeWireUnavailable;
    }
    var pre = Pre{};
    pre.loop = pw.api.thread_loop_new("shotlet-pw", null) orelse {
        _ = std.os.linux.close(fd);
        return error.PwLoop;
    };
    if (pw.api.thread_loop_start(pre.loop) < 0) {
        pw.api.thread_loop_destroy(pre.loop);
        _ = std.os.linux.close(fd);
        return error.PwLoop;
    }
    pw.api.thread_loop_lock(pre.loop);
    connectCore(&pre, fd);
    pw.api.thread_loop_unlock(pre.loop);
    if (pre.core == null) {
        teardown(&pre, &.{});
        return error.PwConnect;
    }
    return pre;
}

/// Create the context and connect its core over fd (loop locked). Leaves
/// pre.core null on failure, with fd closed exactly once.
fn connectCore(pre: *Pre, fd: i32) void {
    pre.context = pw.api.context_new(pw.api.thread_loop_get_loop(pre.loop), null, 0);
    if (pre.context == null) {
        _ = std.os.linux.close(fd);
        return;
    }
    // pw_context_connect_fd closes the fd on some failure paths and not
    // on others (e.g. when allocating the core fails). Remember what the
    // fd refers to, and close it ourselves only if it still refers to
    // that same socket afterwards.
    const id_before = sys.fileId(fd);
    pre.core = pw.api.context_connect_fd(pre.context, fd, null, 0);
    if (pre.core == null) {
        if (id_before) |before| {
            if (sys.fileId(fd)) |after| {
                if (std.meta.eql(before, after)) _ = std.os.linux.close(fd);
            }
        }
    }
}

/// Discard a pre-established connection without grabbing.
pub fn discard(pre: *Pre) void {
    teardown(pre, &.{});
}

pub fn teardown(pre: *Pre, streams: []const ?*anyopaque) void {
    if (pre.loop != null) pw.api.thread_loop_stop(pre.loop);
    for (streams) |s| if (s != null) pw.api.stream_destroy(s);
    if (pre.core != null) _ = pw.api.core_disconnect(pre.core);
    if (pre.context != null) pw.api.context_destroy(pre.context);
    if (pre.loop != null) pw.api.thread_loop_destroy(pre.loop);
    pre.* = .{};
}

pub const max_nodes = 16;

/// Grab one frame from each node using a pre-established connection;
/// consumes it. Streams run concurrently so N monitors cost about as much
/// as one. On success, frames[i] belongs to node_ids[i]; on error no frames
/// are returned.
pub fn grabNodes(pre: *Pre, node_ids: []const u32, frames: []Frame, timeout_ms: u32) !void {
    std.debug.assert(frames.len >= node_ids.len);
    if (node_ids.len == 0 or node_ids.len > max_nodes) {
        teardown(pre, &.{});
        return error.BadNodeCount;
    }
    const n = node_ids.len;
    var ctxs: [max_nodes]Ctx = @splat(.{});
    var hooks: [max_nodes]abi.SpaHook = @splat(.{});
    var streams: [max_nodes]?*anyopaque = @splat(null);

    var pod_buf: [256]u8 align(8) = undefined;
    const format = pod.buildFormatPod(&pod_buf) orelse unreachable;
    const params = [_][*]const u8{format.ptr};

    pw.api.thread_loop_lock(pre.loop);
    const connect_ok = connectStreams(pre, node_ids, &params, ctxs[0..n], hooks[0..n], streams[0..n]);
    if (connect_ok) waitForFrames(pre, ctxs[0..n], timeout_ms);
    pw.api.thread_loop_unlock(pre.loop);
    teardown(pre, streams[0..n]);
    return collectFrames(ctxs[0..n], frames, connect_ok);
}

/// Create and connect one capture stream per node (loop locked). False
/// as soon as one cannot be created or connected.
fn connectStreams(
    pre: *Pre,
    node_ids: []const u32,
    params: *const [1][*]const u8,
    ctxs: []Ctx,
    hooks: []abi.SpaHook,
    streams: []?*anyopaque,
) bool {
    for (node_ids, 0..) |node, i| {
        ctxs[i].loop = pre.loop;
        // PW_KEY_TARGET_OBJECT would be the modern way, but it expects an
        // object serial or name; the portal hands out node ids, which only
        // target_id addresses without relying on session-manager fallbacks
        streams[i] = pw.api.stream_new(pre.core, "shotlet-capture", null);
        if (streams[i] == null) return false;
        ctxs[i].stream = streams[i];
        pw.api.stream_add_listener(streams[i], &hooks[i], &capture.events, &ctxs[i]);
        if (pw.api.stream_connect(
            streams[i],
            abi.PW_DIRECTION_INPUT,
            node,
            abi.PW_STREAM_FLAG_AUTOCONNECT | abi.PW_STREAM_FLAG_MAP_BUFFERS,
            params,
            1,
        ) < 0) return false;
    }
    return true;
}

/// Wait (loop locked) until every stream has a frame, one failed, or the
/// deadline passes.
fn waitForFrames(pre: *Pre, ctxs: []const Ctx, timeout_ms: u32) void {
    const deadline = sys.monoMs() + timeout_ms;
    while (sys.monoMs() < deadline) {
        var all_done = true;
        var any_failed = false;
        for (ctxs) |*c| {
            all_done = all_done and c.done;
            any_failed = any_failed or c.failed;
        }
        if (all_done or any_failed) break;
        _ = pw.api.thread_loop_timed_wait(pre.loop, 1);
    }
}

/// Hand every captured frame to `frames`, or free them all and fail.
fn collectFrames(ctxs: []Ctx, frames: []Frame, connect_ok: bool) !void {
    var ok = connect_ok;
    for (ctxs) |*c| ok = ok and c.done and c.pixels != null;
    if (!ok) {
        freePixels(ctxs);
        return if (connect_ok) error.NoFrame else error.PwConnect;
    }
    var n_done: usize = 0;
    errdefer for (frames[0..n_done]) |*f| f.deinit();
    for (ctxs, 0..) |*c, i| {
        frames[i] = capture.finishFrame(c) catch |err| {
            freePixels(ctxs[i + 1 ..]);
            return err;
        };
        n_done += 1;
    }
}

fn freePixels(ctxs: []const Ctx) void {
    for (ctxs) |*c| if (c.pixels) |p| std.heap.page_allocator.free(p);
}

/// Grab one frame using a pre-established connection; consumes it.
pub fn grabPre(pre: *Pre, node_id: u32, timeout_sec: u32) !Frame {
    var frame: [1]Frame = undefined;
    try grabNodes(pre, &.{node_id}, &frame, timeout_sec * 1000);
    return frame[0];
}

/// Grab a single frame from the portal-provided PipeWire stream.
/// Takes ownership of `fd`. Blocks up to `timeout_sec`.
pub fn grabFrame(fd: i32, node_id: u32, timeout_sec: u32) !Frame {
    var pre = try preconnect(fd);
    return grabPre(&pre, node_id, timeout_sec);
}

/// Grab one frame from each node over the portal fd (consumes fd).
pub fn grabFrames(fd: i32, node_ids: []const u32, frames: []Frame, timeout_ms: u32) !void {
    var pre = try preconnect(fd);
    return grabNodes(&pre, node_ids, frames, timeout_ms);
}
