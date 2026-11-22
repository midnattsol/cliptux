//! FFmpeg's libraries (libavcodec, libavformat, libavutil), loaded at run
//! time with dlopen: Shotlet builds without them and falls back to the
//! ffmpeg program (ffmpeg_proc.zig) when they are missing or not a
//! version whose structures we know.
//!
//! Almost everything goes through functions and AVOptions (by name), so
//! only a few fields of AVFrame, AVPacket, AVStream and AVFormatContext
//! are touched directly. Their offsets are those of FFmpeg 5 to 7
//! (libavutil 57-59, libavcodec 59-61, libavformat 59-61), and before any
//! use they are checked against the defaults the allocators put there.

const std = @import("std");
const dynlib = @import("../platform/api.zig").libs;

pub const Ctx = anyopaque;

pub const nopts: i64 = @bitCast(@as(u64, 0x8000000000000000));
pub const AVERROR_EAGAIN: c_int = -11;
pub const AVERROR_EOF: c_int = -0x20464f45; // FFERRTAG('E','O','F',' ')
pub const search_children: c_int = 1;
pub const AVIO_FLAG_WRITE: c_int = 2;
pub const pix_yuv420p: c_int = 0;

pub const Rational = extern struct { num: c_int, den: c_int };

const Codec = struct {
    avcodec_version: *const fn () callconv(.c) c_uint,
    avcodec_find_encoder_by_name: *const fn ([*:0]const u8) callconv(.c) ?*const Ctx,
    avcodec_alloc_context3: *const fn (?*const Ctx) callconv(.c) ?*Ctx,
    avcodec_open2: *const fn (*Ctx, ?*const Ctx, ?*?*Ctx) callconv(.c) c_int,
    avcodec_send_frame: *const fn (*Ctx, ?*const Ctx) callconv(.c) c_int,
    avcodec_receive_packet: *const fn (*Ctx, *Ctx) callconv(.c) c_int,
    avcodec_free_context: *const fn (*?*Ctx) callconv(.c) void,
    avcodec_parameters_from_context: *const fn (*Ctx, *const Ctx) callconv(.c) c_int,
    av_packet_alloc: *const fn () callconv(.c) ?*Ctx,
    av_packet_free: *const fn (*?*Ctx) callconv(.c) void,
    av_packet_unref: *const fn (*Ctx) callconv(.c) void,
    av_packet_rescale_ts: *const fn (*Ctx, Rational, Rational) callconv(.c) void,
};

