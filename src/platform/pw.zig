//! Minimal PipeWire screen-capture client. Loads libpipewire-0.3 at runtime
//! (dlopen) so shotlet keeps building with zero dependencies and falls back
//! to the Screenshot portal when PipeWire is unavailable. Uses the stable
//! pw_stream C API; the SPA format pod is built by hand.

const std = @import("std");
const sys = @import("sys.zig");

// --- SPA / PipeWire ABI constants (stable since 0.3) ---
const SPA_TYPE_Id: u32 = 3;
const SPA_TYPE_Int: u32 = 4;
const SPA_TYPE_Object: u32 = 15;
const SPA_TYPE_Choice: u32 = 19;
const SPA_TYPE_Rectangle: u32 = 10;
const SPA_TYPE_Fraction: u32 = 11;

const SPA_TYPE_OBJECT_Format: u32 = 0x40003;
const SPA_PARAM_EnumFormat: u32 = 3;
const SPA_PARAM_Format: u32 = 4;
const SPA_PARAM_Meta: u32 = 6;
const SPA_TYPE_OBJECT_ParamMeta: u32 = 0x40005;
const SPA_PARAM_META_type: u32 = 1;
const SPA_PARAM_META_size: u32 = 2;
const SPA_META_VideoCrop: u32 = 2;

const SPA_CHUNK_FLAG_CORRUPTED: i32 = 1 << 0;

const SPA_FORMAT_mediaType: u32 = 1;
const SPA_FORMAT_mediaSubtype: u32 = 2;
const SPA_FORMAT_VIDEO_format: u32 = 0x20001;
const SPA_FORMAT_VIDEO_size: u32 = 0x20003;
const SPA_FORMAT_VIDEO_framerate: u32 = 0x20004;

const SPA_MEDIA_TYPE_video: u32 = 2;
const SPA_MEDIA_SUBTYPE_raw: u32 = 1;

const SPA_CHOICE_Range: u32 = 1;
const SPA_CHOICE_Enum: u32 = 3;

pub const VideoFormat = enum(u32) {
    RGBx = 7,
    BGRx = 8,
    RGBA = 11,
    BGRA = 12,
    _,
};

const PW_DIRECTION_INPUT: c_uint = 0;
const PW_STREAM_FLAG_AUTOCONNECT: c_uint = 1 << 0;
const PW_STREAM_FLAG_MAP_BUFFERS: c_uint = 1 << 2;

const PW_STREAM_STATE_ERROR: c_int = -1;

// --- C struct mirrors (stable ABI) ---
const SpaChunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

const SpaData = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*SpaChunk,
};

const SpaMeta = extern struct {
    type: u32,
    size: u32,
    data: ?*anyopaque,
};

/// spa_meta_region: a spa_region (position + size)
const SpaMetaRegion = extern struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

const SpaBuffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?[*]SpaMeta,
    datas: ?[*]SpaData,
};

