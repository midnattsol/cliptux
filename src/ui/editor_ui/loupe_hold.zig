//! When the magnifier's "while holding Ctrl" setting shows it: once Ctrl
//! has been held on its own for `delay_ms`; it goes the moment Ctrl comes
//! up. A key, click or wheel notch that is not the magnifier's own while
//! Ctrl is down makes it a shortcut (Ctrl+C, Ctrl+Z...): the magnifier
//! stays away until Ctrl is pressed again, so shortcuts never flash it.
//! Pure: the caller feeds it the keys and the clock.

const std = @import("std");

/// how long Ctrl is held before it shows
pub const delay_ms: i64 = 200;

pub const Hold = struct {
    /// Ctrl is down
    down: bool = false,
    /// when it went down, unless a shortcut was made with it since
    since_ms: ?i64 = null,

    /// Ctrl went down at `now` (a repeat while it is down changes nothing).
    pub fn press(self: *Hold, now: i64) void {
        if (self.down) return;
        self.* = .{ .down = true, .since_ms = now };
    }

    /// Ctrl came up.
    pub fn release(self: *Hold) void {
        self.* = .{};
    }

    /// Something else happened while Ctrl is down: a shortcut, not a hold.
    pub fn cancel(self: *Hold) void {
        self.since_ms = null;
    }

    /// Held long enough to show.
    pub fn shown(self: Hold, now: i64) bool {
        const t = self.since_ms orelse return false;
        return now - t >= delay_ms;
    }

    /// When it will show (0: it does already, or will not).
    pub fn dueMs(self: Hold, now: i64) i64 {
        const t = self.since_ms orelse return 0;
        return if (self.shown(now)) 0 else t + delay_ms;
    }
};

test "held on its own it shows after the delay, and goes on release" {
    var h: Hold = .{};
    h.press(1000);
    try std.testing.expect(!h.shown(1000 + delay_ms - 1));
    try std.testing.expectEqual(1000 + delay_ms, h.dueMs(1000));
    try std.testing.expect(h.shown(1000 + delay_ms));
    try std.testing.expectEqual(@as(i64, 0), h.dueMs(1000 + delay_ms));
    h.release();
    try std.testing.expect(!h.shown(5000));
    try std.testing.expectEqual(@as(i64, 0), h.dueMs(5000));
}

test "a shortcut cancels it until Ctrl is pressed again" {
    var h: Hold = .{};
    h.press(1000);
    h.cancel();
    try std.testing.expect(!h.shown(1000 + delay_ms));
    try std.testing.expectEqual(@as(i64, 0), h.dueMs(1000));
    // still down: a repeat does not start it again
    h.press(1100);
    try std.testing.expect(!h.shown(2000));
    h.release();
    h.press(3000);
    try std.testing.expect(h.shown(3000 + delay_ms));
}

test "a shortcut once it shows hides it" {
    var h: Hold = .{};
    h.press(1000);
    try std.testing.expect(h.shown(1500));
    h.cancel();
    try std.testing.expect(!h.shown(1500));
}

test "a repeat while held keeps the first press's clock" {
    var h: Hold = .{};
    h.press(1000);
    h.press(1150);
    try std.testing.expect(h.shown(1000 + delay_ms));
}
