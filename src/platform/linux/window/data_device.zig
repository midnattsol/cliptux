//! The seat's wl_data_device: the data offers other clients make (the
//! clipboard selection or a drag over us), reading the clipboard, and
//! taking drops onto our surfaces (Window.accept_mimes).

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const transfer = @import("../../../ui/transfer.zig");

const Window = window.Window;

/// What a drop onto one of our surfaces delivered (Window.accept_mimes).
pub const Dropped = struct {
    mime: []const u8,
    data: []u8,
};

/// A wl_data_offer and which plain-text types it carries (best first).
const Offer = struct {
    id: u32 = 0,
    /// bit 0: text/plain;charset=utf-8, 1: UTF8_STRING, 2: text/plain
    text: u3 = 0,
    /// bit i: accept_mimes[i] is offered
    accept: u8 = 0,
};

const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

pub const DataDevice = struct {
    /// wl_data_device; 0 without a data device manager
    id: u32 = 0,
    /// data offers the compositor announced (selection or drag), with the
    /// text types each one has; the selection is the clipboard's
    offers: [4]Offer = @splat(.{}),
    selection_offer: u32 = 0,
    /// the offer of a drag currently over one of our surfaces
    dnd_offer: u32 = 0,

    pub fn offerSlot(self: *const DataDevice, id: u32) ?usize {
        if (id == 0) return null;
        for (self.offers, 0..) |o, i| if (o.id == id) return i;
        return null;
    }

    /// A free slot, else the oldest offer that is not the selection.
    fn freeSlot(self: *const DataDevice) usize {
        var slot: usize = 0;
        for (self.offers, 0..) |o, i| {
            if (o.id == 0) return i;
            if (o.id != self.selection_offer) slot = i;
        }
        return slot;
    }
};

/// Create the seat's data device when a manager is offered.
pub fn ensureDevice(w: *Window) !void {
    const g = &w.globals;
    if (g.ddm == 0 or g.seat == 0 or w.data_device.id != 0) return;
    w.data_device.id = w.conn.newId();
    try w.conn.request(g.ddm, wl.wl_data_device_manager.get_data_device, &.{ .{ .new_id = w.data_device.id }, .{ .object = g.seat } });
}

fn dropOffer(w: *Window, slot: usize) void {
    const dd = &w.data_device;
    const id = dd.offers[slot].id;
    if (id == 0) return;
    w.conn.request(id, wl.wl_data_offer.destroy, &.{}) catch {};
    if (dd.selection_offer == id) dd.selection_offer = 0;
    dd.offers[slot] = .{};
}

/// wl_data_offer events: note the types we can take.
pub fn handleOffer(w: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
    if (opcode != wl.wl_data_offer.ev_offer) return;
    const offer = &w.data_device.offers[slot];
    const mime = try r.string();
    for (text_mimes, 0..) |m, i| {
        if (std.mem.eql(u8, mime, m)) offer.text |= @as(u3, 1) << @intCast(i);
    }
    for (w.accept_mimes[0..@min(8, w.accept_mimes.len)], 0..) |m, i| {
        if (std.mem.eql(u8, mime, m)) offer.accept |= @as(u8, 1) << @intCast(i);
    }
}

/// wl_data_device events.
pub fn handleEvent(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    const dd = &w.data_device;
    switch (opcode) {
        wl.wl_data_device.ev_data_offer => {
            const id = try r.uint();
            const slot = dd.freeSlot();
            dropOffer(w, slot);
            dd.offers[slot] = .{ .id = id };
        },
        wl.wl_data_device.ev_enter => {
            const serial = try r.uint();
            _ = try r.uint(); // surface
            _ = try r.fixed();
            _ = try r.fixed();
            dd.dnd_offer = try r.uint();
            try answerDragOffer(w, serial);
        },
        wl.wl_data_device.ev_leave => dd.dnd_offer = 0,
        wl.wl_data_device.ev_drop => try takeDrop(w),
        wl.wl_data_device.ev_selection => {
            const id = try r.uint();
            // the previous selection offer is dead once replaced
            for (dd.offers, 0..) |o, i| {
                if (o.id != 0 and o.id != id and o.id == dd.selection_offer) dropOffer(w, i);
            }
            dd.selection_offer = id;
        },
        else => {},
    }
}

