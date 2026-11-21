//! The event loop: waiting on the socket (waking for key repeats),
//! draining buffered events, and routing each Wayland event to the
//! component that owns its object.

const std = @import("std");
const sys = @import("../../platform/sys.zig");
const wl = @import("../../platform/wayland.zig");
const keyboard = @import("../keyboard.zig");
const window = @import("../window.zig");
const registry = @import("registry.zig");
const output = @import("output.zig");
const surface = @import("surface.zig");
const pointer = @import("pointer.zig");
const keys = @import("keys.zig");
const text_input = @import("text_input.zig");
const data_device = @import("data_device.zig");
const clipboard = @import("clipboard.zig");
const drag = @import("drag.zig");

const Window = window.Window;
const InputEvent = window.InputEvent;

/// Blocking: next logical input event (including synthesized key
/// repeats, which wake the wait when due).
pub fn nextEvent(w: *Window) !InputEvent {
    while (w.queue.items.len == 0) {
        _ = try waitAndDispatch(w, -1);
    }
    return w.queue.orderedRemove(0);
}

/// Like nextEvent but returns null after timeout_ms with no events.
pub fn nextEventTimeout(w: *Window, timeout_ms: i32) !?InputEvent {
    const deadline = keyboard.monotonicMs() + @max(0, timeout_ms);
    while (w.queue.items.len == 0) {
        const left = @max(0, deadline - keyboard.monotonicMs());
        const progressed = try waitAndDispatch(w, @intCast(left));
        if (!progressed and keyboard.monotonicMs() >= deadline) return null;
    }
    return w.queue.orderedRemove(0);
}

/// One wait step: queue a due key repeat, dispatch buffered events, or
/// poll the socket for at most max_ms (-1 = forever), waking early for
/// the next key repeat. Returns false when it timed out idle.
fn waitAndDispatch(w: *Window, max_ms: i32) !bool {
    try pumpRepeat(w);
    if (w.queue.items.len > 0) return true;
    try w.conn.flush();
    if (try w.conn.pollEvent()) |ev| {
        try handleEvent(w, ev);
        return true;
    }
    var fds = [_]sys.pollfd{.{ .fd = w.conn.fd, .events = sys.POLL.IN, .revents = 0 }};
    const n = try sys.poll(&fds, pollTimeoutMs(w, max_ms));
    if (n > 0) {
        try dispatchOne(w);
        return true;
    }
    try pumpRepeat(w);
    return w.queue.items.len > 0;
}

/// How long a caller that polls conn.fd itself may sleep: max_ms
/// (-1 = forever) shortened to the next pending key repeat. Such loops
/// should call drainPending() after waking so repeats get queued.
pub fn pollTimeoutMs(w: *const Window, max_ms: i32) i32 {
    const rep = w.kb.repeat.timeoutMs(keyboard.monotonicMs()) orelse return max_ms;
    const r: i32 = @intCast(@min(rep, std.math.maxInt(i32)));
    return if (max_ms < 0) r else @min(max_ms, r);
}

/// Queue a synthesized key press if the held key is due to repeat.
fn pumpRepeat(w: *Window) !void {
    const code = w.kb.repeat.due(keyboard.monotonicMs()) orelse return;
    var key = keys.translate(w, code, true, false);
    key.repeat = true;
    try w.queue.append(w.alloc, .{ .key = key });
}

/// Read and dispatch all events already buffered in the Wayland socket
/// without blocking, plus any due key repeat. Call before rendering to
/// get the latest input state.
pub fn drainPending(w: *Window) !void {
    while (try w.conn.pollEvent()) |ev| {
        try handleEvent(w, ev);
    }
    try pumpRepeat(w);
}

/// Block for one event and dispatch it.
pub fn dispatchOne(w: *Window) !void {
    const ev = try w.conn.readEvent();
    try handleEvent(w, ev);
}

/// Route one event to its object's owner. Unknown objects and opcodes
/// are skipped (the header carries the size).
pub fn handleEvent(w: *Window, ev: wl.Event) !void {
    var r = wl.ArgReader{ .data = ev.body };
    if (try routeConnection(w, ev, &r)) return;
    if (try routeSurfaces(w, ev, &r)) return;
    if (try routeDataTransfer(w, ev, &r)) return;
    try routeSeat(w, ev, &r);
}

/// wl_display errors, the registry and xdg_wm_base pings.
fn routeConnection(w: *Window, ev: wl.Event, r: *wl.ArgReader) !bool {
    if (ev.object == wl.wl_display.id) {
        // delete_id needs nothing: ids are not recycled
        if (ev.opcode == wl.wl_display.ev_error) return displayError(r);
    } else if (ev.object == w.globals.registry) {
        try registry.handleEvent(w, ev.opcode, r);
    } else if (ev.object == w.globals.wm_base and ev.opcode == wl.xdg_wm_base.ev_ping) {
        const serial = try r.uint();
        try w.conn.request(w.globals.wm_base, wl.xdg_wm_base.pong, &.{.{ .uint = serial }});
        try w.conn.flush();
    } else return false;
    return true;
}

fn displayError(r: *wl.ArgReader) !bool {
    const obj = try r.uint();
    const code = try r.uint();
    const msg = try r.string();
    std.log.err("wayland protocol error on object {d} code {d}: {s}", .{ obj, code, msg });
    return error.ProtocolError;
}

/// Our surfaces' objects and the outputs.
fn routeSurfaces(w: *Window, ev: wl.Event, r: *wl.ArgReader) !bool {
    if (surface.find(w, ev.object)) |f| {
        try surface.handleEvent(w, f.idx, f.kind, ev.opcode, r);
    } else if (w.outputs.slotOf(ev.object)) |slot| {
        try output.handleOutput(w, slot, ev.opcode, r);
    } else if (w.outputs.xdgSlotOf(ev.object)) |slot| {
        try output.handleXdgOutput(w, slot, ev.opcode, r);
    } else return false;
    return true;
}

/// The data device, its offers and our data sources.
fn routeDataTransfer(w: *Window, ev: wl.Event, r: *wl.ArgReader) !bool {
    if (ev.object == 0) return false;
    if (ev.object == w.data_device.id) {
        try data_device.handleEvent(w, ev.opcode, r);
    } else if (w.data_device.offerSlot(ev.object)) |slot| {
        try data_device.handleOffer(w, slot, ev.opcode, r);
    } else if (ev.object == w.clipboard.source) {
        try clipboard.handleSource(w, ev.opcode, r);
    } else if (ev.object == w.drag.source) {
        try drag.handleSource(w, ev.opcode, r);
    } else return false;
    return true;
}

/// The seat and its devices.
fn routeSeat(w: *Window, ev: wl.Event, r: *wl.ArgReader) !void {
    if (ev.object == 0) return;
    if (ev.object == w.globals.seat) {
        try registry.handleSeat(w, ev.opcode, r);
    } else if (ev.object == w.pointer.id) {
        try pointer.handleEvent(w, ev.opcode, r);
    } else if (ev.object == w.pointer.rel) {
        if (ev.opcode == 0) try pointer.handleRelative(w, r);
    } else if (ev.object == w.keys.id) {
        try keys.handleEvent(w, ev.opcode, r);
    } else if (ev.object == w.text_input.id) {
        try text_input.handleEvent(w, ev.opcode, r);
    }
}
