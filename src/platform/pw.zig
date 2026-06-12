//! Minimal PipeWire screen-capture client. Loads libpipewire-0.3 at runtime
//! (dlopen) so cliptux keeps building with zero dependencies and falls back
//! to the Screenshot portal when PipeWire is unavailable. Uses the stable
//! pw_stream C API; the SPA format pod is built by hand.

const std = @import("std");

// --- SPA / PipeWire ABI constants (stable since 0.3) ---
const SPA_TYPE_Id: u32 = 3;
const SPA_TYPE_Object: u32 = 15;
const SPA_TYPE_Choice: u32 = 19;
const SPA_TYPE_Rectangle: u32 = 10;
const SPA_TYPE_Fraction: u32 = 11;

const SPA_TYPE_OBJECT_Format: u32 = 0x40003;
const SPA_PARAM_EnumFormat: u32 = 3;
const SPA_PARAM_Format: u32 = 4;

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

const SpaBuffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?*anyopaque,
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
    inline for (@typeInfo(Api).@"struct".fields) |fld| {
        const sym_name = "pw_" ++ fld.name;
        // DynLib.lookup requires a null-terminated name
        const ptr = l.lookup(fld.type, sym_name) orelse return null;
        @field(out, fld.name) = ptr;
    }
    return out;
}

// --- format pod ---

fn putU32(buf: []u8, pos: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], v, .little);
    pos.* += 4;
}

/// Build the EnumFormat pod: raw video in BGRA/BGRx/RGBA/RGBx at any size.
fn buildFormatPod(buf: []u8) []const u8 {
    var pos: usize = 0;
    putU32(buf, &pos, 0); // body size, patched below
    putU32(buf, &pos, SPA_TYPE_Object);
    putU32(buf, &pos, SPA_TYPE_OBJECT_Format);
    putU32(buf, &pos, SPA_PARAM_EnumFormat);

    // mediaType = video
    putU32(buf, &pos, SPA_FORMAT_mediaType);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 4);
    putU32(buf, &pos, SPA_TYPE_Id);
    putU32(buf, &pos, SPA_MEDIA_TYPE_video);
    putU32(buf, &pos, 0); // pad

    // mediaSubtype = raw
    putU32(buf, &pos, SPA_FORMAT_mediaSubtype);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 4);
    putU32(buf, &pos, SPA_TYPE_Id);
    putU32(buf, &pos, SPA_MEDIA_SUBTYPE_raw);
    putU32(buf, &pos, 0); // pad

    // format: enum choice over the 32-bit formats we can swizzle
    putU32(buf, &pos, SPA_FORMAT_VIDEO_format);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 36); // choice body: 8 meta + 8 child + 5*4 values
    putU32(buf, &pos, SPA_TYPE_Choice);
    putU32(buf, &pos, SPA_CHOICE_Enum);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 4); // child size
    putU32(buf, &pos, SPA_TYPE_Id);
    putU32(buf, &pos, @intFromEnum(VideoFormat.BGRA)); // default
    putU32(buf, &pos, @intFromEnum(VideoFormat.BGRA));
    putU32(buf, &pos, @intFromEnum(VideoFormat.BGRx));
    putU32(buf, &pos, @intFromEnum(VideoFormat.RGBA));
    putU32(buf, &pos, @intFromEnum(VideoFormat.RGBx));
    putU32(buf, &pos, 0); // pad to 8

    // size: range 1x1 .. 16384x16384
    putU32(buf, &pos, SPA_FORMAT_VIDEO_size);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 40); // 8 meta + 8 child + 3*8 rect values
    putU32(buf, &pos, SPA_TYPE_Choice);
    putU32(buf, &pos, SPA_CHOICE_Range);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 8);
    putU32(buf, &pos, SPA_TYPE_Rectangle);
    putU32(buf, &pos, 1920);
    putU32(buf, &pos, 1080);
    putU32(buf, &pos, 1);
    putU32(buf, &pos, 1);
    putU32(buf, &pos, 16384);
    putU32(buf, &pos, 16384);

    // framerate: range 0/1 .. 1000/1 (variable)
    putU32(buf, &pos, SPA_FORMAT_VIDEO_framerate);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 40);
    putU32(buf, &pos, SPA_TYPE_Choice);
    putU32(buf, &pos, SPA_CHOICE_Range);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 8);
    putU32(buf, &pos, SPA_TYPE_Fraction);
    putU32(buf, &pos, 25);
    putU32(buf, &pos, 1);
    putU32(buf, &pos, 0);
    putU32(buf, &pos, 1);
    putU32(buf, &pos, 1000);
    putU32(buf, &pos, 1);

    std.mem.writeInt(u32, buf[0..4], @intCast(pos - 8), .little);
    return buf[0..pos];
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
    pixels: ?[]u32 = null,
    done: bool = false,
    failed: bool = false,
};

