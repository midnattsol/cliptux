//! Surfaces: one wl_surface with an xdg toplevel or a wlr layer surface,
//! its own shm buffers and scale. Creation, teardown and the configure,
//! scale and frame events of each surface's objects.

const std = @import("std");
const sys = @import("../../platform/sys.zig");
const wl = @import("../../platform/wayland.zig");
const window = @import("../window.zig");
const buffers = @import("buffers.zig");
const scale = @import("scale.zig");
const lifecycle = @import("lifecycle.zig");

const Window = window.Window;
const Buffer = buffers.Buffer;
const Layer = lifecycle.Layer;
const OpenOptions = lifecycle.OpenOptions;

/// One wl_surface + xdg toplevel with its own shm buffers and scale.
pub const Surface = struct {
    // --- public, read-only for callers ---
    /// buffer pixels
    width: u32 = 0,
    height: u32 = 0,
    /// effective scale * 120 (fractional, or the integer buffer scale)
    scale120: u32 = 120,
    /// surface size in logical (compositor) pixels
    logical_w: u32 = 0,
    logical_h: u32 = 0,
    /// openOutputs(): the output's logical rectangle; zero otherwise
    x: i32 = 0,
    y: i32 = 0,
    out_w: u32 = 0,
    out_h: u32 = 0,
    /// registry name of the output this surface is fullscreen on; 0 when
    /// the compositor picks
    output: u32 = 0,
    frame_pending: bool = false,
    configured: bool = false,
    alive: bool = false,
    maximized: bool = false,
    /// argb8888 buffers with premultiplied alpha (OpenOptions.transparent)
    transparent: bool = false,

    // --- protocol objects and state ---
    wl_surface: u32 = 0,
    xdg_surf: u32 = 0,
    toplevel: u32 = 0,
    /// zwlr_layer_surface_v1, used instead of xdg_surf/toplevel
    layer_surf: u32 = 0,
    /// its keyboard interactivity as last set
    layer_kb: u32 = 0,
    /// surface size minus its window geometry (a drawn shadow): xdg
    /// configure sizes are the geometry's
    geom_extra_w: u32 = 0,
    geom_extra_h: u32 = 0,
    viewport: u32 = 0,
    fs_obj: u32 = 0, // wp_fractional_scale_v1
    frame_cb: u32 = 0,
    /// integer buffer scale used when fractional scaling is unavailable
    int_scale: i32 = 1,
    /// buffer scale last sent with set_buffer_scale
    committed_scale: i32 = 1,
    /// wl_surface.preferred_buffer_scale (v6); 0 = not received
    preferred_int: i32 = 0,
    /// output slots the surface is on (wl_surface.enter/leave)
    entered: u32 = 0,
    pending_w: u32 = 0, // from xdg_toplevel.configure (surface coords)
    pending_h: u32 = 0,
    bounds_w: u32 = 0, // from xdg_toplevel.configure_bounds (logical)
    bounds_h: u32 = 0,

    pool: u32 = 0,
    pool_fd: sys.fd_t = -1,
    pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [2]Buffer = .{ .{}, .{} },
    cur_buf: usize = 0,
    /// buffer index of the last present, for SHOTLET_DUMP_FRAME
    last_presented: ?usize = null,
};

/// The surfaces opened by open()/openOutputs(); check `alive`.
pub fn surfaceList(w: *Window) []Surface {
    return w.surfaces[0..w.n_surfaces];
}

/// Copy surface 0's state into the single-surface mirror fields.
pub fn syncPrimary(w: *Window) void {
    const s = &w.surfaces[0];
    w.width = s.width;
    w.height = s.height;
    w.scale120 = s.scale120;
    w.scale = @max(1, (s.scale120 + 60) / 120);
    w.maximized = s.maximized;
    w.configured = s.configured;
    w.frame_pending = s.frame_pending;
}

// --- creation and teardown ---

