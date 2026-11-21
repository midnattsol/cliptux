//! A recording in progress: PipeWire's pictures and sound in, the
//! encoder out, on two threads of its own (pictures at a constant frame
//! rate; sound mixed and handed over every 20 ms), with pause, resume,
//! stop and discard from the UI thread.
//!
//! Memory is bounded: three pictures (frames.zig), two seconds of sound
//! per source (audio.zig), and whatever the encoder buffers; nothing of
//! the recording accumulates in RAM.

const std = @import("std");
const sink_mod = @import("../encode/sink.zig");
const quantize = @import("../encode/quantize.zig");
const yuv = @import("../encode/yuv.zig");
const proc = @import("../encode/proc.zig");
const pwstream = @import("../platform/pwstream.zig");
const sys = @import("../platform/sys.zig");
const timeline = @import("timeline.zig");
const frames_mod = @import("frames.zig");
const audio = @import("audio.zig");
const region = @import("region.zig");
const strip_mod = @import("strip.zig");
const sync = @import("sync.zig");

pub const Options = struct {
    format: sink_mod.Format = .mp4,
    fps: u32 = 30,
    quality: sink_mod.Quality = .medium,
    mic: bool = false,
    system: bool = false,
    gif_max_width: u32 = 800,
    dither: quantize.Dither = .ordered,
    vaapi: ?[:0]const u8 = null,
    /// the logical area to keep, inside the stream's logical rect; null
    /// keeps the whole stream
    crop: ?region.Rect = null,
    stream_rect: region.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
};

pub const Done = struct {
    frames: u64,
    duration_ms: i64,
    width: u32,
    height: u32,
    backend: sink_mod.Backend,
    /// the first picture, src_w x src_h (owned by the engine)
    first: []const u32,
    src_w: u32,
    src_h: u32,
};

