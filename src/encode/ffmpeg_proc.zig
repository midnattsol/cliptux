//! MP4 through the ffmpeg program: raw YUV 4:2:0 frames on its stdin,
//! 16-bit stereo PCM on fd 3 (when the recording has sound), H.264 by
//! VA-API when the GPU offers it, else libx264; AAC sound; the index at
//! the front. Used for recordings with sound, and whenever the FFmpeg
//! libraries cannot be loaded in process.

const std = @import("std");
const proc = @import("../platform/api.zig").proc;
const yuv = @import("yuv.zig");
const sys = @import("../platform/api.zig").sys;

pub const Quality = @import("av_mp4.zig").Quality;

pub const Options = struct {
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality = .medium,
    audio: bool = false,
    audio_rate: u32 = 48000,
    /// a VA-API render node, e.g. /dev/dri/renderD128
    vaapi: ?[:0]const u8 = null,
};

pub const Proc = struct {
    gpa: std.mem.Allocator,
    child: proc.Child,
    opts: Options,
    frame: []u8,
    frames: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, envp: proc.Envp, path: [:0]const u8, opts: Options) !Proc {
        var exe_buf: [512]u8 = undefined;
        const exe = proc.which(&exe_buf, "ffmpeg") orelse return error.NoFfmpeg;
        var arg_store: ArgStore = .{};
        const argv = try buildArgs(&arg_store, exe, path, opts);
        const frame = try gpa.alloc(u8, frameBytes(opts.width, opts.height));
        errdefer gpa.free(frame);
        const child = try proc.spawn(argv, envp, .{ .stdin = true, .fd3 = opts.audio, .stderr = true });
        return .{ .gpa = gpa, .child = child, .opts = opts, .frame = frame };
    }

    /// One frame; frames are numbered by their order (constant rate).
    pub fn addFrame(self: *Proc, px: []const u32, stride: usize) !void {
        const w = self.opts.width;
        const h = self.opts.height;
        const ysz = @as(usize, w) * h;
        yuv.toI420(px, stride, w, h, .{
            .y = self.frame.ptr,
            .u = self.frame.ptr + ysz,
            .v = self.frame.ptr + ysz + ysz / 4,
            .y_stride = w,
            .u_stride = w / 2,
            .v_stride = w / 2,
        });
        try sys.writeAllBlocking(self.child.stdin orelse return error.Closed, self.frame);
        self.frames += 1;
    }

    /// The previous frame once more (or black before the first).
    pub fn repeat(self: *Proc) !void {
        if (self.frames == 0) @memset(self.frame, 16);
        try sys.writeAllBlocking(self.child.stdin orelse return error.Closed, self.frame);
        self.frames += 1;
    }

    /// Interleaved stereo samples (any thread but the video one).
    pub fn addAudio(self: *Proc, samples: []const i16) !void {
        const fd = self.child.fd3 orelse return;
        try sys.writeAllBlocking(fd, std.mem.sliceAsBytes(samples));
    }

    /// Close the inputs and wait for ffmpeg to write the file.
    pub fn finish(self: *Proc) !void {
        defer self.gpa.free(self.frame);
        const st = self.child.wait(120_000);
        if (st == null or st.? != 0) {
            std.log.warn("recording: ffmpeg exited with {?d}", .{st});
            return error.FfmpegFailed;
        }
    }

    pub fn abort(self: *Proc) void {
        self.child.kill();
        self.gpa.free(self.frame);
    }
};

pub fn frameBytes(w: u32, h: u32) usize {
    return @as(usize, w) * h * 3 / 2;
}

const ArgStore = struct {
    list: [72]?[*:0]const u8 = @splat(null),
    n: usize = 0,
    text: [512]u8 = undefined,
    used: usize = 0,

    fn add(self: *ArgStore, a: [*:0]const u8) !void {
        if (self.n == self.list.len) return error.TooManyArgs;
        self.list[self.n] = a;
        self.n += 1;
    }

    fn print(self: *ArgStore, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrintSentinel(self.text[self.used..], fmt, args, 0);
        self.used += s.len + 1;
        try self.add(s.ptr);
    }

    fn addAll(self: *ArgStore, items: []const [*:0]const u8) !void {
        for (items) |a| try self.add(a);
    }
};

fn crf(q: Quality) [*:0]const u8 {
    return switch (q) {
        .low => "30",
        .medium => "25",
        .high => "20",
    };
}