/// Create surface idx with its role (layer surface when asked and
/// offered, else an xdg toplevel) and commit it to get a configure.
pub fn create(w: *Window, idx: u8, title: []const u8, opts: OpenOptions, output_id: u32, output_global: u32) !void {
    const s = &w.surfaces[idx];
    s.* = .{ .alive = true, .output = output_global, .transparent = opts.transparent };
    try createBase(w, s);
    if (opts.layer) |l| if (w.globals.layer_shell != 0) {
        return createLayer(w, s, l, output_id);
    };
    try createToplevel(w, s, title, opts, output_id);
}

/// The wl_surface, plus a viewport and fractional scale when offered.
fn createBase(w: *Window, s: *Surface) !void {
    const c = &w.conn;
    const g = &w.globals;
    s.wl_surface = c.newId();
    try c.request(g.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = s.wl_surface }});
    if (g.viewporter != 0 and g.fs_manager != 0) {
        s.viewport = c.newId();
        try c.request(g.viewporter, wl.wp_viewporter.get_viewport, &.{ .{ .new_id = s.viewport }, .{ .object = s.wl_surface } });
        s.fs_obj = c.newId();
        try c.request(g.fs_manager, wl.wp_fractional_scale_manager_v1.get_fractional_scale, &.{ .{ .new_id = s.fs_obj }, .{ .object = s.wl_surface } });
    }
}

fn createLayer(w: *Window, s: *Surface, l: Layer, output_id: u32) !void {
    const c = &w.conn;
    const L = wl.zwlr_layer_surface_v1;
    s.layer_surf = c.newId();
    try c.request(w.globals.layer_shell, wl.zwlr_layer_shell_v1.get_layer_surface, &.{
        .{ .new_id = s.layer_surf }, .{ .object = s.wl_surface }, .{ .object = output_id },
        .{ .uint = l.layer },        .{ .string = l.namespace },
    });
    try c.request(s.layer_surf, L.set_size, &.{ .{ .uint = l.width }, .{ .uint = l.height } });
    try c.request(s.layer_surf, L.set_anchor, &.{.{ .uint = l.anchor }});
    try c.request(s.layer_surf, L.set_margin, &.{
        .{ .int = l.margin[0] }, .{ .int = l.margin[1] }, .{ .int = l.margin[2] }, .{ .int = l.margin[3] },
    });
    try c.request(s.layer_surf, L.set_exclusive_zone, &.{.{ .int = 0 }});
    // on-demand focus is v4; before it the only choice that does
    // not grab every key press is none
    var kb = l.keyboard;
    if (kb == L.keyboard_on_demand and w.globals.layer_shell_version < 4) kb = L.keyboard_none;
    try c.request(s.layer_surf, L.set_keyboard_interactivity, &.{.{ .uint = kb }});
    s.layer_kb = kb;
    s.pending_w = l.width;
    s.pending_h = l.height;
    try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
}

fn createToplevel(w: *Window, s: *Surface, title: []const u8, opts: OpenOptions, output_id: u32) !void {
    const c = &w.conn;
    s.xdg_surf = c.newId();
    try c.request(w.globals.wm_base, wl.xdg_wm_base.get_xdg_surface, &.{ .{ .new_id = s.xdg_surf }, .{ .object = s.wl_surface } });
    s.toplevel = c.newId();
    try c.request(s.xdg_surf, wl.xdg_surface.get_toplevel, &.{.{ .new_id = s.toplevel }});
    try c.request(s.toplevel, wl.xdg_toplevel.set_app_id, &.{.{ .string = @import("../../app_id.zig").app_id }});
    try c.request(s.toplevel, wl.xdg_toplevel.set_title, &.{.{ .string = title }});
    if (opts.fullscreen) {
        try c.request(s.toplevel, wl.xdg_toplevel.set_fullscreen, &.{.{ .object = output_id }});
    } else if (opts.maximized) {
        try c.request(s.toplevel, wl.xdg_toplevel.set_maximized, &.{});
    }
    try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
}