const PwBuffer = extern struct {
    buffer: ?*SpaBuffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

const SpaHook = extern struct {
    link_prev: ?*anyopaque = null,
    link_next: ?*anyopaque = null,
    funcs: ?*const anyopaque = null,
    data: ?*anyopaque = null,
    removed: ?*anyopaque = null,
    priv: ?*anyopaque = null,
};

const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

// --- dynamic API surface ---
const Api = struct {
    init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    thread_loop_new: *const fn ([*:0]const u8, ?*const anyopaque) callconv(.c) ?*anyopaque,
    thread_loop_destroy: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_start: *const fn (?*anyopaque) callconv(.c) c_int,
    thread_loop_stop: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_lock: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_unlock: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_signal: *const fn (?*anyopaque, bool) callconv(.c) void,
    thread_loop_timed_wait: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    thread_loop_get_loop: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    context_new: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    context_destroy: *const fn (?*anyopaque) callconv(.c) void,
    context_connect_fd: *const fn (?*anyopaque, c_int, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    core_disconnect: *const fn (?*anyopaque) callconv(.c) c_int,
    stream_new: *const fn (?*anyopaque, [*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque,
    stream_destroy: *const fn (?*anyopaque) callconv(.c) void,
    stream_disconnect: *const fn (?*anyopaque) callconv(.c) c_int,
    stream_add_listener: *const fn (?*anyopaque, *SpaHook, *const StreamEvents, ?*anyopaque) callconv(.c) void,
    stream_connect: *const fn (?*anyopaque, c_uint, u32, c_uint, [*]const [*]const u8, u32) callconv(.c) c_int,
    stream_dequeue_buffer: *const fn (?*anyopaque) callconv(.c) ?*PwBuffer,
    stream_queue_buffer: *const fn (?*anyopaque, *PwBuffer) callconv(.c) c_int,
    stream_update_params: *const fn (?*anyopaque, [*]const [*]const u8, u32) callconv(.c) c_int,
};

var lib: ?std.DynLib = null;
var api: Api = undefined;
var initialized = false;

/// Try to load libpipewire. Returns false (and logs once) when unavailable.
pub fn available() bool {
    if (initialized) return lib != null;
    initialized = true;
    lib = std.DynLib.open("libpipewire-0.3.so.0") catch {
        std.log.info("libpipewire not found; using the Screenshot portal", .{});
        return false;
    };
    api = loadApi(&lib.?) orelse {
        std.log.warn("libpipewire is missing expected symbols; using the Screenshot portal", .{});
        lib.?.close();
        lib = null;
        return false;
    };
    api.init(null, null);
    return true;
}

fn loadApi(l: *std.DynLib) ?Api {
    var out: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |fld_name, fld_type| {
        const sym_name = "pw_" ++ fld_name;
        // DynLib.lookup requires a null-terminated name
        const ptr = l.lookup(fld_type, sym_name) orelse return null;
        @field(out, fld_name) = ptr;
    }
    return out;
}

// --- pods ---

/// Little-endian u32 writer for hand-built SPA pods; refuses to overflow.
const PodWriter = struct {
    buf: []u8,
    pos: usize = 0,
    overflow: bool = false,

    fn put(self: *PodWriter, v: u32) void {
        if (self.pos + 4 > self.buf.len) {
            self.overflow = true;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    /// Patch the leading pod size and return the pod, or null on overflow.
    fn finish(self: *PodWriter) ?[]const u8 {
        if (self.overflow or self.pos < 8) return null;
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.pos - 8), .little);
        return self.buf[0..self.pos];
    }
};

/// Build the EnumFormat pod: raw video in BGRA/BGRx/RGBA/RGBx at any size.
fn buildFormatPod(buf: []u8) ?[]const u8 {
    var w = PodWriter{ .buf = buf };
    w.put(0); // body size, patched by finish
    w.put(SPA_TYPE_Object);
    w.put(SPA_TYPE_OBJECT_Format);
    w.put(SPA_PARAM_EnumFormat);

    // mediaType = video
    w.put(SPA_FORMAT_mediaType);
    w.put(0);
    w.put(4);
    w.put(SPA_TYPE_Id);
    w.put(SPA_MEDIA_TYPE_video);
    w.put(0); // pad

    // mediaSubtype = raw
    w.put(SPA_FORMAT_mediaSubtype);
    w.put(0);
    w.put(4);
    w.put(SPA_TYPE_Id);
    w.put(SPA_MEDIA_SUBTYPE_raw);
    w.put(0); // pad

    // format: enum choice over the 32-bit formats we can swizzle
    w.put(SPA_FORMAT_VIDEO_format);
    w.put(0);
    w.put(36); // choice body: 8 meta + 8 child + 5*4 values
    w.put(SPA_TYPE_Choice);
    w.put(SPA_CHOICE_Enum);
    w.put(0);
    w.put(4); // child size
    w.put(SPA_TYPE_Id);
    w.put(@backingInt(VideoFormat.BGRA)); // default
    w.put(@backingInt(VideoFormat.BGRA));
    w.put(@backingInt(VideoFormat.BGRx));
    w.put(@backingInt(VideoFormat.RGBA));
    w.put(@backingInt(VideoFormat.RGBx));
    w.put(0); // pad to 8

    // size: range 1x1 .. 16384x16384
    w.put(SPA_FORMAT_VIDEO_size);
    w.put(0);
    w.put(40); // 8 meta + 8 child + 3*8 rect values
    w.put(SPA_TYPE_Choice);
    w.put(SPA_CHOICE_Range);
    w.put(0);
    w.put(8);
    w.put(SPA_TYPE_Rectangle);
    w.put(1920);
    w.put(1080);
    w.put(1);
    w.put(1);
    w.put(16384);
    w.put(16384);

    // framerate: range 0/1 .. 1000/1 (variable)
    w.put(SPA_FORMAT_VIDEO_framerate);
    w.put(0);
    w.put(40);
    w.put(SPA_TYPE_Choice);
    w.put(SPA_CHOICE_Range);
    w.put(0);
    w.put(8);
    w.put(SPA_TYPE_Fraction);
    w.put(25);
    w.put(1);
    w.put(0);
    w.put(1);
    w.put(1000);
    w.put(1);

    return w.finish();
}

/// Build a Meta param asking the producer to attach VideoCrop regions.
fn buildCropMetaPod(buf: []u8) ?[]const u8 {
    var w = PodWriter{ .buf = buf };
    w.put(0);
    w.put(SPA_TYPE_Object);
    w.put(SPA_TYPE_OBJECT_ParamMeta);
    w.put(SPA_PARAM_Meta);

    w.put(SPA_PARAM_META_type);
    w.put(0);
    w.put(4);
    w.put(SPA_TYPE_Id);
    w.put(SPA_META_VideoCrop);
    w.put(0); // pad

    w.put(SPA_PARAM_META_size);
    w.put(0);
    w.put(4);
    w.put(SPA_TYPE_Int);
    w.put(@sizeOf(SpaMetaRegion));
    w.put(0); // pad

    return w.finish();
}

/// Walk an object pod and call `visit(key, value_type, value_bytes)` for
/// each property, unwrapping fixated Choice values. Bounds-checked.
fn forEachProp(pod: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32, u32, []const u8) void) void {
    if (pod.len < 16) return;
    const body_size = std.mem.readInt(u32, pod[0..4], .little);
    const pod_type = std.mem.readInt(u32, pod[4..8], .little);
    if (pod_type != SPA_TYPE_Object or body_size < 8) return;
    const end: usize = @min(pod.len, 8 + @as(usize, body_size));
    var pos: usize = 16; // skip pod header + object type/id
    while (pos + 16 <= end) {
        const key = std.mem.readInt(u32, pod[pos..][0..4], .little);
        const vsize: usize = std.mem.readInt(u32, pod[pos + 8 ..][0..4], .little);
        const vtype = std.mem.readInt(u32, pod[pos + 12 ..][0..4], .little);
        const vdata = pos + 16;
        if (vsize > end - vdata) break;
        // values may arrive wrapped in a Choice pod (None = fixated);
        // the payload then starts after choice meta (8) + child header (8)
        var val = pod[vdata..][0..vsize];
        var vt = vtype;
        if (vtype == SPA_TYPE_Choice and vsize >= 20) {
            vt = std.mem.readInt(u32, pod[vdata + 12 ..][0..4], .little); // child type
            val = pod[vdata + 16 .. vdata + vsize];
        }
        visit(ctx, key, vt, val);
        pos = vdata + std.mem.alignForward(usize, vsize, 8);
    }
}

// --- frame grab ---

pub const Frame = struct {
    width: u32,
    height: u32,
    /// 0xAARRGGBB; allocated with page_allocator
    pixels: []u32,

    pub fn deinit(self: *Frame) void {
        std.heap.page_allocator.free(self.pixels);
        self.* = undefined;
    }
};

const Ctx = struct {
    loop: ?*anyopaque = null,
    stream: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    /// tight 4-byte pixels of the (cropped) frame; page_allocator
    pixels: ?[]u32 = null,
    out_w: u32 = 0,
    out_h: u32 = 0,
    done: bool = false,
    failed: bool = false,
};

fn visitFormat(ctx: *Ctx, key: u32, vt: u32, val: []const u8) void {
    if (key == SPA_FORMAT_VIDEO_format and vt == SPA_TYPE_Id and val.len >= 4) {
        ctx.format = std.mem.readInt(u32, val[0..4], .little);
    } else if (key == SPA_FORMAT_VIDEO_size and vt == SPA_TYPE_Rectangle and val.len >= 8) {
        ctx.width = std.mem.readInt(u32, val[0..4], .little);
        ctx.height = std.mem.readInt(u32, val[4..8], .little);
    }
}

fn onParamChanged(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    std.log.debug("pw param_changed id={d} param={}", .{ id, param != null });
    if (id != SPA_PARAM_Format or param == null) return;
    // parse the negotiated format object pod
    const head: [*]const u8 = @ptrCast(param.?);
    const body_size = std.mem.readInt(u32, head[0..4], .little);
    if (body_size > 64 * 1024) return;
    forEachProp(head[0 .. 8 + @as(usize, body_size)], ctx, visitFormat);

    // ask for crop regions: some producers send a larger buffer and mark
    // the valid area with SPA_META_VideoCrop
    var meta_buf: [96]u8 align(8) = undefined;
    if (buildCropMetaPod(&meta_buf)) |meta| {
        const params = [_][*]const u8{meta.ptr};
        _ = api.stream_update_params(ctx.stream, &params, 1);
    }
}

fn onStateChanged(data: ?*anyopaque, old: c_int, new: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    std.log.debug("pw state {d} -> {d}", .{ old, new });
    if (new == PW_STREAM_STATE_ERROR) {
        std.log.warn("pipewire stream error: {s}", .{if (msg) |m| std.mem.span(m) else "?"});
        ctx.failed = true;
        api.thread_loop_signal(ctx.loop, false);
    }
}

/// The valid area of a buffer: its VideoCrop region when the producer
/// attached a sensible one, else the whole negotiated frame.
fn cropRegion(sb: *const SpaBuffer, width: u32, height: u32) SpaMetaRegion {
    const full = SpaMetaRegion{ .x = 0, .y = 0, .width = width, .height = height };
    const metas = sb.metas orelse return full;
    for (metas[0..sb.n_metas]) |m| {
        if (m.type != SPA_META_VideoCrop or m.size < @sizeOf(SpaMetaRegion)) continue;
        const r: *const SpaMetaRegion = @ptrCast(@alignCast(m.data orelse continue));
        if (r.width == 0 or r.height == 0 or r.x < 0 or r.y < 0) return full;
        const x: u32 = @intCast(r.x);
        const y: u32 = @intCast(r.y);
        if (x >= width or y >= height or r.width > width - x or r.height > height - y) return full;
        return r.*;
    }
    return full;
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    const stream = ctx.stream orelse return;
    const b = api.stream_dequeue_buffer(stream) orelse return;
    defer _ = api.stream_queue_buffer(stream, b);
    if (ctx.done or ctx.failed) return;

    const sb = b.buffer orelse return;
    if (sb.n_datas < 1) return;
    const d = sb.datas.?[0];
    const chunk = d.chunk orelse return;
    // an empty or corrupted buffer is skipped; the next one will do
    if (chunk.size == 0 or (chunk.flags & SPA_CHUNK_FLAG_CORRUPTED) != 0) {
        std.log.debug("pw: skipping empty/corrupted buffer", .{});
        return;
    }
    const src_base: [*]const u8 = @ptrCast(d.data orelse return);
    if (ctx.width == 0 or ctx.height == 0) return;
    const stride: usize = if (chunk.stride > 0) @intCast(chunk.stride) else ctx.width * 4;
    if (stride < @as(usize, ctx.width) * 4) return;
    const crop = cropRegion(sb, ctx.width, ctx.height);
    // never read past the mapped buffer or the chunk, whatever they claim
    const avail = @min(@as(usize, d.maxsize), @as(usize, chunk.offset) + chunk.size);
    const first = @as(usize, chunk.offset) + @as(usize, @intCast(crop.y)) * stride + @as(usize, @intCast(crop.x)) * 4;
    const needed = first + (@as(usize, crop.height) - 1) * stride + @as(usize, crop.width) * 4;
    if (needed > avail) {
        std.log.debug("pw: buffer smaller than the frame ({d} < {d}); skipping", .{ avail, needed });
        return;
    }

    const n: usize = @as(usize, crop.width) * crop.height;
    const pixels = std.heap.page_allocator.alloc(u32, n) catch {
        ctx.failed = true;
        api.thread_loop_signal(ctx.loop, false);
        return;
    };
    const dst_bytes = std.mem.sliceAsBytes(pixels);
    const row_bytes = @as(usize, crop.width) * 4;
    var y: usize = 0;
    while (y < crop.height) : (y += 1) {
        const src_row = src_base[first + y * stride ..][0..row_bytes];
        @memcpy(dst_bytes[y * row_bytes ..][0..row_bytes], src_row);
    }
    ctx.pixels = pixels;
    ctx.out_w = crop.width;
    ctx.out_h = crop.height;
    ctx.done = true;
    api.thread_loop_signal(ctx.loop, false);
}

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
    if (!available()) {
        _ = std.os.linux.close(fd);
        return error.PipeWireUnavailable;
    }
    var pre = Pre{};
    pre.loop = api.thread_loop_new("shotlet-pw", null) orelse {
        _ = std.os.linux.close(fd);
        return error.PwLoop;
    };
    if (api.thread_loop_start(pre.loop) < 0) {
        api.thread_loop_destroy(pre.loop);
        _ = std.os.linux.close(fd);
        return error.PwLoop;
    }
    api.thread_loop_lock(pre.loop);
    pre.context = api.context_new(api.thread_loop_get_loop(pre.loop), null, 0);
    if (pre.context != null) {
        // pw_context_connect_fd closes the fd on some failure paths and not
        // on others (e.g. when allocating the core fails). Remember what the
        // fd refers to, and close it ourselves only if it still refers to
        // that same socket afterwards.
        const id_before = sys.fileId(fd);
        pre.core = api.context_connect_fd(pre.context, fd, null, 0);
        if (pre.core == null) {
            if (id_before) |before| {
                if (sys.fileId(fd)) |after| {
                    if (std.meta.eql(before, after)) _ = std.os.linux.close(fd);
                }
            }
        }
    } else {
        _ = std.os.linux.close(fd);
    }
    api.thread_loop_unlock(pre.loop);
    if (pre.core == null) {
        teardown(&pre, &.{});
        return error.PwConnect;
    }
    return pre;
}

/// Discard a pre-established connection without grabbing.
pub fn discard(pre: *Pre) void {
    teardown(pre, &.{});
}

fn teardown(pre: *Pre, streams: []const ?*anyopaque) void {
    if (pre.loop != null) api.thread_loop_stop(pre.loop);
    for (streams) |s| if (s != null) api.stream_destroy(s);
    if (pre.core != null) _ = api.core_disconnect(pre.core);
    if (pre.context != null) api.context_destroy(pre.context);
    if (pre.loop != null) api.thread_loop_destroy(pre.loop);
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
    var ctxs: [max_nodes]Ctx = @splat(.{});
    var hooks: [max_nodes]SpaHook = @splat(.{});
    var streams: [max_nodes]?*anyopaque = @splat(null);
    const events = StreamEvents{
        .state_changed = onStateChanged,
        .param_changed = onParamChanged,
        .process = onProcess,
    };

    var pod_buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&pod_buf) orelse unreachable;
    const params = [_][*]const u8{pod.ptr};

    api.thread_loop_lock(pre.loop);
    var connect_ok = true;
    for (node_ids, 0..) |node, i| {
        ctxs[i].loop = pre.loop;
        // PW_KEY_TARGET_OBJECT would be the modern way, but it expects an
        // object serial or name; the portal hands out node ids, which only
        // target_id addresses without relying on session-manager fallbacks
        streams[i] = api.stream_new(pre.core, "shotlet-capture", null);
        if (streams[i] == null) {
            connect_ok = false;
            break;
        }
        ctxs[i].stream = streams[i];
        api.stream_add_listener(streams[i], &hooks[i], &events, &ctxs[i]);
        if (api.stream_connect(
            streams[i],
            PW_DIRECTION_INPUT,
            node,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
            &params,
            1,
        ) < 0) {
            connect_ok = false;
            break;
        }
    }
    if (connect_ok) {
        const deadline = sys.monoMs() + timeout_ms;
        while (sys.monoMs() < deadline) {
            var all_done = true;
            var any_failed = false;
            for (ctxs[0..node_ids.len]) |*c| {
                all_done = all_done and c.done;
                any_failed = any_failed or c.failed;
            }
            if (all_done or any_failed) break;
            _ = api.thread_loop_timed_wait(pre.loop, 1);
        }
    }
    api.thread_loop_unlock(pre.loop);
    teardown(pre, streams[0..node_ids.len]);

    var ok = connect_ok;
    for (ctxs[0..node_ids.len]) |*c| ok = ok and c.done and c.pixels != null;
    if (!ok) {
        for (ctxs[0..node_ids.len]) |*c| if (c.pixels) |p| std.heap.page_allocator.free(p);
        return if (connect_ok) error.NoFrame else error.PwConnect;
    }
    var n_done: usize = 0;
    errdefer for (frames[0..n_done]) |*f| f.deinit();
    for (ctxs[0..node_ids.len], 0..) |*c, i| {
        frames[i] = finishFrame(c) catch |err| {
            for (ctxs[i + 1 .. node_ids.len]) |*rest| if (rest.pixels) |p| std.heap.page_allocator.free(p);
            return err;
        };
        n_done += 1;
    }
}

/// Grab one frame using a pre-established connection; consumes it.
pub fn grabPre(pre: *Pre, node_id: u32, timeout_sec: u32) !Frame {
    var frame: [1]Frame = undefined;
    try grabNodes(pre, &.{node_id}, &frame, timeout_sec * 1000);
    return frame[0];
}

fn finishFrame(ctx: *Ctx) !Frame {
    const pixels = ctx.pixels.?;
    switch (@as(VideoFormat, @fromBackingInt(@intCast(ctx.format)))) {
        .BGRA, .BGRx => for (pixels) |*p| {
            p.* |= 0xFF000000;
        },
        .RGBA, .RGBx => for (pixels) |*p| {
            const v = p.*;
            p.* = 0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF);
        },
        else => {
            std.heap.page_allocator.free(pixels);
            return error.UnsupportedFormat;
        },
    }
    return .{ .width = ctx.out_w, .height = ctx.out_h, .pixels = pixels };
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

test "format pod is a well-formed EnumFormat object" {
    var buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&buf).?;
    try std.testing.expectEqual(@as(usize, 0), pod.len % 8);
    try std.testing.expectEqual(@as(u32, @intCast(pod.len - 8)), std.mem.readInt(u32, pod[0..4], .little));
    try std.testing.expectEqual(SPA_TYPE_Object, std.mem.readInt(u32, pod[4..8], .little));
    try std.testing.expectEqual(SPA_TYPE_OBJECT_Format, std.mem.readInt(u32, pod[8..12], .little));
    try std.testing.expectEqual(SPA_PARAM_EnumFormat, std.mem.readInt(u32, pod[12..16], .little));

    // walking it finds every property at an 8-aligned offset
    const Seen = struct {
        keys: [8]u32 = undefined,
        n: usize = 0,
        fn visit(self: *@This(), key: u32, vt: u32, val: []const u8) void {
            _ = vt;
            _ = val;
            self.keys[self.n] = key;
            self.n += 1;
        }
    };
    var seen = Seen{};
    forEachProp(pod, &seen, Seen.visit);
    try std.testing.expectEqual(@as(usize, 5), seen.n);
    try std.testing.expectEqualSlices(u32, &.{
        SPA_FORMAT_mediaType,
        SPA_FORMAT_mediaSubtype,
        SPA_FORMAT_VIDEO_format,
        SPA_FORMAT_VIDEO_size,
        SPA_FORMAT_VIDEO_framerate,
    }, seen.keys[0..5]);

    // a negotiated format pod (choices unwrapped) feeds the ctx
    var ctx = Ctx{};
    forEachProp(pod, &ctx, visitFormat);
    try std.testing.expectEqual(@as(u32, @backingInt(VideoFormat.BGRA)), ctx.format);
    try std.testing.expectEqual(@as(u32, 1920), ctx.width);
    try std.testing.expectEqual(@as(u32, 1080), ctx.height);

    // too small a buffer is reported, never overrun
    var tiny: [40]u8 align(8) = undefined;
    try std.testing.expect(buildFormatPod(&tiny) == null);
}

