//! Filming a monitor for shotlet-drive's `film` and `cut` commands: every
//! frame the compositor sends, sampled down to a quarter of the size
//! each way and kept in memory; then each frame fitted as a cross-fade
//! between the first one and the last. A frame that is no such blend (a window effect scaling
//! a picture of the desktop over the desktop, a panel that went away) is
//! a ghost.

const std = @import("std");
const kit = @import("shotlet");
const pws = kit.pwstream;

/// Each side shrinks by this much (one pixel of each square).
pub const shrink = 4;
const max_frames = 400;
/// A pixel is off when a channel misses the fit by more than this.
const off_level = 10;
/// A frame is a ghost when more than this many per mille of its pixels
/// are off: a pointer's worth stays below it, a missing panel does not.
const ghost_permille = 3;

pub const Film = struct {
    gpa: std.mem.Allocator,
    cap: *pws.Capture,
    /// frames of fw x fh, one after another
    px: []u32,
    fw: u32 = 0,
    fh: u32 = 0,
    n: u32 = 0,
    full: bool = false,

    pub fn start(gpa: std.mem.Allocator, node: u32, w: u32, h: u32) !*Film {
        const f = try gpa.create(Film);
        errdefer gpa.destroy(f);
        const fw = w / shrink;
        const fh = h / shrink;
        const px = try std.heap.page_allocator.alloc(u32, @as(usize, fw) * fh * max_frames);
        errdefer std.heap.page_allocator.free(px);
        f.* = .{ .gpa = gpa, .cap = try pws.Capture.open(gpa, null), .px = px, .fw = fw, .fh = fh };
        errdefer f.cap.close(gpa);
        try f.cap.addVideo(node, onFrame, f);
        return f;
    }

    /// Frames so far (another thread adds them).
    pub fn count(f: *const Film) u32 {
        return @atomicLoad(u32, &f.n, .acquire);
    }

    pub fn stop(f: *Film) void {
        f.cap.close(f.gpa);
    }

    pub fn deinit(f: *Film) void {
        std.heap.page_allocator.free(f.px);
        f.gpa.destroy(f);
    }

    pub fn frame(f: *const Film, i: u32) []const u32 {
        const len = @as(usize, f.fw) * f.fh;
        return f.px[i * len ..][0..len];
    }

    fn onFrame(ctx: *anyopaque, raw: *const pws.Raw) void {
        const f: *Film = @ptrCast(@alignCast(ctx));
        const i = f.n;
        if (i >= max_frames or raw.width / shrink != f.fw or raw.height / shrink != f.fh) {
            f.full = true;
            return;
        }
        const len = @as(usize, f.fw) * f.fh;
        shrinkInto(f.px[i * len ..][0..len], raw, f.fw, f.fh);
        @atomicStore(u32, &f.n, i + 1, .release);
    }
};

/// Every `shrink`-th pixel of `raw` into `out` (fw x fh, 0xAARRGGBB):
/// cheap enough for PipeWire's thread at every frame, and a mix of two
/// pictures stays the same mix of their samples.
fn shrinkInto(out: []u32, raw: *const pws.Raw, fw: u32, fh: u32) void {
    const swap = raw.format == .RGBx or raw.format == .RGBA;
    for (0..fh) |y| {
        const row: [*]align(1) const u32 = @ptrCast(raw.base + (y * shrink + shrink / 2) * raw.stride);
        for (out[y * fw ..][0..fw], 0..) |*o, x| {
            const p = row[x * shrink + shrink / 2];
            o.* = 0xFF000000 | if (swap) (p & 0xFF00) | (p & 0xFF) << 16 | (p >> 16 & 0xFF) else p;
        }
    }
}

/// What the frames between the first and the last were.
pub const Verdict = struct {
    frames: u32 = 0,
    /// neither the first, the last nor a mix of the two
    ghosts: u32 = 0,
    /// a clean mix of the two, part way
    blends: u32 = 0,
    /// the frame with most pixels off, and how many per mille
    worst: u32 = 0,
    worst_permille: u32 = 0,
};

/// A box (x0, y0, x1, y1, in film pixels) left out of the fit.
pub const Mask = [4]u32;

/// Fit every frame as first * a + last * (1 - a).
pub fn judge(f: *const Film, n: u32, mask: ?Mask) Verdict {
    var v: Verdict = .{ .frames = n };
    if (n < 3) return v;
    const a = f.frame(0);
    const b = f.frame(n - 1);
    for (1..n - 1) |i| {
        const fit = fitFrame(f.frame(@intCast(i)), a, b, f.fw, mask);
        if (fit.permille > v.worst_permille) {
            v.worst_permille = fit.permille;
            v.worst = @intCast(i);
        }
        if (fit.permille > ghost_permille) {
            v.ghosts += 1;
        } else if (fit.mix > 0.03 and fit.mix < 0.97) {
            v.blends += 1;
        }
    }
    return v;
}

const Fit = struct { mix: f64, permille: u32 };

fn masked(i: usize, w: u32, mask: ?Mask) bool {
    const m = mask orelse return false;
    const x = i % w;
    const y = i / w;
    return x >= m[0] and y >= m[1] and x < m[2] and y < m[3];
}

fn channel(p: u32, c: u5) f64 {
    return @floatFromInt((p >> c) & 0xFF);
}

/// The best mix of `a` and `b` for `p`, and how much of `p` it misses.
fn fitFrame(p: []const u32, a: []const u32, b: []const u32, w: u32, mask: ?Mask) Fit {
    var num: f64 = 0;
    var den: f64 = 0;
    for (p, a, b, 0..) |pp, pa, pb, i| {
        if (masked(i, w, mask)) continue;
        inline for (.{ 0, 8, 16 }) |c| {
            const d = channel(pp, c) - channel(pb, c);
            const e = channel(pa, c) - channel(pb, c);
            num += d * e;
            den += e * e;
        }
    }
    const k = if (den > 0) std.math.clamp(num / den, 0, 1) else 0;
    var off: usize = 0;
    var all: usize = 0;
    for (p, a, b, 0..) |pp, pa, pb, i| {
        if (masked(i, w, mask)) continue;
        all += 1;
        inline for (.{ 0, 8, 16 }) |c| {
            const want = channel(pb, c) + k * (channel(pa, c) - channel(pb, c));
            if (@abs(channel(pp, c) - want) > off_level) {
                off += 1;
                break;
            }
        }
    }
    return .{ .mix = k, .permille = @intCast(if (all == 0) 0 else off * 1000 / all) };
}

test "a cross-fade is a blend, a shifted picture a ghost" {
    const gpa = std.testing.allocator;
    const w = 40;
    const len = w * 10;
    var px = try gpa.alloc(u32, len * 4);
    defer gpa.free(px);
    for (0..len) |i| {
        const v: u32 = @intCast((i * 37) % 251);
        px[i] = 0xFF000000 | v << 16 | v << 8 | v; // first
        px[3 * len + i] = 0xFF101010; // last
        const m = (v + 0x10) / 2;
        px[len + i] = 0xFF000000 | m << 16 | m << 8 | m; // half way
        const s: u32 = @intCast(((i + 7) * 37) % 251);
        px[2 * len + i] = 0xFF000000 | s << 16 | s << 8 | s; // moved
    }
    const film: Film = .{ .gpa = gpa, .cap = undefined, .px = px, .fw = w, .fh = 10, .n = 4 };
    const v = judge(&film, 4, null);
    try std.testing.expectEqual(@as(u32, 1), v.blends);
    try std.testing.expectEqual(@as(u32, 1), v.ghosts);
    try std.testing.expectEqual(@as(u32, 2), v.worst);
}
