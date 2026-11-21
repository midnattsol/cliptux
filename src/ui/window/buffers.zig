//! Shared-memory double buffering per surface: the shm pool, picking a
//! free back buffer, and presenting it (attach, damage, frame, commit).

const std = @import("std");
const sys = @import("../../platform/sys.zig");
const wl = @import("../../platform/wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const events = @import("events.zig");

const Window = window.Window;
const Rect = window.Rect;
const Surface = surface.Surface;

pub const Buffer = struct {
    id: u32 = 0,
    busy: bool = false,
    // 4-byte aligned: the pool is page-aligned and buf_size is a multiple
    // of 4 (stride = w*4), so each buffer offset is u32-aligned. It is NOT
    // page-aligned for arbitrary window sizes, only u32-aligned.
    pixels: []align(4) u8 = &.{},
};

pub fn destroyPool(c: *wl.Connection, s: *Surface) void {
    for (&s.buffers) |*b| {
        if (b.id != 0) {
            c.request(b.id, wl.wl_buffer.destroy, &.{}) catch {};
            b.* = .{};
        }
    }
    if (s.pool != 0) {
        c.request(s.pool, wl.wl_shm_pool.destroy, &.{}) catch {};
        s.pool = 0;
    }
    if (s.pool_mem.len > 0) {
        sys.munmap(s.pool_mem);
        s.pool_mem = &.{};
    }
    if (s.pool_fd >= 0) {
        sys.close(s.pool_fd);
        s.pool_fd = -1;
    }
    s.last_presented = null;
}

/// (Re)create surface idx's two w x h buffers and queue a .resize.
pub fn createBuffers(w: *Window, idx: u8, width: u32, height: u32) !void {
    const s = &w.surfaces[idx];
    const c = &w.conn;
    destroyPool(c, s);
    const stride = width * 4;
    const buf_size: usize = @as(usize, stride) * height;
    const total = buf_size * 2;
    if (total > std.math.maxInt(i32)) return error.BufferTooLarge;

    s.pool_fd = try sys.memfdCreate("shotlet-shm", sys.MFD_CLOEXEC);
    try sys.ftruncate(s.pool_fd, total);
    s.pool_mem = try sys.mmapRw(s.pool_fd, total);

    s.pool = c.newId();
    try c.request(w.globals.shm, wl.wl_shm.create_pool, &.{
        .{ .new_id = s.pool },
        .{ .fd = s.pool_fd },
        .{ .int = @intCast(total) },
    });
    for (&s.buffers, 0..) |*b, i| try createBuffer(c, s, b, i * buf_size, width, height);
    s.width = width;
    s.height = height;
    try c.flush(); // send while pool_fd is guaranteed open
    if (idx == 0) surface.syncPrimary(w);
    try w.queue.append(w.alloc, .{ .resize = .{ .w = width, .h = height, .surface = idx } });
}

/// One wl_buffer at `offset` of the surface's pool.
fn createBuffer(c: *wl.Connection, s: *Surface, b: *Buffer, offset: usize, width: u32, height: u32) !void {
    const buf_size: usize = @as(usize, width) * 4 * height;
    b.id = c.newId();
    b.busy = false;
    b.pixels = @alignCast(s.pool_mem[offset..][0..buf_size]);
    try c.request(s.pool, wl.wl_shm_pool.create_buffer, &.{
        .{ .new_id = b.id },
        .{ .int = @intCast(offset) },
        .{ .int = @intCast(width) },
        .{ .int = @intCast(height) },
        .{ .int = @intCast(width * 4) },
        .{ .uint = if (s.transparent) wl.wl_shm.format_argb8888 else wl.wl_shm.format_xrgb8888 },
    });
}

/// Returns a drawable back buffer as u32 pixels (0xAARRGGBB) for
/// surface 0. Blocks until a buffer is free if both are busy.
pub fn backBuffer(w: *Window) ![]u32 {
    return backBufferOf(w, 0);
}

/// Back buffer of surface idx (s.width x s.height pixels).
pub fn backBufferOf(w: *Window, idx: u8) ![]u32 {
    if (idx >= w.n_surfaces or !w.surfaces[idx].alive) return error.NoSuchSurface;
    var tries: usize = 0;
    while (true) {
        const s = &w.surfaces[idx];
        if (!s.alive) return error.NoSuchSurface;
        if (s.pool == 0) return error.NotConfigured;
        if (!s.buffers[s.cur_buf].busy) break;
        if (!s.buffers[1 - s.cur_buf].busy) {
            s.cur_buf = 1 - s.cur_buf;
            break;
        }
        try events.dispatchOne(w);
        tries += 1;
        if (tries > 1000) return error.BuffersStuck;
    }
    const s = &w.surfaces[idx];
    const b = &s.buffers[s.cur_buf];
    return @as([*]u32, @ptrCast(b.pixels.ptr))[0 .. b.pixels.len / 4];
}

/// Attach + commit surface 0's current back buffer.
pub fn present(w: *Window) !void {
    return presentSurface(w, 0);
}

/// Attach + commit the current back buffer of surface idx.
pub fn presentSurface(w: *Window, idx: u8) !void {
    return presentDamaged(w, idx, null);
}

/// Like presentSurface, telling the compositor only `damage` (buffer
/// pixels) changed; null means the whole buffer. The caller must have
/// drawn everything else of this back buffer before (both buffers
/// alternate).
pub fn presentDamaged(w: *Window, idx: u8, damage: ?Rect) !void {
    if (idx >= w.n_surfaces) return error.NoSuchSurface;
    const s = &w.surfaces[idx];
    if (!s.alive or s.pool == 0) return error.NoSuchSurface;
    const c = &w.conn;
    const b = &s.buffers[s.cur_buf];
    if (s.fs_obj == 0 and s.committed_scale != s.int_scale and w.globals.compositor_version >= 3) {
        try c.request(s.wl_surface, wl.wl_surface.set_buffer_scale, &.{.{ .int = s.int_scale }});
        s.committed_scale = s.int_scale;
    }
    try c.request(s.wl_surface, wl.wl_surface.attach, &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
    const d = damage orelse Rect{ .x = 0, .y = 0, .w = @intCast(s.width), .h = @intCast(s.height) };
    try c.request(s.wl_surface, wl.wl_surface.damage_buffer, &.{
        .{ .int = d.x }, .{ .int = d.y }, .{ .int = d.w }, .{ .int = d.h },
    });
    if (!s.frame_pending) {
        s.frame_cb = c.newId();
        try c.request(s.wl_surface, wl.wl_surface.frame, &.{.{ .new_id = s.frame_cb }});
        s.frame_pending = true;
    }
    try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
    try c.flush();
    b.busy = true;
    s.last_presented = s.cur_buf;
    s.cur_buf = 1 - s.cur_buf;
    if (idx == 0) surface.syncPrimary(w);
}