test "crop meta pod and crop region validation" {
    var buf: [64]u8 align(8) = undefined;
    const pod = buildCropMetaPod(&buf).?;
    try std.testing.expectEqual(@as(usize, 64), pod.len);
    try std.testing.expectEqual(SPA_TYPE_OBJECT_ParamMeta, std.mem.readInt(u32, pod[8..12], .little));
    try std.testing.expectEqual(SPA_META_VideoCrop, std.mem.readInt(u32, pod[32..36], .little));

    var region = SpaMetaRegion{ .x = 10, .y = 20, .width = 100, .height = 50 };
    var metas = [_]SpaMeta{.{ .type = SPA_META_VideoCrop, .size = @sizeOf(SpaMetaRegion), .data = &region }};
    var sb = SpaBuffer{ .n_metas = 1, .n_datas = 0, .metas = &metas, .datas = null };
    const r = cropRegion(&sb, 200, 100);
    try std.testing.expectEqual(@as(u32, 100), r.width);
    try std.testing.expectEqual(@as(i32, 20), r.y);
    // out of bounds falls back to the full frame
    region.width = 300;
    try std.testing.expectEqual(@as(u32, 200), cropRegion(&sb, 200, 100).width);
}

test "truncated or garbage pods are walked safely" {
    var buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&buf).?;
    var ctx = Ctx{};
    var cut: usize = 0;
    while (cut < pod.len) : (cut += 4) forEachProp(pod[0..cut], &ctx, visitFormat);
    var junk: [128]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (0..2000) |_| {
        prng.random().bytes(&junk);
        std.mem.writeInt(u32, junk[4..8], SPA_TYPE_Object, .little);
        forEachProp(&junk, &ctx, visitFormat);
    }
}