/// Destroy one surface's protocol objects and buffers.
pub fn destroy(w: *Window, idx: u8) void {
    const c = &w.conn;
    const s = &w.surfaces[idx];
    buffers.destroyPool(c, s);
    if (s.fs_obj != 0) c.request(s.fs_obj, 0, &.{}) catch {}; // wp_fractional_scale_v1.destroy
    if (s.viewport != 0) c.request(s.viewport, wl.wp_viewport.destroy, &.{}) catch {};
    if (s.toplevel != 0) c.request(s.toplevel, wl.xdg_toplevel.destroy, &.{}) catch {};
    if (s.layer_surf != 0) c.request(s.layer_surf, wl.zwlr_layer_surface_v1.destroy, &.{}) catch {};
    if (s.xdg_surf != 0) c.request(s.xdg_surf, wl.xdg_surface.destroy, &.{}) catch {};
    if (s.wl_surface != 0) c.request(s.wl_surface, wl.wl_surface.destroy, &.{}) catch {};
    s.* = .{};
    c.flush() catch {};
    if (idx == 0) syncPrimary(w);
}

// --- events ---

/// Which of a surface's objects an event is for.
pub const SurfaceObj = enum { wl_surface, xdg_surf, toplevel, layer_surf, fs_obj, frame_cb, buffer0, buffer1 };

pub fn find(w: *Window, obj: u32) ?struct { idx: u8, kind: SurfaceObj } {
    if (obj == 0) return null;
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        if (!s.alive) continue;
        const kind = objKind(s, obj) orelse continue;
        return .{ .idx = @intCast(i), .kind = kind };
    }
    return null;
}

fn objKind(s: *const Surface, obj: u32) ?SurfaceObj {
    if (obj == s.wl_surface) return .wl_surface;
    if (obj == s.xdg_surf) return .xdg_surf;
    if (obj == s.toplevel) return .toplevel;
    if (obj == s.layer_surf) return .layer_surf;
    if (obj == s.fs_obj) return .fs_obj;
    if (obj == s.frame_cb) return .frame_cb;
    if (obj == s.buffers[0].id) return .buffer0;
    if (obj == s.buffers[1].id) return .buffer1;
    return null;
}

/// Index of the surface whose wl_surface is `wl_surface`.
pub fn indexOf(w: *Window, wl_surface: u32) ?u8 {
    const f = find(w, wl_surface) orelse return null;
    return if (f.kind == .wl_surface) f.idx else null;
}

pub fn handleEvent(w: *Window, idx: u8, kind: SurfaceObj, opcode: u16, r: *wl.ArgReader) !void {
    const s = &w.surfaces[idx];
    switch (kind) {
        .toplevel => try onToplevel(w, s, opcode, r),
        .layer_surf => try onLayerSurface(w, idx, opcode, r),
        .xdg_surf => if (opcode == wl.xdg_surface.ev_configure) try onXdgConfigure(w, idx, r),
        .fs_obj => if (opcode == wl.wp_fractional_scale_v1.ev_preferred_scale) try onPreferredScale(w, idx, r),
        .wl_surface => try onWlSurface(w, idx, opcode, r),
        .frame_cb => if (opcode == wl.wl_callback.ev_done) {
            s.frame_pending = false;
            s.frame_cb = 0;
            try w.queue.append(w.alloc, .frame_done);
        },
        .buffer0, .buffer1 => if (opcode == wl.wl_buffer.ev_release) {
            s.buffers[@intFromBool(kind == .buffer1)].busy = false;
        },
    }
    if (idx == 0) syncPrimary(w);
}

fn onToplevel(w: *Window, s: *Surface, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.xdg_toplevel.ev_configure => {
            const w_ = try r.int();
            const h_ = try r.int();
            s.pending_w = @intCast(@max(0, w_));
            s.pending_h = @intCast(@max(0, h_));
            s.maximized = false;
            const states = try r.array();
            var si: usize = 0;
            while (si + 4 <= states.len) : (si += 4) {
                const st = std.mem.readInt(u32, states[si..][0..4], .little);
                if (st == wl.xdg_toplevel.state_maximized) s.maximized = true;
            }
        },
        wl.xdg_toplevel.ev_close => try w.queue.append(w.alloc, .close),
        wl.xdg_toplevel.ev_configure_bounds => {
            s.bounds_w = @intCast(@max(0, try r.int()));
            s.bounds_h = @intCast(@max(0, try r.int()));
        },
        else => {},
    }
}

