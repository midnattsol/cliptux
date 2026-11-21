//! Small thread primitives on Linux futexes (std's need an Io instance,
//! which PipeWire's callback threads do not have): a mutex and an event
//! counter to wait on with a timeout.

const std = @import("std");
const linux = std.os.linux;

fn wait(addr: *const std.atomic.Value(u32), expect: u32, timeout_ms: ?u32) void {
    var ts: linux.timespec = undefined;
    const tp: ?*const linux.timespec = if (timeout_ms) |ms| blk: {
        ts = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
        break :blk &ts;
    } else null;
    _ = linux.futex_4arg(&addr.raw, .{ .cmd = .WAIT, .private = true }, expect, tp);
}

fn wake(addr: *const std.atomic.Value(u32), n: u32) void {
    _ = linux.futex_3arg(&addr.raw, .{ .cmd = .WAKE, .private = true }, n);
}

pub const Mutex = struct {
    /// 0 unlocked, 1 locked, 2 locked with waiters
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *Mutex) void {
        if (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (self.state.swap(2, .acquire) != 0) wait(&self.state, 2, null);
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(0, .release) == 2) wake(&self.state, 1);
    }
};

/// A counter bumped by `signal`; `waitPast(seen, ms)` sleeps until it
/// moves past `seen` or the time is up, and returns the current value.
pub const Event = struct {
    seq: std.atomic.Value(u32) = .init(0),

    pub fn signal(self: *Event) void {
        _ = self.seq.fetchAdd(1, .release);
        wake(&self.seq, std.math.maxInt(i32));
    }

    pub fn current(self: *const Event) u32 {
        return self.seq.load(.acquire);
    }

    pub fn waitPast(self: *Event, seen: u32, timeout_ms: u32) u32 {
        const now = self.seq.load(.acquire);
        if (now != seen) return now;
        wait(&self.seq, seen, timeout_ms);
        return self.seq.load(.acquire);
    }
};

test "mutex and event across threads" {
    const S = struct {
        m: Mutex = .{},
        ev: Event = .{},
        n: u64 = 0,
        fn work(self: *@This()) void {
            for (0..10_000) |_| {
                self.m.lock();
                self.n += 1;
                self.m.unlock();
            }
            self.ev.signal();
        }
    };
    var s: S = .{};
    const seen = s.ev.current();
    const t1 = try std.Thread.spawn(.{}, S.work, .{&s});
    const t2 = try std.Thread.spawn(.{}, S.work, .{&s});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u64, 20_000), s.n);
    try std.testing.expect(s.ev.waitPast(seen, 10) != seen);
}