/// The best of accept_mimes that offer `id` carries, if any.
fn acceptedMime(w: *const Window, id: u32) ?[]const u8 {
    const slot = w.data_device.offerSlot(id) orelse return null;
    const bits = w.data_device.offers[slot].accept;
    if (bits == 0) return null;
    return w.accept_mimes[@ctz(bits)];
}

/// Tell the drag source whether we take its data (and as what).
fn answerDragOffer(w: *Window, serial: u32) !void {
    const offer = w.data_device.dnd_offer;
    if (offer == 0 or w.accept_mimes.len == 0) return;
    const c = &w.conn;
    const mime = acceptedMime(w, offer);
    if (mime) |m| {
        try c.request(offer, wl.wl_data_offer.accept, &.{ .{ .uint = serial }, .{ .string = m } });
    } else {
        try c.request(offer, wl.wl_data_offer.accept, &.{ .{ .uint = serial }, .null_string });
    }
    if (w.globals.ddm_version >= 3) {
        const a: u32 = if (mime != null) wl.dnd_action_copy else 0;
        try c.request(offer, wl.wl_data_offer.set_actions, &.{ .{ .uint = a }, .{ .uint = a } });
    }
    try c.flush();
}

/// Read a drop's data into Window.dropped.
fn takeDrop(w: *Window) !void {
    const dd = &w.data_device;
    const id = dd.dnd_offer;
    const mime = acceptedMime(w, id) orelse return;
    const c = &w.conn;
    const fd = try receive(w, id, mime);
    defer sys.close(fd);
    const data = try transfer.readBounded(w.alloc, fd, 256 * 1024 * 1024, sys.monoMs() + 10_000);
    if (w.globals.ddm_version >= 3) try c.request(id, wl.wl_data_offer.finish, &.{});
    if (dd.offerSlot(id)) |slot| dropOffer(w, slot);
    dd.dnd_offer = 0;
    try c.flush();
    if (w.dropped) |d| w.alloc.free(d.data);
    w.dropped = .{ .mime = mime, .data = data };
}

/// Ask the owner of `offer` to write it as `mime` into a pipe; returns
/// the read end (the caller closes it).
fn receive(w: *Window, offer: u32, mime: []const u8) !sys.fd_t {
    const fds = try sys.pipe();
    errdefer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try w.conn.request(offer, wl.wl_data_offer.receive, &.{ .{ .string = mime }, .{ .fd = fds[1] } });
    try w.conn.flush(); // the fd travels with the flushed bytes
    return fds[0];
}

/// Plain text on the clipboard, or null when it holds none. Reads at
/// most `max_bytes` and gives up after `timeout_ms` so a stuck source
/// cannot freeze the UI. Caller owns the bytes.
pub fn clipboardText(w: *Window, alloc: std.mem.Allocator, max_bytes: usize, timeout_ms: i64) !?[]u8 {
    // our own text: answering our own receive would need this very loop
    if (w.clipboard.source != 0 and w.clipboard_text.len > 0)
        return try alloc.dupe(u8, w.clipboard_text[0..@min(max_bytes, w.clipboard_text.len)]);
    const dd = &w.data_device;
    const slot = dd.offerSlot(dd.selection_offer) orelse return null;
    const kinds = dd.offers[slot].text;
    if (kinds == 0) return null;
    const fd = try receive(w, dd.selection_offer, text_mimes[@ctz(kinds)]);
    defer sys.close(fd);
    return try transfer.readBounded(alloc, fd, max_bytes, sys.monoMs() + timeout_ms);
}

/// The clipboard's content in the first of accept_mimes it offers
/// (caller frees .data); null when it offers none of them.
pub fn clipboardAccepted(w: *Window, alloc: std.mem.Allocator, max_bytes: usize, timeout_ms: i64) !?Dropped {
    const offer = w.data_device.selection_offer;
    const mime = acceptedMime(w, offer) orelse return null;
    const fd = try receive(w, offer, mime);
    defer sys.close(fd);
    return .{ .mime = mime, .data = try transfer.readBounded(alloc, fd, max_bytes, sys.monoMs() + timeout_ms) };
}