fn onLayerSurface(w: *Window, idx: u8, opcode: u16, r: *wl.ArgReader) !void {
    const s = &w.surfaces[idx];
    switch (opcode) {
        wl.zwlr_layer_surface_v1.ev_configure => {
            const serial = try r.uint();
            const w_ = try r.uint();
            const h_ = try r.uint();
            try w.conn.request(s.layer_surf, wl.zwlr_layer_surface_v1.ack_configure, &.{.{ .uint = serial }});
            if (w_ > 0) s.pending_w = w_;
            if (h_ > 0) s.pending_h = h_;
            s.logical_w = if (s.pending_w > 0) s.pending_w else w.default_w;
            s.logical_h = if (s.pending_h > 0) s.pending_h else w.default_h;
            try scale.applySize(w, idx);
            s.configured = true;
            try w.conn.flush();
        },
        wl.zwlr_layer_surface_v1.ev_closed => try w.queue.append(w.alloc, .close),
        else => {},
    }
}

fn onXdgConfigure(w: *Window, idx: u8, r: *wl.ArgReader) !void {
    const s = &w.surfaces[idx];
    const serial = try r.uint();
    try w.conn.request(s.xdg_surf, wl.xdg_surface.ack_configure, &.{.{ .uint = serial }});
    const size = configuredSize(w, s);
    s.logical_w = size[0];
    s.logical_h = size[1];
    try scale.applySize(w, idx);
    s.configured = true;
    try w.conn.flush();
}

/// The logical size an xdg configure settles on: the compositor's (plus
/// the drawn shadow), else the current, output or default size within
/// the compositor's bounds.
fn configuredSize(w: *const Window, s: *const Surface) [2]u32 {
    var want_w = if (s.pending_w > 0) s.pending_w + s.geom_extra_w else if (s.logical_w > 0) s.logical_w else if (s.out_w > 0) s.out_w else w.default_w;
    var want_h = if (s.pending_h > 0) s.pending_h + s.geom_extra_h else if (s.logical_h > 0) s.logical_h else if (s.out_h > 0) s.out_h else w.default_h;
    // respect compositor bounds for client-decided sizes
    if (s.pending_w == 0 and s.bounds_w > 0) want_w = @min(want_w, s.bounds_w);
    if (s.pending_h == 0 and s.bounds_h > 0) want_h = @min(want_h, s.bounds_h - @min(s.bounds_h / 20, 40));
    return .{ want_w, want_h };
}

fn onPreferredScale(w: *Window, idx: u8, r: *wl.ArgReader) !void {
    const s = &w.surfaces[idx];
    const new_scale = try r.uint();
    if (new_scale != s.scale120 and new_scale > 0) {
        s.scale120 = new_scale;
        if (s.configured) {
            try scale.applySize(w, idx);
            try w.conn.flush();
        }
    }
}

fn onWlSurface(w: *Window, idx: u8, opcode: u16, r: *wl.ArgReader) !void {
    const s = &w.surfaces[idx];
    switch (opcode) {
        wl.wl_surface.ev_enter, wl.wl_surface.ev_leave => {
            const out = try r.uint();
            if (w.outputs.slotOf(out)) |slot| {
                const bit = @as(u32, 1) << @intCast(slot);
                if (opcode == wl.wl_surface.ev_enter) s.entered |= bit else s.entered &= ~bit;
                try scale.updateIntScale(w, idx);
                // the output decides the exact buffer size (outputBufferSize)
                if (s.fs_obj != 0 and s.configured and s.output == 0) try scale.applySize(w, idx);
            }
        },
        wl.wl_surface.ev_preferred_buffer_scale => {
            s.preferred_int = @max(1, try r.int());
            try scale.updateIntScale(w, idx);
        },
        else => {},
    }
}
