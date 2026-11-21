//! Continuous PipeWire capture for recordings: one connection (the
//! portal's fd, or the session's PipeWire for a node the GNOME Shell
//! integration started) with a video stream and up to two sound streams
//! (microphone: the default source; system sound: the default sink's
//! monitor). Callbacks run on PipeWire's thread with the mapped buffer;
//! they copy what they need and return.

const std = @import("std");
const pw = @import("pw.zig");
const sys = @import("sys.zig");

/// What pwstream uses of pw.zig, and three functions it loads itself.
const abi = struct {
    const SpaHook_ = pw.SpaHook;
    const StreamEvents_ = pw.StreamEvents;
    const PodWriter_ = pw.PodWriter;
    const flag_autoconnect = pw.PW_STREAM_FLAG_AUTOCONNECT;
    const flag_map_buffers = pw.PW_STREAM_FLAG_MAP_BUFFERS;
    const direction_input = pw.PW_DIRECTION_INPUT;
    const state_error = pw.PW_STREAM_STATE_ERROR;
    const param_format = pw.SPA_PARAM_Format;
    const chunk_corrupted = pw.SPA_CHUNK_FLAG_CORRUPTED;
    const buildVideoFormatPod = pw.buildFormatPod;
    const buildCropMeta = pw.buildCropMetaPod;
    const crop = pw.cropRegion;

    fn lib() *const pw.Api {
        return &pw.api;
    }

    fn props(pod: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32, u32, []const u8) void) void {
        pw.forEachProp(pod, ctx, visit);
    }

    fn teardownPre(pre: *pw.Pre, streams: []const ?*anyopaque) void {
        pw.teardown(pre, streams);
    }

    /// The negotiated video format and size, out of a Format pod.
    fn visitVideoFormat(out: *[3]u32, key: u32, vt: u32, val: []const u8) void {
        var c: pw.Ctx = .{};
        pw.visitFormat(&c, key, vt, val);
        if (c.format != 0) out[0] = c.format;
        if (c.width != 0) {
            out[1] = c.width;
            out[2] = c.height;
        }
    }
};

const Extra = struct {
    pw_context_connect: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    pw_properties_new_string: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
};
var extra: ?Extra = null;

fn extraApi() !*const Extra {
    if (extra == null) {
        if (!pw.available()) return error.PipeWireUnavailable;
        const l = &pw.lib.?;
        extra = .{
            .pw_context_connect = l.lookup(@FieldType(Extra, "pw_context_connect"), "pw_context_connect") orelse return error.PwSymbols,
            .pw_properties_new_string = l.lookup(@FieldType(Extra, "pw_properties_new_string"), "pw_properties_new_string") orelse return error.PwSymbols,
        };
    }
    return &extra.?;
}

pub const VideoFormat = pw.VideoFormat;

/// A video buffer as mapped: the valid area of the frame.
pub const Raw = struct {
    base: [*]const u8,
    /// bytes per row
    stride: usize,
    width: u32,
    height: u32,
    format: VideoFormat,
    /// CLOCK_MONOTONIC, ns
    time_ns: i64,
};

pub const VideoFn = *const fn (ctx: *anyopaque, raw: *const Raw) void;
/// Interleaved stereo 16-bit samples; time of the first one.
pub const AudioFn = *const fn (ctx: *anyopaque, samples: []const i16, time_ns: i64) void;

pub const AudioSource = enum { mic, system };

pub const rate = 48000;

const max_streams = 3;

const Slot = struct {
    owner: *Capture = undefined,
    stream: ?*anyopaque = null,
    hook: abi.SpaHook_ = .{},
    /// negotiated: format, width, height
    fmt: [3]u32 = @splat(0),
    video: ?VideoFn = null,
    audio: ?AudioFn = null,
    ctx: *anyopaque = undefined,
    failed: bool = false,
    frames: u64 = 0,
};