fn buildArgs(s: *ArgStore, exe: [*:0]const u8, path: [*:0]const u8, o: Options) ![]const ?[*:0]const u8 {
    try s.addAll(&.{ exe, "-hide_banner", "-nostdin", "-loglevel", "error", "-y" });
    if (o.vaapi) |dev| try s.addAll(&.{ "-vaapi_device", dev.ptr });
    // inputs open at once (no probing ahead): the other pipe must not wait
    try s.addAll(&.{ "-probesize", "32", "-analyzeduration", "0", "-thread_queue_size", "64" });
    try s.addAll(&.{ "-f", "rawvideo", "-pix_fmt", "yuv420p", "-color_range", "tv", "-colorspace", "bt709" });
    try s.add("-s");
    try s.print("{d}x{d}", .{ o.width, o.height });
    try s.add("-r");
    try s.print("{d}", .{o.fps});
    try s.addAll(&.{ "-i", "pipe:0" });
    if (o.audio) {
        try s.addAll(&.{ "-probesize", "32", "-analyzeduration", "0", "-thread_queue_size", "64" });
        try s.addAll(&.{ "-f", "s16le", "-ac", "2", "-ar" });
        try s.print("{d}", .{o.audio_rate});
        try s.addAll(&.{ "-i", "pipe:3" });
    }
    if (o.vaapi != null) {
        try s.addAll(&.{ "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-qp", crf(o.quality) });
    } else {
        try s.addAll(&.{ "-c:v", "libx264", "-preset", "veryfast", "-crf", crf(o.quality), "-pix_fmt", "yuv420p" });
    }
    try s.add("-g");
    try s.print("{d}", .{o.fps * 2});
    try s.addAll(&.{ "-color_primaries", "bt709", "-color_trc", "bt709" });
    if (o.audio) try s.addAll(&.{ "-c:a", "aac", "-b:a", "160k" });
    try s.addAll(&.{ "-movflags", "+faststart", "-f", "mp4", path });
    return s.list[0..s.n];
}

/// A render node where ffmpeg can encode H.264 with VA-API: tried once
/// with a tiny encode (about a tenth of a second). Null without one.
pub fn probeVaapi(gpa: std.mem.Allocator, envp: proc.Envp) ?[:0]const u8 {
    if (std.c.getenv("SHOTLET_NO_VAAPI") != null) return null;
    var exe_buf: [512]u8 = undefined;
    const exe = proc.which(&exe_buf, "ffmpeg") orelse return null;
    var dev_buf: [2][:0]const u8 = undefined;
    for (proc.hwEncodeDevices(&dev_buf)) |dev| {
        const r = proc.output(gpa, &.{ exe.ptr, "-hide_banner", "-nostdin", "-loglevel", "error", "-vaapi_device", dev.ptr, "-f", "lavfi", "-i", "color=c=gray:s=64x64:d=0.1", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-f", "null", "-" }, envp, 4096, 5000) catch continue;
        gpa.free(r.out);
        if (r.status != null and r.status.? == 0) return dev;
    }
    return null;
}

test "ffmpeg arguments for software and VA-API encodes" {
    var s: ArgStore = .{};
    const a = try buildArgs(&s, "/usr/bin/ffmpeg", "/tmp/o.mp4", .{ .width = 640, .height = 360, .fps = 30, .audio = true });
    var joined: [1024]u8 = undefined;
    var n: usize = 0;
    for (a) |x| {
        const p = std.mem.span(x.?);
        @memcpy(joined[n..][0..p.len], p);
        joined[n + p.len] = ' ';
        n += p.len + 1;
    }
    const line = joined[0..n];
    try std.testing.expect(std.mem.indexOf(u8, line, "-s 640x360 -r 30 -i pipe:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-i pipe:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "libx264") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "-movflags +faststart -f mp4 /tmp/o.mp4 "));
    var s2: ArgStore = .{};
    const b = try buildArgs(&s2, "/usr/bin/ffmpeg", "/tmp/o.mp4", .{ .width = 64, .height = 64, .fps = 60, .vaapi = "/dev/dri/renderD128" });
    var vaapi = false;
    for (b) |x| vaapi = vaapi or std.mem.eql(u8, std.mem.span(x.?), "h264_vaapi");
    try std.testing.expect(vaapi);
}

test "the ffmpeg program writes H.264 and AAC that ffprobe reads back" {
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const probe = proc.which(&buf, "ffprobe") orelse return error.SkipZigTest;
    const envp: proc.Envp = @ptrCast(std.c.environ);
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-ff");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/a.mp4", .{dir}, 0);
    defer gpa.free(path);
    var p = Proc.open(gpa, envp, path, .{ .width = 64, .height = 48, .fps = 30, .audio = true }) catch |err| {
        if (err == error.NoFfmpeg) return error.SkipZigTest;
        return err;
    };
    // sound from its own thread, as when recording
    const Audio = struct {
        fn run(pp: *Proc) void {
            var pcm: [1600 * 2]i16 = @splat(0);
            for (0..30) |_| pp.addAudio(&pcm) catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, Audio.run, .{&p});
    var px: [64 * 48]u32 = @splat(0xFF336699);
    for (0..30) |i| {
        px[i] = 0xFFFFFFFF;
        try p.addFrame(&px, 64);
    }
    t.join();
    try p.finish();
    const r = try proc.output(gpa, &.{ probe.ptr, "-v", "error", "-show_entries", "stream=codec_name,width,height,avg_frame_rate", "-of", "csv=p=0", path.ptr }, envp, 4096, 10_000);
    defer gpa.free(r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "h264,64,48,30/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "aac") != null);
}
