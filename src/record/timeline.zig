//! A recording's clock: media time (wall time minus pauses), which video
//! frame is due at a constant rate, and how sound chunks line up with it
//! (silence where capture lagged, samples dropped where it ran ahead), so
//! picture and sound stay in sync however the two streams arrive.

const std = @import("std");

pub const ns_per_s: i64 = 1_000_000_000;

pub const Timeline = struct {
    start_ns: ?i64 = null,
    paused_since: ?i64 = null,
    paused_total: i64 = 0,

    pub fn start(self: *Timeline, now: i64) void {
        self.* = .{ .start_ns = now };
    }

    pub fn pause(self: *Timeline, now: i64) void {
        if (self.start_ns != null and self.paused_since == null) self.paused_since = now;
    }

    pub fn unpause(self: *Timeline, now: i64) void {
        const p = self.paused_since orelse return;
        self.paused_total += now - p;
        self.paused_since = null;
    }

    pub fn paused(self: *const Timeline) bool {
        return self.paused_since != null;
    }

    /// Media time at `now`, ns; while paused, frozen where it stopped.
    pub fn media(self: *const Timeline, now: i64) i64 {
        const s = self.start_ns orelse return 0;
        const t = self.paused_since orelse now;
        return @max(0, t - s - self.paused_total);
    }

    /// Media time of an instant during the recording, or null when it
    /// falls in the current pause (or before the start).
    pub fn mediaOf(self: *const Timeline, at: i64) ?i64 {
        const s = self.start_ns orelse return null;
        if (at < s) return null;
        if (self.paused_since) |p| if (at >= p) return null;
        return at - s - self.paused_total;
    }
};

/// Frames at a constant rate: frame n shows from n / fps.
pub const Pacer = struct {
    fps: u32,
    /// frames emitted so far
    next: u64 = 0,

    /// How many frames are due by media time `t` and not emitted yet.
    pub fn due(self: *const Pacer, t: i64) u64 {
        const total: u64 = @intCast(@divFloor(@as(i128, t) * self.fps, ns_per_s) + 1);
        return if (total > self.next) total - self.next else 0;
    }

    /// Media time at which the next frame is due, ns.
    pub fn nextAt(self: *const Pacer) i64 {
        return @intCast(@divFloor(@as(i128, self.next) * ns_per_s, self.fps));
    }
};

/// What to do with a chunk of sound so it lands where it belongs.
pub const Fit = struct {
    /// frames of silence to write first
    pad: u64 = 0,
    /// frames to drop from the chunk's start
    skip: u64 = 0,
};

/// Sound position, in sample frames, against the media clock.
pub const AudioClock = struct {
    rate: u32,
    /// sample frames written so far
    written: u64 = 0,
    /// drift tolerated before correcting, sample frames (about 40 ms)
    slack: u64 = 0,

    pub fn init(rate: u32) AudioClock {
        return .{ .rate = rate, .slack = rate / 25 };
    }

    /// A chunk of `n` frames whose first sample was captured at media
    /// time `t` (ns). Small jitter is left alone; larger gaps become
    /// silence and overlaps are dropped.
    pub fn fit(self: *AudioClock, t: i64, n: u64) Fit {
        const at: u64 = @intCast(@divFloor(@as(i128, @max(t, 0)) * self.rate, ns_per_s));
        var f: Fit = .{};
        if (at > self.written + self.slack) {
            f.pad = at - self.written;
        } else if (at + self.slack < self.written) {
            f.skip = @min(n, self.written - at);
        }
        self.written += f.pad + (n - f.skip);
        return f;
    }

    /// Silence to add at the end so sound lasts as long as the picture.
    pub fn tail(self: *const AudioClock, media_ns: i64) u64 {
        const want: u64 = @intCast(@divFloor(@as(i128, @max(media_ns, 0)) * self.rate, ns_per_s));
        return if (want > self.written) want - self.written else 0;
    }
};

const ms = 1_000_000;

test "media time stops while paused" {
    var tl: Timeline = .{};
    tl.start(1000 * ms);
    try std.testing.expectEqual(@as(i64, 500 * ms), tl.media(1500 * ms));
    tl.pause(2000 * ms);
    try std.testing.expectEqual(@as(i64, 1000 * ms), tl.media(9000 * ms));
    try std.testing.expect(tl.mediaOf(2500 * ms) == null);
    tl.unpause(5000 * ms);
    try std.testing.expectEqual(@as(i64, 1500 * ms), tl.media(5500 * ms));
    try std.testing.expectEqual(@as(i64, 1200 * ms), tl.mediaOf(5200 * ms).?);
    try std.testing.expect(tl.mediaOf(500 * ms) == null);
}

test "the pacer emits frames on the grid" {
    var p: Pacer = .{ .fps = 30 };
    try std.testing.expectEqual(@as(u64, 1), p.due(0));
    p.next = 1;
    try std.testing.expectEqual(@as(u64, 0), p.due(33 * ms));
    try std.testing.expectEqual(@as(u64, 1), p.due(34 * ms));
    // a stall: every missed frame is due (the last picture repeats)
    try std.testing.expectEqual(@as(u64, 30), p.due(1000 * ms));
    p.next = 31;
    try std.testing.expectEqual(@as(i64, 1033333333), p.nextAt());
}

test "sound chunks are padded and trimmed into sync" {
    var a = AudioClock.init(48000);
    // starts 100 ms late: 4800 frames of silence first
    var f = a.fit(100 * ms, 480);
    try std.testing.expectEqual(@as(u64, 4800), f.pad);
    try std.testing.expectEqual(@as(u64, 5280), a.written);
    // on time (a few ms of jitter): untouched
    f = a.fit(112 * ms, 480);
    try std.testing.expectEqual(Fit{}, f);
    // arrives 100 ms early (overlap): dropped
    f = a.fit(20 * ms, 480);
    try std.testing.expectEqual(@as(u64, 480), f.skip);
    try std.testing.expectEqual(@as(u64, 5760), a.written);
    // the picture ran 1 s: the sound gets filled to 1 s
    try std.testing.expectEqual(@as(u64, 48000 - 5760), a.tail(1000 * ms));
}
