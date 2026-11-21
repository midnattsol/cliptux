//! Small ease-out transitions for UI chrome. Nothing here blocks: a Tween
//! is a value that moves toward its target over a short time, read when
//! a frame is drawn; the caller keeps drawing frames while any is active.
//!
//!   motion.enabled     false (reduced motion) makes every Tween jump
//!   Tween.to(v, now)   retarget from wherever it is now
//!   Tween.snap(v)      jump without a transition
//!   Tween.at(now)      current value;  Tween.busy(now): still moving

const std = @import("std");
const sys = @import("../platform/sys.zig");
const theme = @import("theme.zig");

/// Off when the desktop asks for reduced motion (or for scripted runs,
/// whose frame dumps must not depend on timing).
pub var enabled: bool = true;

pub fn now() i64 {
    return sys.monoMs();
}

/// Cubic ease-out on 0..1.
pub fn easeOut(t: f64) f64 {
    const k = 1.0 - std.math.clamp(t, 0, 1);
    return 1.0 - k * k * k;
}

pub const Tween = struct {
    from: f64 = 0,
    target: f64 = 0,
    start_ms: i64 = 0,
    dur_ms: i64 = theme.motion,

    pub fn snap(self: *Tween, v: f64) void {
        self.from = v;
        self.target = v;
        self.start_ms = 0;
    }

    /// Move toward `v`, starting from the current value.
    pub fn to(self: *Tween, v: f64, t: i64) void {
        if (v == self.target) return;
        if (!enabled) return self.snap(v);
        self.from = self.at(t);
        self.target = v;
        self.start_ms = t;
    }

    pub fn at(self: Tween, t: i64) f64 {
        if (self.start_ms == 0 or self.dur_ms <= 0) return self.target;
        const p = @as(f64, @floatFromInt(t - self.start_ms)) / @as(f64, @floatFromInt(self.dur_ms));
        if (p >= 1) return self.target;
        return self.from + (self.target - self.from) * easeOut(p);
    }

    pub fn busy(self: Tween, t: i64) bool {
        return self.start_ms != 0 and t - self.start_ms < self.dur_ms and self.from != self.target;
    }
};

test "tween eases toward its target and can be retargeted" {
    var tw: Tween = .{ .dur_ms = 100 };
    tw.snap(0);
    tw.to(10, 1000);
    try std.testing.expect(tw.busy(1050));
    const mid = tw.at(1050);
    try std.testing.expect(mid > 5 and mid < 10); // ease-out: past halfway
    try std.testing.expectEqual(@as(f64, 10), tw.at(1100));
    try std.testing.expect(!tw.busy(1100));
    tw.to(0, 1050);
    try std.testing.expectEqual(mid, tw.at(1050));
    enabled = false;
    defer enabled = true;
    tw.to(5, 1060);
    try std.testing.expectEqual(@as(f64, 5), tw.at(1060));
}
