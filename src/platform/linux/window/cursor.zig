//! Custom pointer cursors: every shape is drawn once into a shared shm
//! pool at open, and the current one is attached to a cursor surface.

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const render = @import("../../../gfx/render.zig");
const window = @import("../window.zig");

const Window = window.Window;

pub const Cursor = enum { crosshair, arrow, move, text, resize_nwse, resize_nesw, resize_ns, resize_ew };

const cursor_size = 27;

pub const Cursors = struct {
    /// wl_surface showing the current cursor; 0 before open()
    surface: u32 = 0,
    pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    /// one wl_buffer per Cursor
    buffers: [8]u32 = @splat(0),

    pub fn deinit(self: *Cursors) void {
        if (self.pool_mem.len > 0) sys.munmap(self.pool_mem);
    }
};

/// Draw every cursor into one pool and create the cursor surface.
pub fn init(w: *Window) !void {
    const c = &w.conn;
    const cs = &w.cursors;
    const buf_size: usize = cursor_size * cursor_size * 4;
    const total = buf_size * cs.buffers.len;
    const fd = try sys.memfdCreate("shotlet-cursor", sys.MFD_CLOEXEC);
    // note: flushed before close below; fds travel with the queued bytes
    defer sys.close(fd);
    try sys.ftruncate(fd, total);
    cs.pool_mem = try sys.mmapRw(fd, total);

    const pool = c.newId();
    try c.request(w.globals.shm, wl.wl_shm.create_pool, &.{
        .{ .new_id = pool },
        .{ .fd = fd },
        .{ .int = @intCast(total) },
    });
    for (&cs.buffers, 0..) |*id, i| {
        id.* = c.newId();
        try c.request(pool, wl.wl_shm_pool.create_buffer, &.{
            .{ .new_id = id.* },
            .{ .int = @intCast(i * buf_size) },
            .{ .int = cursor_size },
            .{ .int = cursor_size },
            .{ .int = cursor_size * 4 },
            .{ .uint = wl.wl_shm.format_argb8888 },
        });
        const pixels = @as([*]u32, @ptrCast(@alignCast(cs.pool_mem.ptr)))[i * cursor_size * cursor_size ..][0 .. cursor_size * cursor_size];
        drawCursor(@as(Cursor, @fromBackingInt(@intCast(i))), pixels);
    }
    try c.request(pool, wl.wl_shm_pool.destroy, &.{});

    cs.surface = c.newId();
    try c.request(w.globals.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = cs.surface }});
    try c.flush(); // must hit the wire while the memfd is still open
}

pub fn setCursor(w: *Window, kind: Cursor) !void {
    if (w.current_cursor == kind) return;
    w.current_cursor = kind;
    try apply(w);
}

/// Show the current cursor on the pointer.
pub fn apply(w: *Window) !void {
    const cs = &w.cursors;
    if (w.pointer.id == 0 or cs.surface == 0) return;
    const c = &w.conn;
    const idx: usize = @backingInt(w.current_cursor);
    try c.request(cs.surface, wl.wl_surface.attach, &.{ .{ .object = cs.buffers[idx] }, .{ .int = 0 }, .{ .int = 0 } });
    try c.request(cs.surface, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = cursor_size }, .{ .int = cursor_size } });
    try c.request(cs.surface, wl.wl_surface.commit, &.{});
    const hot: i32 = if (w.current_cursor == .arrow) 3 else cursor_size / 2;
    try c.request(w.pointer.id, wl.wl_pointer.set_cursor, &.{
        .{ .uint = w.pointer.enter_serial },
        .{ .object = cs.surface },
        .{ .int = hot },
        .{ .int = if (w.current_cursor == .arrow) 2 else hot },
    });
    try c.flush();
}

// --- drawing (white strokes over a black outline) ---

const white: u32 = 0xFFFFFFFF;
const black: u32 = 0xE6000000;
const mid: f64 = @as(f64, cursor_size) / 2.0;
const m: i32 = cursor_size / 2;
const P = struct { x: i32, y: i32 };

fn drawCursor(kind: Cursor, px: []u32) void {
    @memset(px, 0);
    var c = render.Canvas.init(px, cursor_size, cursor_size);
    switch (kind) {
        .crosshair => drawCrosshair(&c),
        .arrow => {
            // classic pointer with outline
            c.fillTriangleAA(3, 1, 3, 19, 16, 12, black);
            c.fillTriangleAA(4, 4, 4, 16.5, 13.5, 11, white);
        },
        .move => drawMove(&c),
        .text => drawText(&c),
        .resize_nwse, .resize_nesw, .resize_ns, .resize_ew => drawResize(&c, kind),
    }
}

fn drawCrosshair(c: *render.Canvas) void {
    const arms = [4][2]P{
        .{ .{ .x = m, .y = 0 }, .{ .x = m, .y = m - 4 } },
        .{ .{ .x = m, .y = m + 4 }, .{ .x = m, .y = cursor_size - 1 } },
        .{ .{ .x = 0, .y = m }, .{ .x = m - 4, .y = m } },
        .{ .{ .x = m + 4, .y = m }, .{ .x = cursor_size - 1, .y = m } },
    };
    for (arms) |a| c.strokePolylineAA(a[0..], 3.4, black);
    for (arms) |a| c.strokePolylineAA(a[0..], 1.6, white);
    c.fillCircleAA(mid, mid, 1.2, white);
}

fn drawMove(c: *render.Canvas) void {
    const arms = [4][2]P{
        .{ .{ .x = m, .y = m }, .{ .x = m, .y = 1 } },
        .{ .{ .x = m, .y = m }, .{ .x = m, .y = cursor_size - 2 } },
        .{ .{ .x = m, .y = m }, .{ .x = 1, .y = m } },
        .{ .{ .x = m, .y = m }, .{ .x = cursor_size - 2, .y = m } },
    };
    for (arms) |a| c.arrowAA(a[0].x, a[0].y, a[1].x, a[1].y, 4, black);
    for (arms) |a| c.arrowAA(a[0].x, a[0].y, a[1].x, a[1].y, 2, white);
}

fn drawText(c: *render.Canvas) void {
    const stem = [_]P{ .{ .x = m, .y = 3 }, .{ .x = m, .y = cursor_size - 4 } };
    c.strokePolylineAA(stem[0..], 3.2, black);
    c.strokePolylineAA(stem[0..], 1.4, white);
    c.fillRect(m - 3, 2, 7, 2, white);
    c.fillRect(m - 3, cursor_size - 4, 7, 2, white);
}

/// A double-headed arrow through the centre along the resize direction.
fn drawResize(c: *render.Canvas, kind: Cursor) void {
    const d = resizeDelta(kind);
    const x0: i32 = @intFromFloat(mid - d[0]);
    const y0: i32 = @intFromFloat(mid - d[1]);
    const x1: i32 = @intFromFloat(mid + d[0]);
    const y1: i32 = @intFromFloat(mid + d[1]);
    c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x1, y1, 4, black);
    c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x0, y0, 4, black);
    c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x1, y1, 2, white);
    c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x0, y0, 2, white);
}

/// Half the arrow's extent along x and y.
fn resizeDelta(kind: Cursor) [2]f64 {
    const d: f64 = 9.0;
    return switch (kind) {
        .resize_nwse => .{ d * 0.707, d * 0.707 },
        .resize_nesw => .{ d * 0.707, -d * 0.707 },
        .resize_ns => .{ 0, d },
        .resize_ew => .{ d, 0 },
        else => .{ 0, 0 },
    };
}
