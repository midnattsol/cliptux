//! HiDPI: a surface's buffer size from its logical size and scale
//! (fractional-scale-v1 with a viewport, or an integer buffer scale).

const std = @import("std");
const wl = @import("../../platform/wayland.zig");
const window = @import("../window.zig");
const buffers = @import("buffers.zig");
const surface = @import("surface.zig");

const Window = window.Window;
const max_outputs = window.max_outputs;

/// Buffer size for a logical size. With fractional scaling the buffer is
/// logical * scale120 / 120 (rounded) and a viewport maps it back; without
/// it the buffer is logical * integer scale and set_buffer_scale is used.
pub fn bufferSize(logical_w: u32, logical_h: u32, scale120: u32, fractional: bool, int_scale: i32) [2]u32 {
    if (fractional) {
        return .{ (logical_w * scale120 + 60) / 120, (logical_h * scale120 + 60) / 120 };
    }
    const k: u32 = @intCast(@max(1, int_scale));
    return .{ logical_w * k, logical_h * k };
}

/// A surface that exactly covers one output gets a buffer of the output's
/// physical pixels. fractional-scale-v1 rounds the scale to 1/120 steps, so
/// logical * scale120 / 120 can miss the panel by a few pixels (1712 x 179/120
/// = 2554 on a 2560-pixel panel at 1.4953) and the compositor would then
/// resample the whole UI. Null when the surface does not match the output's
/// logical size or the mode is not plausibly that output at about `approx`.
pub fn outputBufferSize(logical_w: u32, logical_h: u32, approx: [2]u32, out_w: i32, out_h: i32, mode_w: i32, mode_h: i32) ?[2]u32 {
    if (out_w != @as(i64, logical_w) or out_h != @as(i64, logical_h) or mode_w <= 0 or mode_h <= 0) return null;
    // the mode is in the panel's native orientation; rotated outputs swap it
    var mw: u32 = @intCast(mode_w);
    var mh: u32 = @intCast(mode_h);
    if ((mw > mh) != (logical_w > logical_h) and mw != mh) std.mem.swap(u32, &mw, &mh);
    const close = struct {
        fn f(a: u32, b: u32) bool {
            const d = if (a > b) a - b else b - a;
            return d <= b / 100 + 2;
        }
    }.f;
    if (!close(mw, approx[0]) or !close(mh, approx[1])) return null;
    return .{ mw, mh };
}

/// Integer buffer scale: the compositor's preferred_buffer_scale when it
/// sent one, else the largest scale among the outputs the surface is on,
/// else the assigned output's, else 1.
pub fn pickIntScale(preferred: i32, entered_scales: []const i32, assigned: i32) i32 {
    if (preferred > 0) return preferred;
    var best: i32 = 0;
    for (entered_scales) |sc| best = @max(best, sc);
    if (best > 0) return best;
    return @max(1, assigned);
}

/// Recompute the physical buffer size from logical size and scale,
/// recreate buffers if needed, and pin the viewport destination.
pub fn applySize(w: *Window, idx: u8) !void {
    const s = &w.surfaces[idx];
    if (s.logical_w == 0 or s.logical_h == 0) return;
    const fractional = s.fs_obj != 0;
    if (!fractional) s.scale120 = @intCast(s.int_scale * 120);
    var size = bufferSize(s.logical_w, s.logical_h, s.scale120, fractional, s.int_scale);
    if (fractional) {
        if (w.outputs.covering(s)) |o| {
            if (outputBufferSize(s.logical_w, s.logical_h, size, o.logicalRect().w, o.logicalRect().h, o.mode_w, o.mode_h)) |px| size = px;
        }
    }
    if (size[0] == 0 or size[1] == 0) return;
    if (size[0] != s.width or size[1] != s.height or s.pool == 0) {
        try buffers.createBuffers(w, idx, size[0], size[1]);
    }
    if (s.viewport != 0) {
        try w.conn.request(s.viewport, wl.wp_viewport.set_destination, &.{
            .{ .int = @intCast(s.logical_w) },
            .{ .int = @intCast(s.logical_h) },
        });
    }
    if (idx == 0) surface.syncPrimary(w);
}

/// Integer-scale path (no wp_fractional_scale): follow the compositor's
/// preferred_buffer_scale or the outputs the surface is on.
pub fn updateIntScale(w: *Window, idx: u8) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.fs_obj != 0) return;
    var scales: [max_outputs]i32 = undefined;
    var n: usize = 0;
    var assigned: i32 = 1;
    for (w.outputs.list, 0..) |o, slot| {
        if (o.id == 0) continue;
        if (s.entered & (@as(u32, 1) << @intCast(slot)) != 0) {
            scales[n] = o.scale;
            n += 1;
        }
        if (o.global == s.output and s.output != 0) assigned = o.scale;
    }
    const k = pickIntScale(s.preferred_int, scales[0..n], assigned);
    if (k == s.int_scale) return;
    s.int_scale = k;
    s.scale120 = @intCast(k * 120);
    if (s.configured) {
        try applySize(w, idx);
        try w.conn.flush();
    }
    if (idx == 0) surface.syncPrimary(w);
}

test "a surface covering one output gets the output's pixels" {
    const t = std.testing;
    // 2560x1440 panel at 1.4953: logical 1712x963, scale120 179 -> 2554x1436
    const approx = bufferSize(1712, 963, 179, true, 1);
    try t.expectEqual([2]u32{ 2554, 1436 }, approx);
    try t.expectEqual([2]u32{ 2560, 1440 }, outputBufferSize(1712, 963, approx, 1712, 963, 2560, 1440).?);
    // rotated panel: the mode is reported in native orientation
    try t.expectEqual([2]u32{ 1440, 2560 }, outputBufferSize(963, 1712, .{ 1436, 2554 }, 963, 1712, 2560, 1440).?);
    // not covering the output, or an implausible mode: keep the computed size
    try t.expect(outputBufferSize(800, 600, .{ 1200, 900 }, 1712, 963, 2560, 1440) == null);
    try t.expect(outputBufferSize(1712, 963, approx, 1712, 963, 3840, 2160) == null);
    try t.expect(outputBufferSize(1712, 963, approx, 1712, 963, 0, 0) == null);
}

test "buffer size for fractional and integer scales" {
    const t = std.testing;
    // fractional 1.25 on 1280x720 logical
    try t.expectEqual([2]u32{ 1600, 900 }, bufferSize(1280, 720, 150, true, 1));
    // fractional 1.0
    try t.expectEqual([2]u32{ 800, 500 }, bufferSize(800, 500, 120, true, 1));
    // integer 2: exact multiple so set_buffer_scale is legal
    try t.expectEqual([2]u32{ 1200, 1820 }, bufferSize(600, 910, 240, false, 2));
    // nonsense scale clamps to 1
    try t.expectEqual([2]u32{ 600, 910 }, bufferSize(600, 910, 120, false, 0));
}

test "integer scale selection" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 3), pickIntScale(3, &.{ 1, 2 }, 1)); // preferred wins
    try t.expectEqual(@as(i32, 2), pickIntScale(0, &.{ 1, 2 }, 1)); // max entered
    try t.expectEqual(@as(i32, 2), pickIntScale(0, &.{}, 2)); // assigned output
    try t.expectEqual(@as(i32, 1), pickIntScale(0, &.{}, 0));
}