fn monoNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const Tap = struct { engine: *Engine, which: usize };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    envp: proc.Envp,
    opts: Options,
    path: [:0]const u8,
    latest: frames_mod.Latest,
    mixer: *audio.Mixer,
    taps: [2]Tap = undefined,
    clock_mutex: sync.Mutex = .{},
    tl: timeline.Timeline = .{},
    /// media time at which the recording ends (set by stop)
    end_ns: ?i64 = null,
    stopping: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),
    video_thread: ?std.Thread = null,
    audio_thread: ?std.Thread = null,
    sink: ?sink_mod.Sink = null,
    sink_ready: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    // results
    frames: u64 = 0,
    out_w: u32 = 0,
    out_h: u32 = 0,
    first: []u32 = &.{},
    strip: strip_mod.Strip,

    /// Start recording `node` of `cap` into `path` (created by the sink).
    pub fn start(gpa: std.mem.Allocator, envp: proc.Envp, cap: *pwstream.Capture, node: u32, path: [:0]const u8, opts: Options) !*Engine {
        const self = try gpa.create(Engine);
        errdefer gpa.destroy(self);
        const mixer = try gpa.create(audio.Mixer);
        errdefer gpa.destroy(mixer);
        mixer.* = .{};
        self.* = .{
            .gpa = gpa,
            .envp = envp,
            .opts = opts,
            .path = path,
            .latest = .{ .gpa = gpa, .crop = opts.crop, .stream_rect = opts.stream_rect },
            .mixer = mixer,
            .strip = .{ .gpa = gpa },
        };
        try cap.addVideo(node, frames_mod.Latest.onVideo, &self.latest);
        self.addAudio(cap);
        self.video_thread = try std.Thread.spawn(.{}, videoMain, .{self});
        return self;
    }

    fn addAudio(self: *Engine, cap: *pwstream.Capture) void {
        const srcs = [_]struct { on: bool, src: pwstream.AudioSource }{ .{ .on = self.opts.mic, .src = .mic }, .{ .on = self.opts.system, .src = .system } };
        for (srcs, 0..) |s, i| {
            if (!s.on or self.opts.format == .gif) continue;
            self.taps[i] = .{ .engine = self, .which = i };
            cap.addAudio(s.src, onAudio, &self.taps[i]) catch |err| {
                std.log.warn("recording: no {t} sound: {t}", .{ s.src, err });
                continue;
            };
            self.mixer.enable(i);
        }
    }

    fn hasAudio(self: *const Engine) bool {
        for (self.mixer.sources) |s| if (s.active) return true;
        return false;
    }

    fn onAudio(ctx: *anyopaque, samples: []const i16, t: i64) void {
        const tap: *Tap = @ptrCast(@alignCast(ctx));
        const e = tap.engine;
        e.clock_mutex.lock();
        const at = e.tl.mediaOf(t);
        e.clock_mutex.unlock();
        if (at) |m| e.mixer.push(tap.which, samples, m);
    }

    pub fn deinit(self: *Engine) void {
        self.latest.deinit();
        self.strip.deinit();
        self.gpa.free(self.first);
        self.gpa.destroy(self.mixer);
        self.gpa.destroy(self);
    }

    pub fn pause(self: *Engine) void {
        self.clock_mutex.lock();
        defer self.clock_mutex.unlock();
        self.tl.pause(monoNs());
    }

    pub fn unpause(self: *Engine) void {
        self.clock_mutex.lock();
        defer self.clock_mutex.unlock();
        self.tl.unpause(monoNs());
    }

    pub fn paused(self: *Engine) bool {
        self.clock_mutex.lock();
        defer self.clock_mutex.unlock();
        return self.tl.paused();
    }

    /// Recorded time so far, ms (0 until the first picture).
    pub fn elapsedMs(self: *Engine) i64 {
        self.clock_mutex.lock();
        defer self.clock_mutex.unlock();
        return @divTrunc(self.tl.media(monoNs()), std.time.ns_per_ms);
    }

    /// Whether the first picture arrived and the encoder runs.
    pub fn started(self: *const Engine) bool {
        return self.sink_ready.load(.acquire);
    }

    /// A failure on the encoder thread (the recording stopped).
    pub fn failed(self: *const Engine) ?anyerror {
        if (self.stopping.load(.acquire)) return null;
        return @atomicLoad(?anyerror, &self.err, .acquire);
    }

    fn media(self: *Engine) i64 {
        self.clock_mutex.lock();
        defer self.clock_mutex.unlock();
        return self.tl.media(monoNs());
    }

    /// Finish the file. The engine's results stay valid until deinit.
    pub fn stop(self: *Engine) !Done {
        self.clock_mutex.lock();
        self.end_ns = self.tl.media(monoNs());
        self.clock_mutex.unlock();
        self.stopping.store(true, .release);
        self.latest.arrived.signal();
        if (self.video_thread) |t| t.join();
        self.video_thread = null;
        if (self.err) |e| return e;
        return .{
            .frames = self.frames,
            .duration_ms = @intCast(self.frames * 1000 / self.opts.fps),
            .width = self.out_w,
            .height = self.out_h,
            .backend = self.sink.?.backend,
            .first = self.first,
            .src_w = self.latest.width,
            .src_h = self.latest.height,
        };
    }

    /// Stop and delete what was written.
    pub fn discard(self: *Engine) void {
        self.abort.store(true, .release);
        _ = self.stop() catch {};
        sys.unlink(self.path) catch {};
    }

    // --- the picture thread

    fn videoMain(self: *Engine) void {
        self.videoLoop() catch |err| {
            std.log.warn("recording: stopped: {t}", .{err});
            @atomicStore(?anyerror, &self.err, err, .release);
            if (self.sink) |*s| s.abort();
            self.sink = null;
        };
        if (self.audio_thread) |t| t.join();
        self.audio_thread = null;
    }

    fn waitFirst(self: *Engine) !void {
        const deadline = sys.monoMs() + 10_000;
        var seen = self.latest.arrived.current();
        while (self.latest.received() == 0) {
            if (self.stopping.load(.acquire)) return error.Stopped;
            if (sys.monoMs() > deadline) return error.NoPicture;
            seen = self.latest.arrived.waitPast(seen, 100);
        }
    }

    fn videoLoop(self: *Engine) !void {
        try self.waitFirst();
        self.clock_mutex.lock();
        self.tl.start(monoNs());
        self.clock_mutex.unlock();
        const sw = self.latest.width;
        const sh = self.latest.height;
        const out = switch (self.opts.format) {
            .mp4 => region.evenSize(sw, sh),
            .gif => region.gifSize(sw, sh, self.opts.gif_max_width),
        };
        self.out_w = out[0];
        self.out_h = out[1];
        const scaled: []u32 = if (self.opts.format == .gif and out[0] != sw) try self.gpa.alloc(u32, @as(usize, out[0]) * out[1]) else &.{};
        defer self.gpa.free(scaled);
        self.sink = try sink_mod.Sink.open(self.gpa, self.envp, self.path, .{
            .format = self.opts.format,
            .width = out[0],
            .height = out[1],
            .fps = self.opts.fps,
            .quality = self.opts.quality,
            .audio = self.hasAudio(),
            .dither = self.opts.dither,
            .vaapi = self.opts.vaapi,
        });
        self.sink_ready.store(true, .release);
        std.log.info("recording: {d}x{d} at {d} fps, {s}", .{ out[0], out[1], self.opts.fps, self.sink.?.backend.label() });
        if (self.sink.?.has_audio) self.audio_thread = try std.Thread.spawn(.{}, audioMain, .{self});
        try self.pump(sw, sh, scaled);
        if (self.abort.load(.acquire)) {
            self.sink.?.abort();
            return;
        }
        if (self.audio_thread) |t| t.join();
        self.audio_thread = null;
        try self.sink.?.finish(self.frames);
    }

    /// Emit frames on the grid until stopped.
    fn pump(self: *Engine, sw: u32, sh: u32, scaled: []u32) !void {
        var pacer: timeline.Pacer = .{ .fps = self.opts.fps };
        var last_count: u64 = 0;
        var px: []const u32 = &.{};
        var last_idx: u64 = 0;
        while (true) {
            const stopping = self.stopping.load(.acquire);
            const now_media = if (stopping) (self.end_ns orelse self.media()) else self.media();
            if (stopping and self.abort.load(.acquire)) return;
            var due = pacer.due(now_media);
            if (stopping and due > 0) due -= 1; // the end itself is not a frame
            if (due == 0) {
                if (stopping) break;
                const wait_ns = pacer.nextAt() - now_media;
                _ = self.latest.arrived.waitPast(self.latest.arrived.current(), @intCast(std.math.clamp(@divTrunc(wait_ns, std.time.ns_per_ms), 1, 50)));
                continue;
            }
            const count = self.latest.received();
            const fresh = count != last_count;
            if (fresh) px = self.latest.acquire().?;
            last_count = count;
            var k: u64 = 0;
            while (k < due) : (k += 1) {
                const idx = pacer.next;
                // an unchanged picture is only written where the encoder
                // needs every frame (the ffmpeg pipe) and at the very end
                if (fresh and k == due - 1) {
                    try self.emit(px, sw, sh, scaled, idx);
                    last_idx = idx;
                } else if (self.sink.?.needsEveryFrame()) {
                    try self.sink.?.repeat();
                }
                pacer.next += 1;
            }
            self.frames = pacer.next;
        }
        // the last picture shows until the end
        if (self.frames > 1 and last_idx < self.frames - 1 and self.opts.format == .mp4 and !self.sink.?.needsEveryFrame() and px.len > 0)
            try self.emit(px, sw, sh, scaled, self.frames - 1);
    }

    fn emit(self: *Engine, px: []const u32, sw: u32, sh: u32, scaled: []u32, idx: u64) !void {
        if (self.first.len == 0) self.first = try self.gpa.dupe(u32, px);
        self.strip.offer(idx, px, sw, sw, sh);
        if (scaled.len > 0) {
            yuv.downscale(px, sw, sw, sh, scaled, self.out_w, self.out_h);
            return self.sink.?.video(scaled, self.out_w, idx);
        }
        try self.sink.?.video(px, sw, idx);
    }

    // --- the sound thread

    fn audioMain(self: *Engine) void {
        const buf = self.gpa.alloc(i16, audio.rate * audio.channels / 2) catch return;
        defer self.gpa.free(buf);
        while (!self.stopping.load(.acquire)) {
            self.flushAudio(buf, self.media()) catch return;
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        if (self.abort.load(.acquire)) return;
        const end = self.end_ns orelse self.media();
        self.mixer.finishAt(end);
        self.flushAudio(buf, end) catch {};
    }

    fn flushAudio(self: *Engine, buf: []i16, at: i64) !void {
        while (true) {
            const n = self.mixer.take(buf, at);
            if (n == 0) return;
            try self.sink.?.audio(buf[0 .. n * audio.channels]);
        }
    }
};
