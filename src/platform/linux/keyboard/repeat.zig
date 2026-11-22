//! Key repeat: a pure deadline tracker the window polls with a monotonic
//! clock (tests feed it a fake one).

const std = @import("std");
const linux = std.os.linux;

/// Deadline-based key repeat, driven by wl_keyboard.repeat_info. The window
/// asks `timeoutMs` how long it may sleep and calls `due` when it wakes.
pub const Repeat = struct {
    /// repeats per second; 0 disables repeat
    rate: i32 = 25,
    /// ms before the first repeat
    delay: i32 = 600,
    code: u32 = 0,
    next_ms: i64 = 0,
    active: bool = false,

    pub fn setInfo(self: *Repeat, rate: i32, delay: i32) void {
        self.rate = @max(0, rate);
        self.delay = @max(0, delay);
        if (self.rate == 0) self.stop();
    }

    /// A key went down: (re)arm for it, or stop when it does not repeat.
    pub fn press(self: *Repeat, code: u32, repeats: bool, now_ms: i64) void {
        if (!repeats or self.rate == 0) {
            // a non-repeating key (e.g. Shift) does not cancel the held one
            return;
        }
        self.code = code;
        self.active = true;
        self.next_ms = now_ms + self.delay;
    }

    pub fn release(self: *Repeat, code: u32) void {
        if (self.active and self.code == code) self.stop();
    }

    pub fn stop(self: *Repeat) void {
        self.active = false;
        self.code = 0;
    }

    fn interval(self: *const Repeat) i64 {
        return @max(1, @divTrunc(1000, @as(i64, @max(1, self.rate))));
    }

    /// Milliseconds until the next repeat is due (0 when overdue), or null
    /// when nothing is repeating.
    pub fn timeoutMs(self: *const Repeat, now_ms: i64) ?i64 {
        if (!self.active) return null;
        return @max(0, self.next_ms - now_ms);
    }

    /// The key to synthesize when a repeat is due. Emits at most one per
    /// call; a stalled loop skips the backlog instead of flooding.
    pub fn due(self: *Repeat, now_ms: i64) ?u32 {
        if (!self.active or now_ms < self.next_ms) return null;
        self.next_ms += self.interval();
        if (self.next_ms <= now_ms) self.next_ms = now_ms + self.interval();
        return self.code;
    }
};

pub fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const testing = std.testing;

test "repeat timing with a fake clock" {
    var r: Repeat = .{};
    r.setInfo(25, 400); // 40 ms interval
    try testing.expect(r.timeoutMs(0) == null);
    r.press(30, true, 1000);
    try testing.expectEqual(@as(?i64, 400), r.timeoutMs(1000));
    try testing.expect(r.due(1399) == null);
    try testing.expectEqual(@as(?u32, 30), r.due(1400));
    try testing.expect(r.due(1420) == null);
    try testing.expectEqual(@as(?u32, 30), r.due(1440));
    // a stalled loop gets one repeat, not a burst
    try testing.expectEqual(@as(?u32, 30), r.due(3000));
    try testing.expect(r.due(3000) == null);
    // a non-repeating key (Shift) does not cancel the held one
    r.press(42, false, 3000);
    try testing.expect(r.active and r.code == 30);
    // releasing another key keeps repeating; releasing the held one stops
    r.release(31);
    try testing.expect(r.active);
    r.release(30);
    try testing.expect(r.timeoutMs(3000) == null);
    // focus loss
    r.press(30, true, 0);
    r.stop();
    try testing.expect(r.due(10_000) == null);
    // rate 0 disables repeat
    r.setInfo(0, 100);
    r.press(30, true, 0);
    try testing.expect(r.due(10_000) == null);
}