pub const Capture = struct {
    pre: pw.Pre,
    slots: [max_streams]Slot = @splat(.{}),
    n: usize = 0,

    /// Connect over the portal's fd (consumed), or to the session's
    /// PipeWire daemon when null.
    pub fn open(gpa: std.mem.Allocator, fd: ?i32) !*Capture {
        const self = try gpa.create(Capture);
        errdefer gpa.destroy(self);
        self.* = .{ .pre = if (fd) |f| try pw.preconnect(f) else try connectDefault() };
        return self;
    }

    pub fn close(self: *Capture, gpa: std.mem.Allocator) void {
        var streams: [max_streams]?*anyopaque = @splat(null);
        for (self.slots[0..self.n], 0..) |s, i| streams[i] = s.stream;
        abi.teardownPre(&self.pre, streams[0..self.n]);
        gpa.destroy(self);
    }

    /// Whether any stream reported an error.
    pub fn failed(self: *const Capture) bool {
        for (self.slots[0..self.n]) |*s| if (@atomicLoad(bool, &s.failed, .acquire)) return true;
        return false;
    }

    pub fn videoFrames(self: *const Capture) u64 {
        for (self.slots[0..self.n]) |*s| if (s.video != null) return @atomicLoad(u64, &s.frames, .acquire);
        return 0;
    }

    pub fn addVideo(self: *Capture, node: u32, cb: VideoFn, ctx: *anyopaque) !void {
        var pod_buf: [256]u8 align(8) = undefined;
        const pod = abi.buildVideoFormatPod(&pod_buf) orelse return error.Pod;
        const slot = try self.newSlot(ctx);
        slot.video = cb;
        try self.connect(slot, "shotlet-record", null, node, pod);
    }

    pub fn addAudio(self: *Capture, src: AudioSource, cb: AudioFn, ctx: *anyopaque) !void {
        var pod_buf: [256]u8 align(8) = undefined;
        const pod = buildAudioPod(&pod_buf) orelse return error.Pod;
        const props: [*:0]const u8 = switch (src) {
            .mic => "media.type=Audio media.category=Capture media.role=Screen node.name=shotlet-record-mic",
            .system => "media.type=Audio media.category=Capture media.role=Screen stream.capture.sink=true node.name=shotlet-record-system",
        };
        const slot = try self.newSlot(ctx);
        slot.audio = cb;
        try self.connect(slot, "shotlet-record-audio", props, 0xFFFFFFFF, pod);
    }

    fn newSlot(self: *Capture, ctx: *anyopaque) !*Slot {
        if (self.n == max_streams) return error.TooManyStreams;
        const s = &self.slots[self.n];
        s.* = .{ .owner = self, .ctx = ctx };
        return s;
    }

    fn connect(self: *Capture, slot: *Slot, name: [*:0]const u8, props: ?[*:0]const u8, target: u32, pod: []const u8) !void {
        const api = abi.lib();
        const ex = try extraApi();
        api.thread_loop_lock(self.pre.loop);
        defer api.thread_loop_unlock(self.pre.loop);
        const p = if (props) |s| ex.pw_properties_new_string(s) else null;
        slot.stream = api.stream_new(self.pre.core, name, p) orelse return error.PwStream;
        self.n += 1;
        api.stream_add_listener(slot.stream, &slot.hook, &events, slot);
        const params = [_][*]const u8{pod.ptr};
        if (api.stream_connect(slot.stream, abi.direction_input, target, abi.flag_autoconnect | abi.flag_map_buffers, &params, 1) < 0)
            return error.PwConnect;
    }
};

const events: abi.StreamEvents_ = .{
    .state_changed = onState,
    .param_changed = onParam,
    .process = onProcess,
};

fn connectDefault() !pw.Pre {
    const ex = try extraApi();
    const api = abi.lib();
    var pre: pw.Pre = .{};
    pre.loop = api.thread_loop_new("shotlet-rec", null) orelse return error.PwLoop;
    if (api.thread_loop_start(pre.loop) < 0) {
        api.thread_loop_destroy(pre.loop);
        return error.PwLoop;
    }
    api.thread_loop_lock(pre.loop);
    pre.context = api.context_new(api.thread_loop_get_loop(pre.loop), null, 0);
    if (pre.context != null) pre.core = ex.pw_context_connect(pre.context, null, 0);
    api.thread_loop_unlock(pre.loop);
    if (pre.core == null) {
        abi.teardownPre(&pre, &.{});
        return error.PwConnect;
    }
    return pre;
}

fn onState(data: ?*anyopaque, _: c_int, new: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    if (new == abi.state_error) {
        std.log.warn("recording: pipewire stream error: {s}", .{if (msg) |m| std.mem.span(m) else "?"});
        @atomicStore(bool, &slot.failed, true, .release);
    }
}

fn onParam(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    if (id != abi.param_format or param == null or slot.video == null) return;
    const head: [*]const u8 = @ptrCast(param.?);
    const body = std.mem.readInt(u32, head[0..4], .little);
    if (body > 64 * 1024) return;
    abi.props(head[0 .. 8 + @as(usize, body)], &slot.fmt, abi.visitVideoFormat);
    var meta_buf: [96]u8 align(8) = undefined;
    if (abi.buildCropMeta(&meta_buf)) |meta| {
        const params = [_][*]const u8{meta.ptr};
        _ = abi.lib().stream_update_params(slot.stream, &params, 1);
    }
}