fn onParamChanged(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    std.log.debug("pw param_changed id={d} param={}", .{ id, param != null });
    if (id != SPA_PARAM_Format or param == null) return;
    // parse the negotiated format object pod
    const pod: [*]const u8 = @ptrCast(param.?);
    const body_size = std.mem.readInt(u32, pod[0..4], .little);
    const pod_type = std.mem.readInt(u32, pod[4..8], .little);
    if (pod_type != SPA_TYPE_Object or body_size < 8) return;
    var pos: usize = 16; // skip pod header + object type/id
    const end: usize = 8 + body_size;
    while (pos + 16 <= end) {
        const key = std.mem.readInt(u32, pod[pos..][0..4], .little);
        const vsize = std.mem.readInt(u32, pod[pos + 8 ..][0..4], .little);
        const vtype = std.mem.readInt(u32, pod[pos + 12 ..][0..4], .little);
        const vdata = pos + 16;
        if (vdata + vsize > end) break;
        // values may arrive wrapped in a Choice pod (None = fixated);
        // the payload then starts after choice meta (8) + child header (8)
        var val = vdata;
        var vt = vtype;
        if (vtype == SPA_TYPE_Choice and vsize >= 20) {
            vt = std.mem.readInt(u32, pod[vdata + 12 ..][0..4], .little); // child type
            val = vdata + 16;
        }
        if (key == SPA_FORMAT_VIDEO_format and vt == SPA_TYPE_Id) {
            ctx.format = std.mem.readInt(u32, pod[val..][0..4], .little);
        } else if (key == SPA_FORMAT_VIDEO_size and vt == SPA_TYPE_Rectangle) {
            ctx.width = std.mem.readInt(u32, pod[val..][0..4], .little);
            ctx.height = std.mem.readInt(u32, pod[val + 4 ..][0..4], .little);
        }
        pos = vdata + std.mem.alignForward(usize, vsize, 8);
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

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    std.log.debug("pw process", .{});
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    const stream = ctx.stream orelse return;
    const b = api.stream_dequeue_buffer(stream) orelse return;
    defer _ = api.stream_queue_buffer(stream, b);
    if (ctx.done or ctx.failed) return;

    const sb = b.buffer orelse return;
    if (sb.n_datas < 1) return;
    const d = sb.datas.?[0];
    const chunk = d.chunk orelse return;
    const src_base: [*]const u8 = @ptrCast(d.data orelse return);
    if (ctx.width == 0 or ctx.height == 0) return;
    const stride: usize = if (chunk.stride > 0) @intCast(chunk.stride) else ctx.width * 4;
    // never read past the mapped buffer, whatever the chunk claims
    const needed = @as(usize, chunk.offset) + (@as(usize, ctx.height) - 1) * stride + @as(usize, ctx.width) * 4;
    if (needed > d.maxsize) return;

    const n: usize = @as(usize, ctx.width) * ctx.height;
    const pixels = std.heap.page_allocator.alloc(u32, n) catch {
        ctx.failed = true;
        api.thread_loop_signal(ctx.loop, false);
        return;
    };
    const dst_bytes = std.mem.sliceAsBytes(pixels);
    var y: usize = 0;
    while (y < ctx.height) : (y += 1) {
        const src_row = src_base[chunk.offset + y * stride ..][0 .. ctx.width * 4];
        @memcpy(dst_bytes[y * ctx.width * 4 ..][0 .. ctx.width * 4], src_row);
    }
    ctx.pixels = pixels;
    ctx.done = true;
    api.thread_loop_signal(ctx.loop, false);
}

/// Pre-established PipeWire connection (handshake done, no stream yet).
pub const Pre = struct {
    loop: ?*anyopaque = null,
    context: ?*anyopaque = null,
    core: ?*anyopaque = null,
};

/// Connect to the PipeWire daemon over the portal fd. Takes ownership of fd.
/// Safe to run on a separate thread (no shared allocator use).
pub fn preconnect(fd: i32) !Pre {
    if (!available()) return error.PipeWireUnavailable;
    var pre = Pre{};
    pre.loop = api.thread_loop_new("cliptux-pw", null) orelse return error.PwLoop;
    if (api.thread_loop_start(pre.loop) < 0) {
        api.thread_loop_destroy(pre.loop);
        return error.PwLoop;
    }
    api.thread_loop_lock(pre.loop);
    pre.context = api.context_new(api.thread_loop_get_loop(pre.loop), null, 0);
    if (pre.context == null) {
        // fd ownership only transfers to a successful connect
        _ = std.os.linux.close(fd);
    }
    pre.core = if (pre.context != null) api.context_connect_fd(pre.context, fd, null, 0) else null;
    api.thread_loop_unlock(pre.loop);
    if (pre.core == null) {
        teardown(&pre, null);
        return error.PwConnect;
    }
    return pre;
}

/// Discard a pre-established connection without grabbing.
pub fn discard(pre: *Pre) void {
    teardown(pre, null);
}

fn teardown(pre: *Pre, stream: ?*anyopaque) void {
    if (pre.loop != null) api.thread_loop_stop(pre.loop);
    if (stream != null) api.stream_destroy(stream);
    if (pre.core != null) _ = api.core_disconnect(pre.core);
    if (pre.context != null) api.context_destroy(pre.context);
    if (pre.loop != null) api.thread_loop_destroy(pre.loop);
    pre.* = .{};
}

/// Grab one frame using a pre-established connection; consumes it.
pub fn grabPre(pre: *Pre, node_id: u32, timeout_sec: u32) !Frame {
    var ctx = Ctx{ .loop = pre.loop };
    var hook = SpaHook{};
    var events = StreamEvents{
        .state_changed = onStateChanged,
        .param_changed = onParamChanged,
        .process = onProcess,
    };

    api.thread_loop_lock(pre.loop);
    const stream = api.stream_new(pre.core, "cliptux-capture", null);

    var pod_buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&pod_buf);
    var params = [_][*]const u8{pod.ptr};

    var connect_rc: c_int = -1;
    if (stream != null) {
        ctx.stream = stream;
        api.stream_add_listener(stream, &hook, &events, &ctx);
        connect_rc = api.stream_connect(
            stream,
            PW_DIRECTION_INPUT,
            node_id,
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
            &params,
            1,
        );
    }
    if (connect_rc >= 0) {
        var waited: u32 = 0;
        while (!ctx.done and !ctx.failed and waited < timeout_sec) {
            _ = api.thread_loop_timed_wait(pre.loop, 1);
            waited += 1;
        }
    }
    api.thread_loop_unlock(pre.loop);
    teardown(pre, stream);

    if (connect_rc < 0) return error.PwConnect;
    if (!ctx.done or ctx.pixels == null) {
        if (ctx.pixels) |p| std.heap.page_allocator.free(p);
        return error.NoFrame;
    }
    return finishFrame(&ctx);
}

fn finishFrame(ctx: *Ctx) !Frame {
    const pixels = ctx.pixels.?;
    switch (@as(VideoFormat, @enumFromInt(ctx.format))) {
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
    return .{ .width = ctx.width, .height = ctx.height, .pixels = pixels };
}

/// Grab a single frame from the portal-provided PipeWire stream.
/// Takes ownership of `fd`. Blocks up to `timeout_sec`.
pub fn grabFrame(fd: i32, node_id: u32, timeout_sec: u32) !Frame {
    var pre = try preconnect(fd);
    return grabPre(&pre, node_id, timeout_sec);
}
