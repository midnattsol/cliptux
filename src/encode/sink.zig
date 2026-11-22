//! Where a recording's frames go: the GIF encoder, or H.264/MP4 through
//! (in this order) the ffmpeg program with VA-API, the FFmpeg libraries
//! in process (libx264, OpenH264) or the ffmpeg program with libx264.
//! A recording with sound goes to the ffmpeg program.

const std = @import("std");
const gif = @import("gif.zig");
const av = @import("av.zig");
const av_mp4 = @import("av_mp4.zig");
const ffmpeg = @import("ffmpeg_proc.zig");
const proc = @import("../platform/api.zig").proc;
const quantize = @import("quantize.zig");
const yuv = @import("yuv.zig");
const sys = @import("../platform/api.zig").sys;

pub const Format = enum { mp4, gif };
pub const Quality = av_mp4.Quality;

pub const Config = struct {
    format: Format,
    /// output size (MP4: even; GIF: already scaled to the maximum width)
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality = .medium,
    audio: bool = false,
    dither: quantize.Dither = .ordered,
    /// VA-API render node from ffmpeg_proc.probeVaapi, if any
    vaapi: ?[:0]const u8 = null,
};

pub const Backend = enum {
    gif,
    ffmpeg_vaapi,
    libav,
    ffmpeg,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .gif => "GIF encoder",
            .ffmpeg_vaapi => "ffmpeg, VA-API",
            .libav => "FFmpeg libraries",
            .ffmpeg => "ffmpeg, libx264",
        };
    }
};

pub const Sink = struct {
    backend: Backend,
    cfg: Config,
    gif_enc: ?gif.Encoder = null,
    gif_fd: ?sys.fd_t = null,
    mp4: ?av_mp4.Mp4 = null,
    ff: ?ffmpeg.Proc = null,
    /// the recording has sound (the backend takes it)
    has_audio: bool = false,

    pub fn open(gpa: std.mem.Allocator, envp: proc.Envp, path: [:0]const u8, cfg: Config) !Sink {
        if (cfg.format == .gif) return openGif(gpa, path, cfg);
        const want = forced();
        const ff_opts: ffmpeg.Options = .{ .width = cfg.width, .height = cfg.height, .fps = cfg.fps, .quality = cfg.quality, .audio = cfg.audio };
        if (cfg.vaapi != null and want != .libav and want != .ffmpeg) {
            var o = ff_opts;
            o.vaapi = cfg.vaapi;
            if (ffmpeg.Proc.open(gpa, envp, path, o)) |p| return .{ .backend = .ffmpeg_vaapi, .cfg = cfg, .ff = p, .has_audio = cfg.audio } else |err| std.log.info("recording: ffmpeg with VA-API: {t}", .{err});
        }
        if (cfg.audio and want != .libav) {
            if (ffmpeg.Proc.open(gpa, envp, path, ff_opts)) |p| return .{ .backend = .ffmpeg, .cfg = cfg, .ff = p, .has_audio = true } else |err| std.log.info("recording: ffmpeg: {t}; no sound", .{err});
        }
        if (want != .ffmpeg) {
            if (av_mp4.Mp4.open(path, .{ .width = cfg.width, .height = cfg.height, .fps = cfg.fps, .quality = cfg.quality })) |m| {
                std.log.info("recording: {s} through the FFmpeg libraries", .{m.encoder_name});
                return .{ .backend = .libav, .cfg = cfg, .mp4 = m };
            } else |err| std.log.info("recording: FFmpeg libraries: {t} ({s})", .{ err, if (av.available()) "loaded" else av.missing() });
        }
        var o = ff_opts;
        o.audio = false;
        const p = try ffmpeg.Proc.open(gpa, envp, path, o);
        return .{ .backend = .ffmpeg, .cfg = cfg, .ff = p };
    }

    /// SHOTLET_ENCODER=libav|ffmpeg picks one path (tests, bug reports).
    fn forced() ?Backend {
        const v = std.mem.span(std.c.getenv("SHOTLET_ENCODER") orelse return null);
        if (std.mem.eql(u8, v, "libav")) return .libav;
        if (std.mem.eql(u8, v, "ffmpeg")) return .ffmpeg;
        return null;
    }

    fn openGif(gpa: std.mem.Allocator, path: [:0]const u8, cfg: Config) !Sink {
        const fd = try sys.createWrite(path);
        errdefer sys.close(fd);
        const enc = try gif.Encoder.init(gpa, cfg.width, cfg.height, .{ .dither = cfg.dither }, fd);
        return .{ .backend = .gif, .cfg = cfg, .gif_enc = enc, .gif_fd = fd };
    }

    /// Frame `index` (shown at index / fps s), cfg.width x cfg.height.
    pub fn video(self: *Sink, px: []const u32, stride: usize, index: u64) !void {
        switch (self.backend) {
            .gif => try self.gif_enc.?.addFrame(px, stride, @intCast(index * 1000 / self.cfg.fps)),
            .libav => try self.mp4.?.addFrame(px, stride, index),
            .ffmpeg, .ffmpeg_vaapi => try self.ff.?.addFrame(px, stride),
        }
    }

    /// Whether every frame must be written, unchanged ones too (the
    /// ffmpeg pipe has no timestamps); else unchanged pictures are skipped.
    pub fn needsEveryFrame(self: *const Sink) bool {
        return self.backend == .ffmpeg or self.backend == .ffmpeg_vaapi;
    }

    /// The previous frame again (needsEveryFrame sinks).
    pub fn repeat(self: *Sink) !void {
        if (self.ff) |*f| try f.repeat();
    }

    /// Interleaved 16-bit stereo at 48 kHz (only when has_audio).
    pub fn audio(self: *Sink, samples: []const i16) !void {
        if (!self.has_audio) return;
        try self.ff.?.addAudio(samples);
    }

    pub fn finish(self: *Sink, frames: u64) !void {
        switch (self.backend) {
            .gif => {
                defer self.closeGif();
                try self.gif_enc.?.finish(@intCast(frames * 1000 / self.cfg.fps));
            },
            .libav => try self.mp4.?.finish(),
            .ffmpeg, .ffmpeg_vaapi => try self.ff.?.finish(),
        }
    }

    pub fn abort(self: *Sink) void {
        switch (self.backend) {
            .gif => self.closeGif(),
            .libav => self.mp4.?.close(),
            .ffmpeg, .ffmpeg_vaapi => self.ff.?.abort(),
        }
    }

    fn closeGif(self: *Sink) void {
        if (self.gif_enc) |*e| e.deinit();
        self.gif_enc = null;
        if (self.gif_fd) |fd| sys.close(fd);
        self.gif_fd = null;
    }
};

test "a GIF sink writes a file the decoder reads" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-sink");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/a.gif", .{dir}, 0);
    defer gpa.free(path);
    const envp: proc.Envp = @ptrCast(std.c.environ);
    var s = try Sink.open(gpa, envp, path, .{ .format = .gif, .width = 40, .height = 20, .fps = 10 });
    var px: [40 * 20]u32 = undefined;
    for (0..20) |i| {
        for (&px, 0..) |*p, k| p.* = if (k % 40 == i * 2) 0xFFFFFFFF else 0xFF203040;
        try s.video(&px, 40, i);
    }
    try s.finish(20);
    const data = try sys.readFileAlloc(gpa, path, 1 << 20);
    defer gpa.free(data);
    const st = try @import("gifdec.zig").stats(gpa, data);
    try std.testing.expectEqual(@as(u32, 20), st.frames);
    try std.testing.expectEqual(@as(i64, 2000), st.duration_ms);
}
