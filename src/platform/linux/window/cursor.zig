//! The pointer's cursor over our surfaces. Where the compositor offers
//! cursor-shape-v1 it draws the desktop's own cursors (theme, size,
//! HiDPI) and we only name the shape; elsewhere every shape is drawn
//! (cursor_art.zig) into one shm pool at the scale of the surface under
//! the pointer, and the current one is attached to a cursor surface.
//! SHOTLET_NO_CURSOR_SHAPE=1 ignores the protocol (registry.zig).

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const art = @import("cursor_art.zig");

const Window = window.Window;
const shape_device = wl.wp_cursor_shape_device_v1;

pub const Cursor = window.Cursor;

const n_kinds = std.enums.values(Cursor).len;
/// the largest scale drawn; the compositor scales further
const max_scale = 4;

pub const Cursors = struct {
    /// wp_cursor_shape_device_v1 of the pointer; 0 without the protocol
    device: u32 = 0,
    /// the drawn fallback: a wl_surface showing the current cursor and
    /// one wl_buffer per Cursor at `scale`; 0 until first needed
    surface: u32 = 0,
    scale: u32 = 0,
    pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [n_kinds]u32 = @splat(0),

    pub fn deinit(self: *Cursors) void {
        if (self.pool_mem.len > 0) sys.munmap(self.pool_mem);
    }
};

/// The pointer `w.pointer.id` was just taken: give it a shape device.
pub fn pointerAdded(w: *Window) !void {
    if (w.globals.cursor_shape == 0) return;
    const c = &w.conn;
    w.cursors.device = c.newId();
    try c.request(w.globals.cursor_shape, wl.wp_cursor_shape_manager_v1.get_pointer, &.{
        .{ .new_id = w.cursors.device },
        .{ .object = w.pointer.id },
    });
}

/// The pointer is about to be released: let go of its shape device.
pub fn pointerRemoved(w: *Window) !void {
    if (w.cursors.device == 0) return;
    try w.conn.request(w.cursors.device, shape_device.destroy, &.{});
    w.cursors.device = 0;
}

pub fn setCursor(w: *Window, kind: Cursor) !void {
    if (w.current_cursor == kind) return;
    w.current_cursor = kind;
    try apply(w);
}

/// Show the current cursor on the pointer (after every enter: the
/// compositor forgets it when the pointer leaves).
pub fn apply(w: *Window) !void {
    if (w.pointer.id == 0) return;
    const kind = w.current_cursor;
    if (w.cursors.device != 0) {
        try w.conn.request(w.cursors.device, shape_device.set_shape, &.{
            .{ .uint = w.pointer.enter_serial },
            .{ .uint = shapeOf(kind) },
        });
        std.log.debug("cursor: {t} via cursor-shape", .{kind});
    } else {
        try attachDrawn(w, kind);
        std.log.debug("cursor: {t} drawn at {d}x", .{ kind, w.cursors.scale });
    }
    try w.conn.flush();
}

/// The cursor-shape-v1 shape for `kind`.
fn shapeOf(kind: Cursor) u32 {
    return switch (kind) {
        .arrow => shape_device.shape_default,
        .crosshair => shape_device.shape_crosshair,
        .text => shape_device.shape_text,
        .grab => shape_device.shape_grab,
        .grabbing => shape_device.shape_grabbing,
        .resize_ew => shape_device.shape_ew_resize,
        .resize_ns => shape_device.shape_ns_resize,
        .resize_nesw => shape_device.shape_nesw_resize,
        .resize_nwse => shape_device.shape_nwse_resize,
    };
}

// --- the drawn fallback ---

