//! Clocks, sleeps, poll deadlines, futexes and the kernel CSPRNG.

const std = @import("std");
const linux = std.os.linux;

fn clockNow(clock: linux.clockid_t) linux.timespec {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(clock, &ts);
    return ts;
}

fn toMs(ts: linux.timespec) i64 {
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Milliseconds on the monotonic clock; for deadlines.
pub fn monoMs() i64 {
    return toMs(clockNow(.MONOTONIC));
}

/// Seconds since the epoch (UTC).
pub fn realtimeSec() i64 {
    return clockNow(.REALTIME).sec;
}

/// Milliseconds since the epoch (UTC).
pub fn realtimeMs() i64 {
    return toMs(clockNow(.REALTIME));
}

/// Fill `buf` from the kernel CSPRNG.
pub fn getRandom(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) {
            // only fails on pre-3.17 kernels; fall back to the clock
            const t: u64 = @bitCast(monoMs() ^ (realtimeSec() << 20));
            for (buf[off..], 0..) |*b, i| b.* = @truncate(t >> @intCast((i % 8) * 8));
            return;
        }
        off += rc;
    }
}

/// Poll timeout until `deadline_ms` (monotonic), or -1 when there is none.
pub fn timeoutUntil(deadline_ms: ?i64) i32 {
    const d = deadline_ms orelse return -1;
    const left = d - monoMs();
    if (left <= 0) return 0;
    return @intCast(@min(left, std.math.maxInt(i32)));
}

/// Nanoseconds on the monotonic clock.
pub fn monoNs() i64 {
    const ts = clockNow(.MONOTONIC);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Sleep for `ms` milliseconds (restarted when a signal cuts it short).
pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (true) {
        var rem: linux.timespec = undefined;
        if (linux.errno(linux.nanosleep(&ts, &rem)) != .INTR) return;
        ts = rem;
    }
}

/// Sleep while `addr` holds `expect`, at most `timeout_ms` (forever when
/// null), or until futexWake; may also return spuriously.
pub fn futexWait(addr: *const std.atomic.Value(u32), expect: u32, timeout_ms: ?u32) void {
    var ts: linux.timespec = undefined;
    const tp: ?*const linux.timespec = if (timeout_ms) |ms| blk: {
        ts = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
        break :blk &ts;
    } else null;
    _ = linux.futex_4arg(&addr.raw, .{ .cmd = .WAIT, .private = true }, expect, tp);
}

/// Wake up to `n` threads in futexWait on `addr`.
pub fn futexWake(addr: *const std.atomic.Value(u32), n: u32) void {
    _ = linux.futex_3arg(&addr.raw, .{ .cmd = .WAKE, .private = true }, n);
}
