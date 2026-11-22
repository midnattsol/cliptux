//! Dragging an image out of our surfaces (startDrag): the data source,
//! the icon under the pointer, and the drag's progress (Window.drag_state).

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const transfer = @import("../../../ui/transfer.zig");

const Window = window.Window;

/// Progress of a drag started with startDrag().
pub const DragState = window.DragState;
pub const DragIcon = window.DragIcon;

pub const Drag = struct {
    /// wl_data_source of the drag; 0 when none
    source: u32 = 0,
    /// a drop target accepted one of the types (wl_data_source.target)
    accepted: bool = false,
    /// payloads offered as image/png and text/uri-list (owned)
    png: []u8 = &.{},
    uri: []u8 = &.{},
    // the icon surface and its buffer
    icon: u32 = 0,
    icon_buf: u32 = 0,
    icon_mem: []align(std.heap.page_size_min) u8 = &.{},
};

/// Start dragging an image out of surface idx; call on the button
/// press (its serial starts the drag). Offers drag_mimes: `png_data`
/// as image/png and `uri_list` as text/uri-list (copy semantics).
/// Takes ownership of both on success. Follow drag_state.
pub fn startDrag(w: *Window, idx: u8, png_data: []u8, uri_list: []u8, icon: ?DragIcon) !void {
    const g = &w.globals;
    if (g.ddm == 0 or w.data_device.id == 0) return error.NoDataDevice;
    const s = &w.surfaces[idx];
    if (!s.alive) return error.NoSuchSurface;
    endDrag(w);
    const c = &w.conn;
    const source = c.newId();
    try c.request(g.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
    for (transfer.drag_mimes) |m| try c.request(source, wl.wl_data_source.offer, &.{.{ .string = m }});
    if (g.ddm_version >= 3) try c.request(source, wl.wl_data_source.set_actions, &.{.{ .uint = wl.dnd_action_copy }});
    var icon_id: u32 = 0;
    if (icon) |ic| icon_id = makeIcon(w, ic) catch 0;
    try c.request(w.data_device.id, wl.wl_data_device.start_drag, &.{
        .{ .object = source }, .{ .object = s.wl_surface }, .{ .object = icon_id }, .{ .uint = w.input_serial },
    });
    try c.flush();
    w.drag.source = source;
    w.drag.png = png_data;
    w.drag.uri = uri_list;
    w.drag_state = .active;
    w.drag.accepted = false;
}

/// The icon surface showing `ic`, held a little in from its top-left.
fn makeIcon(w: *Window, ic: DragIcon) !u32 {
    const d = &w.drag;
    const c = &w.conn;
    const fd = try sys.memfdCreate("shotlet-dnd", sys.MFD_CLOEXEC);
    defer sys.close(fd); // flushed below while still open
    try makeIconBuffer(w, ic, fd);
    d.icon = c.newId();
    try c.request(w.globals.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = d.icon }});
    const k = @max(1, ic.scale);
    if (w.globals.compositor_version >= 3 and k > 1) try c.request(d.icon, wl.wl_surface.set_buffer_scale, &.{.{ .int = k }});
    // the pointer holds the icon a little in from its top-left corner
    const hx: i32 = -@as(i32, @intCast(@min(ic.width / @as(u32, @intCast(k)) / 2, 40)));
    const hy: i32 = -@as(i32, @intCast(@min(ic.height / @as(u32, @intCast(k)) / 2, 30)));
    if (w.globals.compositor_version >= 5) {
        try c.request(d.icon, wl.wl_surface.attach, &.{ .{ .object = d.icon_buf }, .{ .int = 0 }, .{ .int = 0 } });
        try c.request(d.icon, wl.wl_surface.offset, &.{ .{ .int = hx }, .{ .int = hy } });
    } else {
        try c.request(d.icon, wl.wl_surface.attach, &.{ .{ .object = d.icon_buf }, .{ .int = hx }, .{ .int = hy } });
    }
    try c.request(d.icon, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = std.math.maxInt(i32) }, .{ .int = std.math.maxInt(i32) } });
    try c.request(d.icon, wl.wl_surface.commit, &.{});
    try c.flush(); // the memfd travels with these bytes
    return d.icon;
}