const Format = struct {
    avformat_version: *const fn () callconv(.c) c_uint,
    avformat_get_class: *const fn () callconv(.c) ?*const Ctx,
    avformat_alloc_output_context2: *const fn (*?*Ctx, ?*const Ctx, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    avformat_new_stream: *const fn (*Ctx, ?*const Ctx) callconv(.c) ?*Ctx,
    avio_open: *const fn (*?*Ctx, [*:0]const u8, c_int) callconv(.c) c_int,
    avio_closep: *const fn (*?*Ctx) callconv(.c) c_int,
    avformat_write_header: *const fn (*Ctx, ?*?*Ctx) callconv(.c) c_int,
    av_interleaved_write_frame: *const fn (*Ctx, ?*Ctx) callconv(.c) c_int,
    av_write_trailer: *const fn (*Ctx) callconv(.c) c_int,
    avformat_free_context: *const fn (?*Ctx) callconv(.c) void,
};

const Util = struct {
    avutil_version: *const fn () callconv(.c) c_uint,
    av_frame_alloc: *const fn () callconv(.c) ?*Ctx,
    av_frame_free: *const fn (*?*Ctx) callconv(.c) void,
    av_frame_get_buffer: *const fn (*Ctx, c_int) callconv(.c) c_int,
    av_frame_make_writable: *const fn (*Ctx) callconv(.c) c_int,
    av_opt_set: *const fn (*Ctx, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    av_opt_set_int: *const fn (*Ctx, [*:0]const u8, i64, c_int) callconv(.c) c_int,
    av_opt_set_q: *const fn (*Ctx, [*:0]const u8, Rational, c_int) callconv(.c) c_int,
    av_dict_set: *const fn (*?*Ctx, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    av_dict_free: *const fn (*?*Ctx) callconv(.c) void,
    av_log_set_level: *const fn (c_int) callconv(.c) void,
    av_strerror: *const fn (c_int, [*]u8, usize) callconv(.c) c_int,
};

pub var codec: Codec = undefined;
pub var format: Format = undefined;
pub var util: Util = undefined;

var libs: [3]?dynlib.Lib = .{ null, null, null };
var state: enum { unknown, ok, missing } = .unknown;
var why_missing: []const u8 = "";

/// Load the libraries once. False (with the reason in `missing()`) when
/// they are absent, incomplete or of a version we do not know.
pub fn available() bool {
    if (state == .unknown) state = if (load()) .ok else .missing;
    return state == .ok;
}

pub fn missing() []const u8 {
    return why_missing;
}

const majors = [_][]const u8{ "61", "60", "59" };

fn openAny(base: []const u8, versions: []const []const u8) ?dynlib.Lib {
    return dynlib.open(base, versions);
}

fn load() bool {
    if (std.c.getenv("SHOTLET_NO_LIBAV") != null) {
        why_missing = "turned off (SHOTLET_NO_LIBAV)";
        return false;
    }
    libs[2] = openAny("avutil", &.{ "59", "58", "57" }) orelse return fail("libavutil not found");
    libs[0] = openAny("avcodec", &majors) orelse return fail("libavcodec not found");
    libs[1] = openAny("avformat", &majors) orelse return fail("libavformat not found");
    if (!bind(Codec, &codec, &libs[0].?) or !bind(Format, &format, &libs[1].?) or !bind(Util, &util, &libs[2].?))
        return fail("FFmpeg libraries lack expected functions");
    const vc = codec.avcodec_version() >> 16;
    const vf = format.avformat_version() >> 16;
    const vu = util.avutil_version() >> 16;
    if (vc < 59 or vc > 61 or vf < 59 or vf > 61 or vu < 57 or vu > 59) return fail("FFmpeg version not supported");
    util.av_log_set_level(16); // AV_LOG_ERROR
    if (!checkLayouts()) return fail("FFmpeg structures not as expected");
    return true;
}

fn fail(msg: []const u8) bool {
    why_missing = msg;
    for (&libs) |*l| if (l.*) |*x| {
        x.close();
        l.* = null;
    };
    return false;
}

fn bind(comptime T: type, out: *T, l: *dynlib.Lib) bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, ty| {
        @field(out, name) = l.lookup(ty, name) orelse return false;
    }
    return true;
}

// --- the fields we touch

pub const frame_data = 0; // uint8_t *data[8]
pub const frame_linesize = 64; // int linesize[8]
pub const frame_width = 104;
pub const frame_height = 108;
pub const frame_format = 116;
pub const frame_sar = 128;
pub const frame_pts = 136;

pub const pkt_pts = 8;
pub const pkt_dts = 16;
pub const pkt_stream_index = 36;
pub const pkt_duration = 64;
pub const pkt_pos = 72;

pub const fmt_class = 0;
pub const fmt_pb = 32;

pub const stream_index = 8;
pub const stream_codecpar = 16;
pub const stream_time_base = 32;

pub fn field(comptime T: type, obj: *Ctx, offset: usize) *T {
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + offset));
}

/// The allocators' defaults where we expect them; anything else means a
/// layout we do not know, and the libraries are not used.
fn checkLayouts() bool {
    var f: ?*Ctx = util.av_frame_alloc() orelse return false;
    defer util.av_frame_free(&f);
    const fr = f.?;
    if (field(i32, fr, frame_format).* != -1) return false;
    if (field(i32, fr, frame_sar).* != 0 or field(i32, fr, frame_sar + 4).* != 1) return false;
    if (field(i64, fr, frame_pts).* != nopts) return false;
    // extended_data points at data[] after av_frame_alloc
    if (field(usize, fr, 96).* != @intFromPtr(fr)) return false;

    var p: ?*Ctx = codec.av_packet_alloc() orelse return false;
    defer codec.av_packet_free(&p);
    const pk = p.?;
    if (field(i64, pk, pkt_pts).* != nopts or field(i64, pk, pkt_dts).* != nopts or field(i64, pk, pkt_pos).* != -1) return false;

    var oc: ?*Ctx = null;
    if (format.avformat_alloc_output_context2(&oc, null, "mp4", "x.mp4") < 0 or oc == null) return false;
    defer format.avformat_free_context(oc);
    if (field(?*const Ctx, oc.?, fmt_class).* != format.avformat_get_class()) return false;
    if (field(?*Ctx, oc.?, fmt_pb).* != null) return false;
    const st = format.avformat_new_stream(oc.?, null) orelse return false;
    if (field(c_int, st, stream_index).* != 0 or field(?*Ctx, st, stream_codecpar).* == null) return false;
    return true;
}

pub fn errName(code: c_int, buf: []u8) []const u8 {
    if (state != .ok) return "?";
    if (util.av_strerror(code, buf.ptr, buf.len) < 0) return "unknown error";
    return std.mem.sliceTo(buf, 0);
}

test "libav loads with the expected layouts, or says why not" {
    if (available()) {
        try std.testing.expect(codec.avcodec_version() >> 16 >= 59);
    } else {
        try std.testing.expect(missing().len > 0);
    }
}
