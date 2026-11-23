//! When the magnifier's "when needed" setting shows it: not while the
//! pointer sweeps across the screen, but once it slows down to aim (below
//! `slow`) or rests (`rest_ms` without a move); it goes again when the
//! pointer speeds up (past `fast`: the gap keeps it from flickering at
//! one speed). Pure: the caller feeds it the pointer and the clock.

const std = @import("std");

/// logical px per second: below shows, above hides
pub const slow: f64 = 260;
pub const fast: f64 = 700;
/// a pointer still this long rests
pub const rest_ms: i64 = 200;
/// the speed follows each move's with this time constant
const smooth_ms: f64 = 50;
/// moves closer in time than this are summed with the next (events
/// drained together carry the same clock)
const min_step_ms: i64 = 8;

pub const Pace = struct {
    /// smoothed, logical px per second
    speed: f64 = 0,
    /// where the speed was last measured from, and when
    last: ?[2]f64 = null,
    last_ms: i64 = 0,
    /// slow enough (or resting) for the magnifier
    calm: bool = true,

    /// The pointer is at (`x`, `y`), logical px, at `now` (ms).
    pub fn move(self: *Pace, x: f64, y: f64, now: i64) void {
        const l = self.last orelse return self.restart(x, y, now);
        const dt = now - self.last_ms;
        if (dt >= rest_ms) return self.restart(x, y, now);
        if (dt < min_step_ms) return;
        const dtf: f64 = @floatFromInt(dt);
        const v = @sqrt((x - l[0]) * (x - l[0]) + (y - l[1]) * (y - l[1])) * 1000 / dtf;
        self.speed += (v - self.speed) * (1 - @exp(-dtf / smooth_ms));
        self.last = .{ x, y };
        self.last_ms = now;
        if (self.calm and self.speed > fast) self.calm = false;
        if (!self.calm and self.speed < slow) self.calm = true;
    }

    /// A pointer still since `rest_ms` rests: calm again.
    pub fn tick(self: *Pace, now: i64) void {
        if (self.calm or now - self.last_ms < rest_ms) return;
        self.calm = true;
        self.speed = 0;
    }

    /// When it would rest (0: already calm).
    pub fn dueMs(self: Pace) i64 {
        return if (self.calm) 0 else self.last_ms + rest_ms;
    }

    /// A fresh start at (`x`, `y`): after a rest, or the first move.
    fn restart(self: *Pace, x: f64, y: f64, now: i64) void {
        self.last = .{ x, y };
        self.last_ms = now;
        self.speed = 0;
    }
};

/// Moves of `step` px every `every` ms from `t0`, `n` of them, along x.
fn sweep(p: *Pace, t0: i64, step: f64, every: i64, n: usize) i64 {
    var t = t0;
    for (0..n) |i| {
        t += every;
        p.move(@as(f64, @floatFromInt(i + 1)) * step, 0, t);
    }
    return t;
}

test "a fast sweep hides it, slowing down shows it again" {
    var p: Pace = .{};
    p.move(0, 0, 1000);
    try std.testing.expect(p.calm);
    // 40 px per 16 ms: 2500 px/s
    var t = sweep(&p, 1000, 40, 16, 6);
    try std.testing.expect(!p.calm);
    // 2 px per 16 ms: 125 px/s
    const x0 = p.last.?[0];
    for (0..12) |i| {
        t += 16;
        p.move(x0 + @as(f64, @floatFromInt(i + 1)) * 2, 0, t);
    }
    try std.testing.expect(p.calm);
}

test "a pointer that stops rests after a while, and says when" {
    var p: Pace = .{};
    p.move(0, 0, 1000);
    const t = sweep(&p, 1000, 40, 16, 6);
    try std.testing.expect(!p.calm);
    try std.testing.expectEqual(t + rest_ms, p.dueMs());
    p.tick(t + rest_ms - 1);
    try std.testing.expect(!p.calm);
    p.tick(t + rest_ms);
    try std.testing.expect(p.calm);
    try std.testing.expectEqual(@as(i64, 0), p.dueMs());
}

test "between the thresholds it keeps what it was" {
    var p: Pace = .{};
    p.move(0, 0, 1000);
    // 7 px per 16 ms: about 440 px/s, between slow and fast
    _ = sweep(&p, 1000, 7, 16, 20);
    try std.testing.expect(p.calm);
    var q: Pace = .{};
    q.move(0, 0, 1000);
    const t = sweep(&q, 1000, 40, 16, 6);
    try std.testing.expect(!q.calm);
    const x0 = q.last.?[0];
    for (0..20) |i| q.move(x0 + @as(f64, @floatFromInt(i + 1)) * 7, 0, t + 16 * @as(i64, @intCast(i + 1)));
    try std.testing.expect(!q.calm);
}

test "events with the same clock are summed with the next" {
    var p: Pace = .{};
    p.move(0, 0, 1000);
    p.move(30, 0, 1000);
    p.move(31, 0, 1016);
    // 31 px over 16 ms, not 30 px in no time
    var q: Pace = .{};
    q.move(0, 0, 1000);
    q.move(31, 0, 1016);
    try std.testing.expectEqual(q.speed, p.speed);
    try std.testing.expect(p.calm);
}
