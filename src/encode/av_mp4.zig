//! H.264 in MP4 through the FFmpeg libraries in process (av.zig): the
//! frames go from Shotlet's buffers straight into the encoder, no copy
//! through a pipe. libx264 (CRF, veryfast) when there, else OpenH264.
//! Video only: recordings with sound use the ffmpeg program.

const std = @import("std");
const av = @import("av.zig");
const yuv = @import("yuv.zig");

pub const Quality = enum { low, medium, high };

pub const Options = struct {
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality = .medium,
};

const Ctx = av.Ctx;

pub const Mp4 = struct {
    enc: ?*Ctx = null,
    fmt: ?*Ctx = null,
    frame: ?*Ctx = null,
    pkt: ?*Ctx = null,
    stream: *Ctx = undefined,
    codec_tb: av.Rational,
    opts: Options,
    header_written: bool = false,
    encoder_name: []const u8 = "",
    frames: u64 = 0,

    /// Open `path` for writing; error when the libraries cannot do it
    /// (the caller then tries the ffmpeg program).
    pub fn open(path: [:0]const u8, opts: Options) !Mp4 {
        if (!av.available()) return error.NoLibav;
        if (opts.width % 2 != 0 or opts.height % 2 != 0 or opts.fps == 0) return error.BadSize;
        var self: Mp4 = .{ .opts = opts, .codec_tb = .{ .num = 1, .den = @intCast(opts.fps) } };
        errdefer self.close();
        try self.openEncoder();
        try self.openMuxer(path);
        self.frame = av.util.av_frame_alloc() orelse return error.NoMemory;
        av.field(c_int, self.frame.?, av.frame_width).* = @intCast(opts.width);
        av.field(c_int, self.frame.?, av.frame_height).* = @intCast(opts.height);
        av.field(c_int, self.frame.?, av.frame_format).* = av.pix_yuv420p;
        try check(av.util.av_frame_get_buffer(self.frame.?, 0), "frame buffer");
        self.pkt = av.codec.av_packet_alloc() orelse return error.NoMemory;
        return self;
    }

    fn openEncoder(self: *Mp4) !void {
        for ([_][:0]const u8{ "libx264", "libopenh264" }) |name| {
            const c = av.codec.avcodec_find_encoder_by_name(name) orelse continue;
            var ctx: ?*Ctx = av.codec.avcodec_alloc_context3(c) orelse return error.NoMemory;
            if (self.configure(ctx.?, name)) {
                self.enc = ctx;
                self.encoder_name = name;
                return;
            } else |err| {
                std.log.info("recording: {s} did not open ({t})", .{ name, err });
                av.codec.avcodec_free_context(&ctx);
            }
        }
        return error.NoH264Encoder;
    }

    fn configure(self: *Mp4, ctx: *Ctx, name: []const u8) !void {
        const o = self.opts;
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrintSentinel(&size_buf, "{d}x{d}", .{ o.width, o.height }, 0);
        try setStr(ctx, "video_size", size);
        try setStr(ctx, "pixel_format", "yuv420p");
        try check(av.util.av_opt_set_q(ctx, "time_base", self.codec_tb, 0), "time_base");
        // not an option in every version; the time base is what counts
        _ = av.util.av_opt_set_q(ctx, "framerate", .{ .num = @intCast(o.fps), .den = 1 }, 0);
        try setInt(ctx, "g", @as(i64, o.fps) * 2);
        try setInt(ctx, "bf", 0);
        try setInt(ctx, "threads", 0);
        try setStr(ctx, "flags", "+global_header");
        try setStr(ctx, "colorspace", "bt709");
        try setStr(ctx, "color_primaries", "bt709");
        try setStr(ctx, "color_trc", "bt709");
        try setStr(ctx, "color_range", "tv");
        if (std.mem.eql(u8, name, "libx264")) {
            try setStr(ctx, "preset", "veryfast");
            try setStr(ctx, "crf", switch (o.quality) {
                .low => "30",
                .medium => "25",
                .high => "20",
            });
        } else {
            // bits per pixel per second, roughly what CRF gives screens
            const bpp: i64 = switch (o.quality) {
                .low => 1,
                .medium => 2,
                .high => 4,
            };
            try setInt(ctx, "b", @divTrunc(@as(i64, o.width) * o.height * bpp * @min(o.fps, 30), 10));
        }
        try check(av.codec.avcodec_open2(ctx, null, null), "open encoder");
    }

    fn openMuxer(self: *Mp4, path: [:0]const u8) !void {
        try check(av.format.avformat_alloc_output_context2(&self.fmt, null, "mp4", path.ptr), "mp4 muxer");
        const fmt = self.fmt orelse return error.NoMuxer;
        self.stream = av.format.avformat_new_stream(fmt, null) orelse return error.NoMemory;
        try check(av.codec.avcodec_parameters_from_context(av.field(*Ctx, self.stream, av.stream_codecpar).*, self.enc.?), "stream parameters");
        av.field(av.Rational, self.stream, av.stream_time_base).* = self.codec_tb;
        try check(av.format.avio_open(av.field(?*Ctx, fmt, av.fmt_pb), path.ptr, av.AVIO_FLAG_WRITE), "open file");
        var dict: ?*Ctx = null;
        defer av.util.av_dict_free(&dict);
        _ = av.util.av_dict_set(&dict, "movflags", "+faststart", 0);
        try check(av.format.avformat_write_header(fmt, &dict), "mp4 header");
        self.header_written = true;
    }

    /// Encode one frame (w x h of the options, `stride` pixels per row)
    /// as frame number `index` (at index / fps seconds).
    pub fn addFrame(self: *Mp4, px: []const u32, stride: usize, index: u64) !void {
        const f = self.frame.?;
        try check(av.util.av_frame_make_writable(f), "frame writable");
        const data = av.field([8]?[*]u8, f, av.frame_data);
        const ls = av.field([8]c_int, f, av.frame_linesize);
        yuv.toI420(px, stride, self.opts.width, self.opts.height, .{
            .y = data[0].?,
            .u = data[1].?,
            .v = data[2].?,
            .y_stride = @intCast(ls[0]),
            .u_stride = @intCast(ls[1]),
            .v_stride = @intCast(ls[2]),
        });
        av.field(i64, f, av.frame_pts).* = @intCast(index);
        try check(av.codec.avcodec_send_frame(self.enc.?, f), "encode");
        try self.drain();
        self.frames += 1;
    }

    fn drain(self: *Mp4) !void {
        const pkt = self.pkt.?;
        const st_tb = av.field(av.Rational, self.stream, av.stream_time_base).*;
        while (true) {
            const rc = av.codec.avcodec_receive_packet(self.enc.?, pkt);
            if (rc == av.AVERROR_EAGAIN or rc == av.AVERROR_EOF) return;
            try check(rc, "receive packet");
            // every frame lasts one tick: the last one too
            av.field(i64, pkt, av.pkt_duration).* = 1;
            av.codec.av_packet_rescale_ts(pkt, self.codec_tb, st_tb);
            av.field(c_int, pkt, av.pkt_stream_index).* = 0;
            const wr = av.format.av_interleaved_write_frame(self.fmt.?, pkt);
            av.codec.av_packet_unref(pkt);
            try check(wr, "write packet");
        }
    }

    /// Flush the encoder and write the index (moved to the front).
    pub fn finish(self: *Mp4) !void {
        try check(av.codec.avcodec_send_frame(self.enc.?, null), "flush");
        try self.drain();
        try check(av.format.av_write_trailer(self.fmt.?), "trailer");
        self.header_written = false;
        self.close();
    }

    pub fn close(self: *Mp4) void {
        if (self.fmt) |fmt| {
            if (self.header_written) _ = av.format.av_write_trailer(fmt);
            _ = av.format.avio_closep(av.field(?*Ctx, fmt, av.fmt_pb));
            av.format.avformat_free_context(fmt);
            self.fmt = null;
        }
        if (self.enc != null) av.codec.avcodec_free_context(&self.enc);
        if (self.frame != null) av.util.av_frame_free(&self.frame);
        if (self.pkt != null) av.codec.av_packet_free(&self.pkt);
    }
};

