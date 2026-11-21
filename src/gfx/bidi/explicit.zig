//! Explicit embeddings, overrides and isolates (UAX #9 X1-X10).

const std = @import("std");
const classes = @import("classes.zig");
const sequence = @import("sequence.zig");
const Class = classes.Class;

pub const max_depth = 125;

const none = std.math.maxInt(u32);

/// X1-X10 with explicit codes present. False when scratch runs out (the
/// caller then ignores the codes).
pub fn resolveExplicit(cps: []const u21, para: u1, types: []Class, levels: []u8) bool {
    const n = cps.len;
    var mem: [16384]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&mem, std.heap.page_allocator);
    const a = bfa.allocator();
    // BD9: isolate initiator -> matching PDI
    const match = a.alloc(u32, n) catch return false;
    defer a.free(match);
    @memset(match, none);
    const matched_pdi = a.alloc(bool, n) catch return false;
    defer a.free(matched_pdi);
    @memset(matched_pdi, false);
    matchIsolates(a, types, match, matched_pdi) catch return false;

    explicitLevels(cps, para, types, levels, match);

    // X10: level runs joined across isolates into isolating run sequences
    // (found on the explicit levels; `levels` receives the final ones)
    const xl = a.dupe(u8, levels) catch return false;
    defer a.free(xl);
    const idx = a.alloc(u32, n) catch return false;
    defer a.free(idx);
    const seq_cps = a.alloc(u21, n) catch return false;
    defer a.free(seq_cps);
    const seq_types = a.alloc(Class, n) catch return false;
    defer a.free(seq_types);
    const runs: Runs = .{
        .cps = cps,
        .para = para,
        .xl = xl,
        .match = match,
        .matched_pdi = matched_pdi,
        .idx = idx,
        .seq_cps = seq_cps,
        .seq_types = seq_types,
    };
    runs.resolve(types, levels);
    return true;
}

/// BD9: index of the matching PDI for every isolate initiator that has
/// one, and which PDIs are matched.
fn matchIsolates(a: std.mem.Allocator, types: []const Class, match: []u32, matched_pdi: []bool) !void {
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    for (types, 0..) |t, i| {
        if (classes.isIsolateInit(t)) {
            try stack.append(a, @intCast(i));
        } else if (t == .PDI) {
            if (stack.pop()) |o| {
                match[o] = @intCast(i);
                matched_pdi[i] = true;
            }
        }
    }
}

/// X1-X8: explicit levels into `levels`; embedding and override codes
/// become BN and overridden characters take the override's type.
fn explicitLevels(cps: []const u21, para: u1, types: []Class, levels: []u8, match: []const u32) void {
    var s: Stack = .{};
    s.entries[0] = .{ .level = para, .override = null, .isolate = false };
    for (types, 0..) |*t, i| {
        const top = s.top();
        switch (t.*) {
            .RLE, .LRE, .RLO, .LRO => {
                levels[i] = top.level;
                s.pushEmbedding(t.*);
                t.* = .BN;
            },
            .RLI, .LRI, .FSI => {
                levels[i] = top.level;
                const rtl = isolateIsRtl(cps, t.*, i, match);
                if (top.override) |o| t.* = o;
                s.pushIsolate(rtl);
            },
            .PDI => {
                s.popIsolate();
                const cur = s.top();
                levels[i] = cur.level;
                if (cur.override) |o| t.* = o;
            },
            .PDF => {
                s.popEmbedding();
                levels[i] = s.top().level;
                t.* = .BN;
            },
            .B => levels[i] = para,
            .BN => levels[i] = top.level,
            else => {
                levels[i] = top.level;
                if (top.override) |o| t.* = o;
            },
        }
    }
}

/// Direction of the isolate opened by `t` at `i` (FSI: its first strong
/// character up to the matching PDI).
fn isolateIsRtl(cps: []const u21, t: Class, i: usize, match: []const u32) bool {
    if (t != .FSI) return t == .RLI;
    const end = if (match[i] != none) match[i] else cps.len;
    return (classes.firstStrong(cps[i + 1 .. end]) orelse 0) == 1;
}

/// Least odd (`rtl`) or even level above `level`.
fn nextLevel(level: u8, rtl: bool) u8 {
    return if (rtl) (level + 1) | 1 else (level + 2) & ~@as(u8, 1);
}

const Entry = struct { level: u8, override: ?Class, isolate: bool };

