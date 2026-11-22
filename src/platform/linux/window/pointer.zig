//! The seat's pointer: enter/leave, motion and buttons in buffer pixels
//! of the surface under it, wheel scrolling gathered per pointer frame,
//! and relative motion (zwp_relative_pointer_v1).

const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const cursor = @import("cursor.zig");

const Window = window.Window;
const InputEvent = window.InputEvent;

pub const Pointer = struct {
    /// wl_pointer; 0 when the seat has none
    id: u32 = 0,
    /// zwp_relative_pointer_v1; 0 when not tracked
    rel: u32 = 0,
    /// relative motion summed until takeRelative()
    rel_sum: [2]f64 = .{ 0, 0 },
    /// position in buffer pixels of `surface`, the surface under it
    x: f64 = 0,
    y: f64 = 0,
    surface: u8 = 0,
    /// serial of the last enter, for set_cursor
    enter_serial: u32 = 0,
    /// vertical scroll gathered until the pointer frame
    axis_value: f64 = 0,
    axis_v120: ?i32 = null,
    axis_pending: bool = false,
};

/// Take the seat's pointer (and its relative pointer when tracked), or
/// let go of it when the seat lost it.
pub fn updateDevice(w: *Window, has_pointer: bool) !void {
    const c = &w.conn;
    const p = &w.pointer;
    if (has_pointer and p.id == 0) {
        p.id = c.newId();
        try c.request(w.globals.seat, wl.wl_seat.get_pointer, &.{.{ .new_id = p.id }});
        if (w.globals.rel_manager != 0 and w.track_relative) {
            p.rel = c.newId();
            // zwp_relative_pointer_manager_v1.get_relative_pointer
            try c.request(w.globals.rel_manager, 1, &.{ .{ .new_id = p.rel }, .{ .object = p.id } });
        }
    } else if (!has_pointer and p.id != 0) {
        if (p.rel != 0) {
            try c.request(p.rel, 0, &.{}); // destroy
            p.rel = 0;
        }
        if (w.globals.seat_version >= 3) try c.request(p.id, wl.wl_pointer.release, &.{});
        p.id = 0;
    }
}

/// Relative pointer motion since the last call (logical pixels); null
/// when the compositor has no zwp_relative_pointer_v1 (or
/// track_relative was not set before open()).
pub fn takeRelative(w: *Window) ?[2]f64 {
    if (w.pointer.rel == 0) return null;
    defer w.pointer.rel_sum = .{ 0, 0 };
    return w.pointer.rel_sum;
}

/// zwp_relative_pointer_v1.relative_motion: utime_hi, utime_lo, dx, dy
/// (accelerated: what the cursor moved), dx, dy unaccelerated.
pub fn handleRelative(w: *Window, r: *wl.ArgReader) !void {
    _ = try r.uint();
    _ = try r.uint();
    w.pointer.rel_sum[0] += try r.fixed();
    w.pointer.rel_sum[1] += try r.fixed();
}

/// wl_pointer events.
pub fn handleEvent(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_pointer.ev_leave => try onLeave(w),
        wl.wl_pointer.ev_enter => try onEnter(w, r),
        wl.wl_pointer.ev_motion => try onMotion(w, r),
        wl.wl_pointer.ev_button => try onButton(w, r),
        wl.wl_pointer.ev_axis => try onAxis(w, r),
        wl.wl_pointer.ev_axis_value120 => try onAxisValue120(w, r),
        wl.wl_pointer.ev_frame => try flushAxis(w),
        else => {},
    }
}

fn onLeave(w: *Window) !void {
    w.pointer_in = false;
    if (w.report_leave) try w.queue.append(w.alloc, .{ .pointer_motion = .{ .x = -1, .y = -1, .surface = w.pointer.surface } });
}

fn onEnter(w: *Window, r: *wl.ArgReader) !void {
    const p = &w.pointer;
    w.pointer_in = true;
    p.enter_serial = try r.uint();
    const surf = try r.uint();
    p.surface = surface.indexOf(w, surf) orelse 0;
    try readPosition(w, r);
    try cursor.apply(w);
}

fn onMotion(w: *Window, r: *wl.ArgReader) !void {
    const p = &w.pointer;
    _ = try r.uint(); // time
    try readPosition(w, r);
    const ev: InputEvent = .{ .pointer_motion = .{ .x = p.x, .y = p.y, .surface = p.surface } };
    // coalesce with a queued motion on the same surface
    if (w.queue.items.len > 0) {
        const last = &w.queue.items[w.queue.items.len - 1];
        if (last.* == .pointer_motion and last.pointer_motion.surface == p.surface) {
            last.* = ev;
            return;
        }
    }
    try w.queue.append(w.alloc, ev);
}

/// Surface-local logical position -> buffer pixels.
fn readPosition(w: *Window, r: *wl.ArgReader) !void {
    const f = bufferScale(w);
    w.pointer.x = (try r.fixed()) * f[0];
    w.pointer.y = (try r.fixed()) * f[1];
}

fn onButton(w: *Window, r: *wl.ArgReader) !void {
    const serial = try r.uint();
    _ = try r.uint(); // time
    const button = try r.uint();
    const state = try r.uint();
    w.input_serial = serial;
    try w.queue.append(w.alloc, .{ .pointer_button = .{
        .button = button,
        .pressed = state == 1,
        .x = w.pointer.x,
        .y = w.pointer.y,
        .surface = w.pointer.surface,
    } });
}

fn onAxis(w: *Window, r: *wl.ArgReader) !void {
    _ = try r.uint(); // time
    const axis = try r.uint();
    const value = try r.fixed();
    if (axis == 0) { // vertical
        w.pointer.axis_value += value;
        w.pointer.axis_pending = true;
        // before v5 there is no frame event to wait for
        if (w.globals.seat_version < 5) try flushAxis(w);
    }
}

fn onAxisValue120(w: *Window, r: *wl.ArgReader) !void {
    const axis = try r.uint();
    const v120 = try r.int();
    if (axis == 0) {
        w.pointer.axis_v120 = (w.pointer.axis_v120 orelse 0) + v120;
        w.pointer.axis_pending = true;
    }
}

/// One scroll event per pointer frame, carrying both the smooth value
/// and the wheel's exact notches when it sent them.
fn flushAxis(w: *Window) !void {
    const p = &w.pointer;
    if (!p.axis_pending) return;
    try w.queue.append(w.alloc, .{ .pointer_axis = .{ .value = p.axis_value, .value120 = p.axis_v120, .surface = p.surface } });
    p.axis_value = 0;
    p.axis_v120 = null;
    p.axis_pending = false;
}

/// Buffer pixels per logical pixel, per axis (see outputBufferSize:
/// the buffer is not always exactly logical * scale120 / 120).
fn bufferScale(w: *const Window) [2]f64 {
    const s = &w.surfaces[w.pointer.surface];
    if (s.logical_w == 0 or s.logical_h == 0 or s.width == 0 or s.height == 0) {
        const f = @as(f64, @floatFromInt(s.scale120)) / 120.0;
        return .{ f, f };
    }
    return .{
        @as(f64, @floatFromInt(s.width)) / @as(f64, @floatFromInt(s.logical_w)),
        @as(f64, @floatFromInt(s.height)) / @as(f64, @floatFromInt(s.logical_h)),
    };
}