fn check(rc: c_int, what: []const u8) !void {
    if (rc >= 0) return;
    var buf: [128]u8 = @splat(0);
    std.log.info("recording: libav {s}: {s}", .{ what, av.errName(rc, &buf) });
    return error.Libav;
}

fn setStr(ctx: *Ctx, name: [*:0]const u8, value: [*:0]const u8) !void {
    try check(av.util.av_opt_set(ctx, name, value, av.search_children), std.mem.span(name));
}

fn setInt(ctx: *Ctx, name: [*:0]const u8, value: i64) !void {
    try check(av.util.av_opt_set_int(ctx, name, value, av.search_children), std.mem.span(name));
}

test "libav writes a playable MP4 when the libraries are there" {
    if (!av.available()) return error.SkipZigTest;
    const sys = @import("../platform/sys.zig");
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-av");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/t.mp4", .{dir}, 0);
    defer gpa.free(path);
    const w = 160;
    const h = 90;
    var mp4 = Mp4.open(path, .{ .width = w, .height = h, .fps = 30 }) catch |err| {
        // a libavcodec without any H.264 encoder: the program fallback
        if (err == error.NoH264Encoder) return error.SkipZigTest;
        return err;
    };
    var px: [w * h]u32 = undefined;
    for (0..45) |i| {
        for (&px, 0..) |*p, k| p.* = 0xFF000000 | @as(u32, @intCast((k + i * 3) % 256)) << 8;
        try mp4.addFrame(&px, w, i);
    }
    try mp4.finish();
    const data = try sys.readFileAlloc(gpa, path, 1 << 24);
    defer gpa.free(data);
    // ftyp first, and the index (moov) before the data (faststart)
    try std.testing.expectEqualStrings("ftyp", data[4..8]);
    const moov = std.mem.indexOf(u8, data, "moov").?;
    const mdat = std.mem.indexOf(u8, data, "mdat").?;
    try std.testing.expect(moov < mdat);
}