/// The directional status stack and overflow counters of X1-X8.
const Stack = struct {
    entries: [max_depth + 2]Entry = undefined,
    sp: usize = 1,
    overflow_isolate: usize = 0,
    overflow_embed: usize = 0,
    valid_isolate: usize = 0,

    fn top(s: *const Stack) Entry {
        return s.entries[s.sp - 1];
    }

    fn push(s: *Stack, e: Entry) void {
        s.entries[s.sp] = e;
        s.sp += 1;
    }

    fn canPush(s: *const Stack, level: u8) bool {
        return level <= max_depth and s.overflow_isolate == 0 and s.overflow_embed == 0;
    }

    /// X2-X5: RLE, LRE, RLO, LRO.
    fn pushEmbedding(s: *Stack, t: Class) void {
        const next = nextLevel(s.top().level, t == .RLE or t == .RLO);
        if (s.canPush(next)) {
            const override: ?Class = if (t == .RLO) .R else if (t == .LRO) .L else null;
            s.push(.{ .level = next, .override = override, .isolate = false });
        } else if (s.overflow_isolate == 0) s.overflow_embed += 1;
    }

    /// X5a-X5c: RLI, LRI, FSI.
    fn pushIsolate(s: *Stack, rtl: bool) void {
        const next = nextLevel(s.top().level, rtl);
        if (s.canPush(next)) {
            s.valid_isolate += 1;
            s.push(.{ .level = next, .override = null, .isolate = true });
        } else s.overflow_isolate += 1;
    }

    /// X6a: a PDI closes the innermost valid isolate.
    fn popIsolate(s: *Stack) void {
        if (s.overflow_isolate > 0) {
            s.overflow_isolate -= 1;
        } else if (s.valid_isolate > 0) {
            s.overflow_embed = 0;
            while (!s.entries[s.sp - 1].isolate) s.sp -= 1;
            s.sp -= 1;
            s.valid_isolate -= 1;
        }
    }

    /// X7: a PDF closes the innermost embedding or override.
    fn popEmbedding(s: *Stack) void {
        if (s.overflow_isolate > 0) {} else if (s.overflow_embed > 0) {
            s.overflow_embed -= 1;
        } else if (!s.top().isolate and s.sp >= 2) s.sp -= 1;
    }
};

/// X10 over the explicit levels `xl`; `idx`, `seq_cps` and `seq_types`
/// are scratch of the text's length.
const Runs = struct {
    cps: []const u21,
    para: u1,
    xl: []const u8,
    match: []const u32,
    matched_pdi: []const bool,
    idx: []u32,
    seq_cps: []u21,
    seq_types: []Class,

    /// Resolve every isolating run sequence, writing final types and levels.
    fn resolve(r: Runs, types: []Class, levels: []u8) void {
        const n = r.cps.len;
        var start: usize = 0;
        while (start < n) {
            const end = r.runEnd(start);
            defer start = end;
            // a run starting with a matched PDI continues an earlier sequence
            if (r.matched_pdi[start]) continue;
            r.resolveOne(r.collect(start, end), types, levels);
        }
    }

    /// End of the level run starting at `start`.
    fn runEnd(r: Runs, start: usize) usize {
        var end = start + 1;
        while (end < r.xl.len and r.xl[end] == r.xl[start]) end += 1;
        return end;
    }

    /// Indices of the sequence beginning with the level run [start, end),
    /// following isolate initiators to their matching PDIs.
    fn collect(r: Runs, start: usize, end: usize) []u32 {
        var m: usize = 0;
        var rs = start;
        var re = end;
        while (true) {
            for (rs..re) |k| {
                r.idx[m] = @intCast(k);
                m += 1;
            }
            const last = re - 1;
            if (!classes.isIsolateInit(classes.class(r.cps[last])) or r.match[last] == none) break;
            rs = r.match[last];
            re = r.runEnd(rs);
        }
        return r.idx[0..m];
    }

    /// W1-I2 on the sequence `seq`, with sos / eos from the neighbouring
    /// levels.
    fn resolveOne(r: Runs, seq: []const u32, types: []Class, levels: []u8) void {
        const m = seq.len;
        const lv = r.xl[seq[0]];
        const sos: u1 = @intCast(@max(lv, r.levelBefore(seq[0])) % 2);
        const eos: u1 = @intCast(@max(lv, r.levelAfter(seq[m - 1])) % 2);
        for (seq, 0..) |q, j| {
            r.seq_cps[j] = r.cps[q];
            r.seq_types[j] = types[q];
        }
        sequence.resolveSequence(r.seq_cps[0..m], r.seq_types[0..m], sos, eos, @intCast(lv % 2));
        for (seq, 0..) |q, j| {
            types[q] = r.seq_types[j];
            levels[q] = sequence.implicitLevel(lv, r.seq_types[j]);
        }
    }

    /// Level of the last character before `first` that X9 keeps, or the
    /// paragraph level.
    fn levelBefore(r: Runs, first: u32) u8 {
        var k = first;
        while (k > 0) {
            k -= 1;
            if (!classes.isRemoved(classes.class(r.cps[k]))) return r.xl[k];
        }
        return r.para;
    }

    /// Level of the first character after `last` that X9 keeps, or the
    /// paragraph level (also after an unmatched isolate initiator).
    fn levelAfter(r: Runs, last: u32) u8 {
        if (classes.isIsolateInit(classes.class(r.cps[last]))) return r.para;
        var q = last + 1;
        while (q < r.cps.len) : (q += 1) {
            if (!classes.isRemoved(classes.class(r.cps[q]))) return r.xl[q];
        }
        return r.para;
    }
};