fn monoNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    const api = abi.lib();
    const b = api.stream_dequeue_buffer(slot.stream) orelse return;
    defer _ = api.stream_queue_buffer(slot.stream, b);
    const sb = b.buffer orelse return;
    if (sb.n_datas < 1) return;
    const d = sb.datas.?[0];
    const chunk = d.chunk orelse return;
    if (chunk.size == 0 or (chunk.flags & abi.chunk_corrupted) != 0) return;
    const base: [*]const u8 = @ptrCast(d.data orelse return);
    const now = monoNs();
    const avail = @min(@as(usize, d.maxsize), @as(usize, chunk.offset) + chunk.size);
    if (slot.audio) |cb| {
        const n = (avail - chunk.offset) / 4;
        const samples: [*]const i16 = @ptrCast(@alignCast(base + chunk.offset));
        cb(slot.ctx, samples[0 .. n * 2], now - @divTrunc(@as(i64, @intCast(n)) * std.time.ns_per_s, rate));
        return;
    }
    const cb = slot.video orelse return;
    const w = slot.fmt[1];
    const h = slot.fmt[2];
    if (w == 0 or h == 0) return;
    const stride: usize = if (chunk.stride > 0) @intCast(chunk.stride) else @as(usize, w) * 4;
    if (stride < @as(usize, w) * 4) return;
    const crop = abi.crop(sb, w, h);
    const first = @as(usize, chunk.offset) + @as(usize, @intCast(crop.y)) * stride + @as(usize, @intCast(crop.x)) * 4;
    const needed = first + (@as(usize, crop.height) - 1) * stride + @as(usize, crop.width) * 4;
    if (needed > avail) return;
    const raw: Raw = .{ .base = base + first, .stride = stride, .width = crop.width, .height = crop.height, .format = @fromBackingInt(slot.fmt[0]), .time_ns = now };
    cb(slot.ctx, &raw);
    _ = @atomicRmw(u64, &slot.frames, .Add, 1, .release);
}

// --- the sound format: S16LE, 48 kHz, stereo

const SPA_TYPE_Id: u32 = 3;
const SPA_TYPE_Int: u32 = 4;
const SPA_TYPE_Object: u32 = 15;
const SPA_TYPE_OBJECT_Format: u32 = 0x40003;
const SPA_PARAM_EnumFormat: u32 = 3;
const SPA_FORMAT_mediaType: u32 = 1;
const SPA_FORMAT_mediaSubtype: u32 = 2;
const SPA_FORMAT_AUDIO_format: u32 = 0x10001;
const SPA_FORMAT_AUDIO_rate: u32 = 0x10003;
const SPA_FORMAT_AUDIO_channels: u32 = 0x10004;
const SPA_MEDIA_TYPE_audio: u32 = 1;
const SPA_MEDIA_SUBTYPE_raw: u32 = 1;
const SPA_AUDIO_FORMAT_S16_LE: u32 = 0x103;

fn buildAudioPod(buf: []u8) ?[]const u8 {
    var w = abi.PodWriter_{ .buf = buf };
    for ([_]u32{ 0, SPA_TYPE_Object, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat }) |v| w.put(v);
    const props = [_][3]u32{
        .{ SPA_FORMAT_mediaType, SPA_TYPE_Id, SPA_MEDIA_TYPE_audio },
        .{ SPA_FORMAT_mediaSubtype, SPA_TYPE_Id, SPA_MEDIA_SUBTYPE_raw },
        .{ SPA_FORMAT_AUDIO_format, SPA_TYPE_Id, SPA_AUDIO_FORMAT_S16_LE },
        .{ SPA_FORMAT_AUDIO_rate, SPA_TYPE_Int, rate },
        .{ SPA_FORMAT_AUDIO_channels, SPA_TYPE_Int, 2 },
    };
    // key, flags, then a 4-byte value pod padded to 8
    for (props) |p| for ([_]u32{ p[0], 0, 4, p[1], p[2], 0 }) |v| w.put(v);
    return w.finish();
}

test "the sound format pod is a well-formed object" {
    var buf: [256]u8 align(8) = undefined;
    const pod = buildAudioPod(&buf).?;
    try std.testing.expectEqual(@as(usize, 0), pod.len % 8);
    try std.testing.expectEqual(@as(u32, @intCast(pod.len - 8)), std.mem.readInt(u32, pod[0..4], .little));
    const Seen = struct {
        rate: u32 = 0,
        fmt: u32 = 0,
        fn visit(self: *@This(), key: u32, vt: u32, val: []const u8) void {
            _ = vt;
            if (key == SPA_FORMAT_AUDIO_rate) self.rate = std.mem.readInt(u32, val[0..4], .little);
            if (key == SPA_FORMAT_AUDIO_format) self.fmt = std.mem.readInt(u32, val[0..4], .little);
        }
    };
    var seen: Seen = .{};
    abi.props(pod, &seen, Seen.visit);
    try std.testing.expectEqual(@as(u32, 48000), seen.rate);
    try std.testing.expectEqual(SPA_AUDIO_FORMAT_S16_LE, seen.fmt);
}
