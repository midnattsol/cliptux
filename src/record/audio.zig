//! Sound for a recording: the microphone and the system sound, each put
//! in place on the media clock (timeline.AudioClock), mixed, and handed
//! to the encoder in order. A source that stops delivering (a suspended
//! sink's monitor sends nothing) is filled with silence so the other
//! never waits for it.

const std = @import("std");
const timeline = @import("timeline.zig");
const sync = @import("sync.zig");

pub const rate = 48000;
pub const channels = 2;
/// ring of each source: 2 s
const ring_frames = rate * 2;
/// a source this far behind the clock is filled with silence
const max_lag_ns = 200 * std.time.ns_per_ms;

pub const Source = struct {
    clock: timeline.AudioClock = timeline.AudioClock.init(rate),
    ring: [ring_frames * channels]i16 = undefined,
    active: bool = false,

    /// Append `n` frames (or silence when `samples` is null) at the end.
    fn put(self: *Source, samples: ?[]const i16, n: u64) void {
        var i: u64 = 0;
        const start = self.clock.written - n;
        while (i < n) : (i += 1) {
            const at = ((start + i) % ring_frames) * channels;
            if (samples) |s| {
                self.ring[at] = s[i * channels];
                self.ring[at + 1] = s[i * channels + 1];
            } else {
                self.ring[at] = 0;
                self.ring[at + 1] = 0;
            }
        }
    }
};

pub const Mixer = struct {
    mutex: sync.Mutex = .{},
    sources: [2]Source = .{ .{}, .{} },
    /// frames handed to the encoder so far
    out: u64 = 0,
    dropped: u64 = 0,

    pub fn enable(self: *Mixer, which: usize) void {
        self.sources[which].active = true;
    }

    /// A chunk from source `which` whose first frame is at media time `t`.
    pub fn push(self: *Mixer, which: usize, samples: []const i16, t: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = &self.sources[which];
        const n: u64 = samples.len / channels;
        const f = s.clock.fit(t, n);
        if (f.pad > 0) {
            const before = s.clock.written;
            s.clock.written -= n - f.skip;
            s.put(null, f.pad);
            s.clock.written = before;
        }
        s.put(samples[f.skip * channels ..], n - f.skip);
        // the encoder fell 2 s behind: the oldest sound is lost
        if (s.clock.written - self.out > ring_frames) {
            self.dropped += s.clock.written - ring_frames - self.out;
            self.out = s.clock.written - ring_frames;
        }
    }

    /// Fill sources lagging behind media time `t` with silence.
    fn padLagging(self: *Mixer, t: i64) void {
        for (&self.sources) |*s| {
            if (!s.active) continue;
            const want = s.clock.tail(t - max_lag_ns);
            if (want == 0) continue;
            s.clock.written += want;
            s.put(null, want);
        }
    }

    /// Mix what every active source has into `buf` (stereo frames);
    /// the number of frames. `media_ns`: now on the media clock.
    pub fn take(self: *Mixer, buf: []i16, media_ns: i64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.padLagging(media_ns);
        var avail: u64 = std.math.maxInt(u64);
        for (&self.sources) |*s| if (s.active) {
            avail = @min(avail, s.clock.written);
        };
        if (avail == std.math.maxInt(u64) or avail <= self.out) return 0;
        const n: usize = @intCast(@min(avail - self.out, buf.len / channels));
        for (0..n) |i| {
            const at = ((self.out + i) % ring_frames) * channels;
            for (0..channels) |c| {
                var acc: i32 = 0;
                for (&self.sources) |*s| if (s.active) {
                    acc += s.ring[at + c];
                };
                buf[i * channels + c] = @intCast(std.math.clamp(acc, -32768, 32767));
            }
        }
        self.out += n;
        return n;
    }

    /// Bring every source to `media_ns` with silence (the end).
    pub fn finishAt(self: *Mixer, media_ns: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.padLagging(media_ns + max_lag_ns);
    }
};

const ms = std.time.ns_per_ms;

test "two sources mix in sync, a silent one does not hold the other" {
    const gpa = std.testing.allocator;
    const m = try gpa.create(Mixer);
    defer gpa.destroy(m);
    m.* = .{};
    m.enable(0);
    m.enable(1);
    var a: [480 * 2]i16 = @splat(1000);
    var b: [480 * 2]i16 = @splat(-300);
    // mic from 0 ms, system from 50 ms (silence before it)
    for (0..10) |k| m.push(0, &a, @intCast(k * 10 * ms));
    m.push(1, &b, 50 * ms);
    var out: [48000 * 2]i16 = undefined;
    const n = m.take(&out, 100 * ms);
    // system has 50 ms + 10 ms: that much is mixed
    try std.testing.expectEqual(@as(usize, 2880), n);
    try std.testing.expectEqual(@as(i16, 1000), out[0]);
    try std.testing.expectEqual(@as(i16, 700), out[2400 * 2]);
    // system goes quiet; one second later its silence is filled in
    for (10..100) |k| m.push(0, &a, @intCast(k * 10 * ms));
    const more = m.take(&out, 1000 * ms);
    try std.testing.expect(more >= 48000 - 2880 - 48 * 200 - 480);
    try std.testing.expectEqual(@as(i16, 1000), out[more * 2 - 2]);
}

test "a lone source passes through" {
    const gpa = std.testing.allocator;
    const m = try gpa.create(Mixer);
    defer gpa.destroy(m);
    m.* = .{};
    m.enable(1);
    var a: [480 * 2]i16 = undefined;
    for (&a, 0..) |*x, i| x.* = @intCast(i);
    m.push(1, &a, 0);
    var out: [4800]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 480), m.take(&out, 10 * ms));
    try std.testing.expectEqualSlices(i16, &a, out[0..960]);
}
