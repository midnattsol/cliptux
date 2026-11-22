//! The editor's own dim transition, in place of the compositor's window
//! effects (the GNOME extension turns those off for it): it opens on the
//! frozen frame exactly as the desktop looked and dims in; it closes by
//! easing everything it drew (dim, chrome, annotations) back to that
//! plain frame, so taking the window away afterwards changes nothing on
//! screen. Reduced motion makes both instant.

const std = @import("std");
const editor = @import("../editor.zig");
const motion = @import("../motion.zig");
const theme = @import("../theme.zig");
const view_mod = @import("../view.zig");
const shapes_mod = @import("../shapes.zig");

const Editor = editor.Editor;
const Rect = shapes_mod.Rect;

/// Both directions take this long.
pub const duration_ms = theme.motion_fast;

/// The fade-in's progress: when the first frame went out (0: not yet).
pub const Enter = struct {
    start_ms: i64 = 0,
    done: bool = false,
};

/// Still fading in (the loop keeps drawing frames).
pub fn entering(ed: *const Editor) bool {
    return !ed.enter.done and motion.enabled;
}

/// How far the fade-in is, 0..256, for the frame being drawn now; null
/// once it is over. Ending it marks every back buffer for a full
/// repaint, since the blended frames left traces in them.
pub fn enterLevel(ed: *Editor) ?u32 {
    if (ed.enter.done) return null;
    const now = motion.now();
    if (ed.enter.start_ms == 0) ed.enter.start_ms = now;
    const k = level(ed.enter.start_ms, now);
    if (k < 256) return k;
    ed.enter.done = true;
    for (ed.panes[0..ed.n_panes]) |*p| {
        if (!p.alive) continue;
        const all: Rect = .{ .x = 0, .y = 0, .w = @intCast(p.width), .h = @intCast(p.height) };
        for (&p.pending) |*q| q.add(all);
    }
    return null;
}

/// The frame just drawn into `px`, seen through the fade-in: the
/// undimmed view, turning into the frame as `k` goes to 256.
pub fn blendIn(ed: *Editor, px: []u32, k: u32) void {
    const p = ed.pn();
    if (p.viewc.len != px.len) return;
    mix(px, p.viewc, px, k);
}

/// 0..256 along the eased curve, `start` ms ago; 256 without motion.
fn level(start: i64, now: i64) u32 {
    if (!motion.enabled) return 256;
    const t = @as(f64, @floatFromInt(now - start)) / @as(f64, @floatFromInt(duration_ms));
    return @intFromFloat(@round(motion.easeOut(t) * 256));
}

/// dst = a + (b - a) * k / 256 per colour channel, opaque. dst may be b.
pub fn mix(dst: []u32, a: []const u32, b: []const u32, k: u32) void {
    @setRuntimeSafety(false);
    const ka = 256 - k;
    for (dst, a, b) |*d, pa, pb| {
        const rb = ((pa & 0x00FF00FF) * ka + (pb & 0x00FF00FF) * k) >> 8;
        const g = ((pa & 0x0000FF00) * ka + (pb & 0x0000FF00) * k) >> 8;
        d.* = 0xFF000000 | (rb & 0x00FF00FF) | (g & 0x0000FF00);
    }
}

/// Per pane: the last frame shown and the plain capture as it shows.
const Frames = struct {
    from: [editor.max_panes][]u32 = @splat(&.{}),
    plain: [editor.max_panes][]u32 = @splat(&.{}),
    shown: [editor.max_panes]bool = @splat(true),

    fn init(ed: *Editor) !Frames {
        var f: Frames = .{};
        errdefer f.deinit(ed.alloc);
        for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
            const n = @as(usize, p.width) * p.height;
            if (!p.alive or n == 0 or p.last_frame.len != n) continue;
            f.from[i] = try ed.alloc.dupe(u32, p.last_frame);
            f.plain[i] = try ed.alloc.alloc(u32, n);
            const all: Rect = .{ .x = 0, .y = 0, .w = @intCast(p.width), .h = @intCast(p.height) };
            view_mod.resample(ed.img.pixels, ed.img.width, ed.img.height, p.view, f.plain[i], p.width, p.height, all);
            f.shown[i] = false;
        }
        return f;
    }

    fn deinit(f: *Frames, alloc: std.mem.Allocator) void {
        for (&f.from, &f.plain) |a, b| {
            alloc.free(a);
            alloc.free(b);
        }
    }
};

/// Ease the editor back to the plain capture, then return with that
/// frame on screen; the window stays up (and lets clicks through) for
/// the caller to close.
pub fn out(ed: *Editor) !void {
    var frames = try Frames.init(ed);
    defer frames.deinit(ed.alloc);
    const surfs = ed.win.surfaceList();
    for (surfs, 0..) |s, i| if (s.alive) ed.win.setInputRegion(@intCast(i), &.{}) catch {};
    const start = motion.now();
    while (!allShown(&frames, ed.n_panes)) {
        const k = level(start, motion.now());
        try presentStep(ed, &frames, k);
        _ = try ed.win.nextEventTimeout(ed.win.pollTimeoutMs(8));
        ed.win.queue.clearRetainingCapacity();
    }
    try waitPresented(ed, 150);
}

/// A frame at `k` on every surface free to take one; the last one (k =
/// 256) marks the pane done.
fn presentStep(ed: *Editor, frames: *Frames, k: u32) !void {
    const surfs = ed.win.surfaceList();
    for (0..ed.n_panes) |i| {
        if (frames.shown[i] or i >= surfs.len or surfs[i].frame_pending) continue;
        const px = ed.win.backBufferOf(@intCast(i)) catch {
            frames.shown[i] = true;
            continue;
        };
        if (px.len != frames.from[i].len) {
            frames.shown[i] = true;
            continue;
        }
        mix(px, frames.from[i], frames.plain[i], k);
        try ed.win.presentSurface(@intCast(i));
        if (k >= 256) frames.shown[i] = true;
    }
}

fn allShown(frames: *const Frames, n: u8) bool {
    for (frames.shown[0..n]) |s| if (!s) return false;
    return true;
}

/// Until the compositor showed the last frames (or `max_ms` passed).
fn waitPresented(ed: *Editor, max_ms: i64) !void {
    const deadline = motion.now() + max_ms;
    while (motion.now() < deadline) {
        const pending = for (ed.win.surfaceList()) |s| {
            if (s.alive and s.frame_pending) break true;
        } else false;
        if (!pending) return;
        _ = try ed.win.nextEventTimeout(ed.win.pollTimeoutMs(@intCast(@max(1, deadline - motion.now()))));
        ed.win.queue.clearRetainingCapacity();
    }
}

test "mix goes from a to b" {
    var a = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var b = [_]u32{ 0xFFFFFFFF, 0xFF000000 };
    var d: [2]u32 = undefined;
    mix(&d, &a, &b, 0);
    try std.testing.expectEqualSlices(u32, &a, &d);
    mix(&d, &a, &b, 256);
    try std.testing.expectEqualSlices(u32, &b, &d);
    mix(&d, &a, &b, 128);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), d[0]);
    try std.testing.expectEqual(@as(u32, 0xFF7F7F7F), d[1]);
}