/// Attach the drawn `kind` at the scale of the surface under the pointer.
fn attachDrawn(w: *Window, kind: Cursor) !void {
    const cs = &w.cursors;
    const c = &w.conn;
    if (cs.surface == 0) {
        cs.surface = c.newId();
        try c.request(w.globals.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = cs.surface }});
    }
    // a buffer scale needs wl_surface v3
    const scale = if (w.globals.compositor_version >= 3) cursorScale(w.surfaces[w.pointer.surface].scale120) else 1;
    if (cs.scale != scale) {
        try drawAll(w, scale);
        if (w.globals.compositor_version >= 3) try c.request(cs.surface, wl.wl_surface.set_buffer_scale, &.{.{ .int = @intCast(scale) }});
    }
    const side: i32 = @intCast(art.size * scale);
    try c.request(cs.surface, wl.wl_surface.attach, &.{ .{ .object = cs.buffers[@backingInt(kind)] }, .{ .int = 0 }, .{ .int = 0 } });
    try c.request(cs.surface, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = side }, .{ .int = side } });
    try c.request(cs.surface, wl.wl_surface.commit, &.{});
    const hot = art.hotspot(kind);
    try c.request(w.pointer.id, wl.wl_pointer.set_cursor, &.{
        .{ .uint = w.pointer.enter_serial },
        .{ .object = cs.surface },
        .{ .int = hot[0] },
        .{ .int = hot[1] },
    });
}

/// The whole buffer scale that covers a surface scale (120ths).
fn cursorScale(scale120: u32) u32 {
    return std.math.clamp((scale120 + 119) / 120, 1, max_scale);
}

/// (Re)draw every cursor at `scale` into a new pool.
fn drawAll(w: *Window, scale: u32) !void {
    const c = &w.conn;
    const cs = &w.cursors;
    const side = art.size * scale;
    const buf_size: usize = side * side * 4;
    const total = buf_size * n_kinds;
    const fd = try sys.memfdCreate("shotlet-cursor", sys.MFD_CLOEXEC);
    defer sys.close(fd);
    try sys.ftruncate(fd, total);
    const mem = try sys.mmapRw(fd, total);
    if (cs.pool_mem.len > 0) sys.munmap(cs.pool_mem);
    cs.pool_mem = mem;
    cs.scale = scale;

    const pool = c.newId();
    try c.request(w.globals.shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(total) } });
    const pixels: [*]u32 = @ptrCast(@alignCast(mem.ptr));
    for (&cs.buffers, std.enums.values(Cursor), 0..) |*id, kind, i| {
        if (id.* != 0) try c.request(id.*, wl.wl_buffer.destroy, &.{});
        id.* = c.newId();
        try c.request(pool, wl.wl_shm_pool.create_buffer, &.{
            .{ .new_id = id.* },
            .{ .int = @intCast(i * buf_size) },
            .{ .int = @intCast(side) },
            .{ .int = @intCast(side) },
            .{ .int = @intCast(side * 4) },
            .{ .uint = wl.wl_shm.format_argb8888 },
        });
        art.draw(kind, scale, pixels[i * side * side ..][0 .. side * side]);
    }
    try c.request(pool, wl.wl_shm_pool.destroy, &.{});
    try c.flush(); // the fd travels with the queued bytes: before close
}

test "every cursor names a shape of its own" {
    var seen: [64]bool = @splat(false);
    for (std.enums.values(Cursor)) |kind| {
        const s = shapeOf(kind);
        try std.testing.expect(!seen[s]);
        seen[s] = true;
    }
    try std.testing.expectEqual(@as(u32, 16), shapeOf(.grab));
    try std.testing.expectEqual(@as(u32, 17), shapeOf(.grabbing));
    try std.testing.expectEqual(@as(u32, 1), shapeOf(.arrow));
}

test "drawn cursors cover the surface scale, within bounds" {
    try std.testing.expectEqual(@as(u32, 1), cursorScale(120));
    try std.testing.expectEqual(@as(u32, 2), cursorScale(150));
    try std.testing.expectEqual(@as(u32, 2), cursorScale(240));
    try std.testing.expectEqual(@as(u32, 3), cursorScale(300));
    try std.testing.expectEqual(@as(u32, max_scale), cursorScale(1200));
    try std.testing.expectEqual(@as(u32, 1), cursorScale(0));
}