/// Copy the icon's pixels into a shm buffer backed by memfd `fd`, which
/// must stay open until the requests are flushed.
fn makeIconBuffer(w: *Window, ic: DragIcon, fd: sys.fd_t) !void {
    const d = &w.drag;
    const c = &w.conn;
    const size: usize = @as(usize, ic.width) * ic.height * 4;
    try sys.ftruncate(fd, size);
    d.icon_mem = try sys.mmapRw(fd, size);
    @memcpy(@as([*]u32, @ptrCast(@alignCast(d.icon_mem.ptr)))[0 .. size / 4], ic.pixels[0 .. size / 4]);
    const pool = c.newId();
    try c.request(w.globals.shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
    d.icon_buf = c.newId();
    try c.request(pool, wl.wl_shm_pool.create_buffer, &.{
        .{ .new_id = d.icon_buf },       .{ .int = 0 },                      .{ .int = @intCast(ic.width) },
        .{ .int = @intCast(ic.height) }, .{ .int = @intCast(ic.width * 4) }, .{ .uint = wl.wl_shm.format_argb8888 },
    });
    try c.request(pool, wl.wl_shm_pool.destroy, &.{});
}

/// wl_data_source events of the drag.
pub fn handleSource(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_data_source.ev_target => {
            const mime = r.string() catch "";
            w.drag.accepted = mime.len > 0;
        },
        wl.wl_data_source.ev_send => try onSend(w, r),
        wl.wl_data_source.ev_dnd_drop_performed => {
            if (w.drag_state == .active) w.drag_state = .dropped;
        },
        wl.wl_data_source.ev_dnd_finished => {
            w.drag_state = .finished;
            releaseSource(w);
        },
        wl.wl_data_source.ev_cancelled => {
            if (w.drag_state != .finished) w.drag_state = .cancelled;
            releaseSource(w);
        },
        else => {},
    }
}

/// The target reads one of our types.
fn onSend(w: *Window, r: *wl.ArgReader) !void {
    const mime = try r.string();
    const fd = w.conn.takeFd() orelse return;
    defer sys.close(fd);
    const data: []const u8 = switch (transfer.dragPayloadFor(mime) orelse return) {
        .png => w.drag.png,
        .uri_list => w.drag.uri,
    };
    sys.writeAllBlocking(fd, data) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionReset => {},
        else => std.log.warn("drag send failed: {t}", .{err}),
    };
    // before v3 there is no dnd_finished: a read is the drop
    if (w.globals.ddm_version < 3) w.drag_state = .finished;
}

/// Destroy the drag's source and icon (payloads stay until endDrag).
fn releaseSource(w: *Window) void {
    const d = &w.drag;
    const c = &w.conn;
    if (d.source != 0) c.request(d.source, wl.wl_data_source.destroy, &.{}) catch {};
    d.source = 0;
    if (d.icon != 0) c.request(d.icon, wl.wl_surface.destroy, &.{}) catch {};
    d.icon = 0;
    if (d.icon_buf != 0) c.request(d.icon_buf, wl.wl_buffer.destroy, &.{}) catch {};
    d.icon_buf = 0;
    if (d.icon_mem.len > 0) sys.munmap(d.icon_mem);
    d.icon_mem = &.{};
    c.flush() catch {};
}

/// Drop the drag's source and payloads; drag_state becomes .none.
pub fn endDrag(w: *Window) void {
    releaseSource(w);
    if (w.drag.png.len > 0) w.alloc.free(w.drag.png);
    if (w.drag.uri.len > 0) w.alloc.free(w.drag.uri);
    w.drag.png = &.{};
    w.drag.uri = &.{};
    w.drag_state = .none;
}
