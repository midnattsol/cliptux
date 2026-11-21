//! Requests on a surface's role: xdg toplevel moves, maximize, title,
//! window geometry and menu; layer surface placement and keyboard
//! interactivity; input regions and client-side resizes.

const wl = @import("../../platform/wayland.zig");
const window = @import("../window.zig");
const scale = @import("scale.zig");

const Window = window.Window;
const Rect = window.Rect;

/// Begin an interactive compositor-driven move (call on header drag).
pub fn startMove(w: *Window) !void {
    const toplevel = w.surfaces[0].toplevel;
    if (w.globals.seat == 0 or toplevel == 0) return;
    try w.conn.request(toplevel, wl.xdg_toplevel.move, &.{
        .{ .object = w.globals.seat },
        .{ .uint = w.input_serial },
    });
    try w.conn.flush();
}

pub fn toggleMaximize(w: *Window) !void {
    const toplevel = w.surfaces[0].toplevel;
    if (toplevel == 0) return;
    const op: u16 = if (w.surfaces[0].maximized) wl.xdg_toplevel.unset_maximized else wl.xdg_toplevel.set_maximized;
    try w.conn.request(toplevel, op, &.{});
    try w.conn.flush();
}

pub fn minimize(w: *Window) !void {
    const toplevel = w.surfaces[0].toplevel;
    if (toplevel == 0) return;
    try w.conn.request(toplevel, wl.xdg_toplevel.set_minimized, &.{});
    try w.conn.flush();
}

/// Where surface idx takes pointer input, in its logical coordinates;
/// null: everywhere. Elsewhere clicks reach the window below. Applied
/// with the next present.
pub fn setInputRegion(w: *Window, idx: u8, rects: ?[]const Rect) !void {
    const s = &w.surfaces[idx];
    if (!s.alive) return error.NoSuchSurface;
    const c = &w.conn;
    const rs = rects orelse {
        try c.request(s.wl_surface, wl.wl_surface.set_input_region, &.{.{ .object = 0 }});
        return;
    };
    const region = c.newId();
    try c.request(w.globals.compositor, wl.wl_compositor.create_region, &.{.{ .new_id = region }});
    for (rs) |r| try c.request(region, wl.wl_region.add, &.{ .{ .int = r.x }, .{ .int = r.y }, .{ .int = r.w }, .{ .int = r.h } });
    try c.request(s.wl_surface, wl.wl_surface.set_input_region, &.{.{ .object = region }});
    try c.request(region, wl.wl_region.destroy, &.{});
}

/// The part of surface idx that is the window proper (logical
/// coordinates), without its drawn shadow. xdg toplevels only.
pub fn setWindowGeometry(w: *Window, idx: u8, r: Rect) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.xdg_surf == 0) return;
    s.geom_extra_w = s.logical_w -| @as(u32, @intCast(@max(0, r.w)));
    s.geom_extra_h = s.logical_h -| @as(u32, @intCast(@max(0, r.h)));
    try w.conn.request(s.xdg_surf, wl.xdg_surface.set_window_geometry, &.{ .{ .int = r.x }, .{ .int = r.y }, .{ .int = r.w }, .{ .int = r.h } });
}

/// Change a toplevel's title (window rules key on it).
pub fn setTitle(w: *Window, idx: u8, title: []const u8) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.toplevel == 0) return;
    try w.conn.request(s.toplevel, wl.xdg_toplevel.set_title, &.{.{ .string = title }});
    try w.conn.flush();
}

/// The compositor's window menu (GNOME: Always on Top, Move, ...) at
/// logical x, y of surface idx. Call from a button press.
pub fn showWindowMenu(w: *Window, idx: u8, x: i32, y: i32) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.toplevel == 0 or w.globals.seat == 0) return;
    try w.conn.request(s.toplevel, wl.xdg_toplevel.show_window_menu, &.{
        .{ .object = w.globals.seat }, .{ .uint = w.input_serial }, .{ .int = x }, .{ .int = y },
    });
    try w.conn.flush();
}

/// Move or resize a layer surface (logical pixels; margins are top,
/// right, bottom, left). A new size arrives as a .resize event.
pub fn setLayerPlacement(w: *Window, idx: u8, width: u32, height: u32, margin: [4]i32) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.layer_surf == 0) return;
    const c = &w.conn;
    const L = wl.zwlr_layer_surface_v1;
    try c.request(s.layer_surf, L.set_size, &.{ .{ .uint = width }, .{ .uint = height } });
    try c.request(s.layer_surf, L.set_margin, &.{
        .{ .int = margin[0] }, .{ .int = margin[1] }, .{ .int = margin[2] }, .{ .int = margin[3] },
    });
    try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
    try c.flush();
}

/// Let a layer surface take keyboard focus when clicked (on demand) or
/// never; some compositors (labwc) focus an on-demand surface as soon
/// as it maps, so a window that must not steal the keyboard opens with
/// none and asks for on-demand only while the pointer is over it.
pub fn setLayerKeyboard(w: *Window, idx: u8, on_demand: bool) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.layer_surf == 0 or w.globals.layer_shell_version < 4) return;
    const L = wl.zwlr_layer_surface_v1;
    const kb = if (on_demand) L.keyboard_on_demand else L.keyboard_none;
    if (kb == s.layer_kb) return;
    s.layer_kb = kb;
    try w.conn.request(s.layer_surf, L.set_keyboard_interactivity, &.{.{ .uint = kb }});
    try w.conn.request(s.wl_surface, wl.wl_surface.commit, &.{});
    try w.conn.flush();
}

/// Ask an xdg toplevel to become a new size (logical); takes effect at
/// the next configure the compositor sends (or our own resize when it
/// lets the client decide): used by windows that size themselves.
pub fn resizeTo(w: *Window, idx: u8, width: u32, height: u32) !void {
    const s = &w.surfaces[idx];
    if (!s.alive or s.maximized) return;
    if (s.logical_w == width and s.logical_h == height) return;
    s.logical_w = width;
    s.logical_h = height;
    s.pending_w = 0;
    s.pending_h = 0;
    try scale.applySize(w, idx);
    try w.conn.flush();
}

/// Begin an interactive move of surface idx (call on a button press).
pub fn startMoveOf(w: *Window, idx: u8) !void {
    const s = &w.surfaces[idx];
    if (w.globals.seat == 0 or s.toplevel == 0) return;
    try w.conn.request(s.toplevel, wl.xdg_toplevel.move, &.{ .{ .object = w.globals.seat }, .{ .uint = w.input_serial } });
    try w.conn.flush();
}
