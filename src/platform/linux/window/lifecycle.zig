//! Opening the window's surfaces (one, or one per output), waiting for
//! their first configure, closing them and tearing everything down.

const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const output = @import("output.zig");
const buffers = @import("buffers.zig");
const registry = @import("registry.zig");
const events = @import("events.zig");
const text_input = @import("text_input.zig");
const cursor = @import("cursor.zig");
const data_device = @import("data_device.zig");
const clipboard = @import("clipboard.zig");
const drag = @import("drag.zig");
const dump = @import("dump.zig");
const vanish = @import("vanish.zig");

const Window = window.Window;
const Output = output.Output;
const max_outputs = window.max_outputs;
const max_surfaces = window.max_surfaces;

/// A wlr-layer-shell placement (see OpenOptions.layer).
pub const Layer = window.Layer;

pub const OpenOptions = struct {
    fullscreen: bool = true,
    /// ask to be maximized (the work area: panels stay visible)
    maximized: bool = false,
    /// fallback size when the compositor lets the client decide
    width: u32 = 800,
    height: u32 = 500,
    /// premultiplied ARGB buffers: see-through where alpha < 255
    transparent: bool = false,
    /// a wlr-layer-shell surface when the compositor offers one;
    /// ignored otherwise (an xdg toplevel as the rest describes)
    layer: ?Layer = null,
};

/// Create the toplevel; returns after the first configure, with buffers
/// allocated (a .resize event will be queued).
pub fn open(w: *Window, title: []const u8, opts: OpenOptions) !void {
    w.default_w = opts.width;
    w.default_h = opts.height;
    try surface.create(w, 0, title, opts, 0, 0);
    w.n_surfaces = 1;
    try finishOpen(w);
}

/// Open one fullscreen surface per known output (up to max_surfaces),
/// ordered left to right, top to bottom. Surface 0 is the first. Falls
/// back to a single open() when the compositor announced no outputs.
/// Returns after every surface got its first configure.
pub fn openOutputs(w: *Window, title: []const u8) !void {
    var order: [max_outputs]u8 = undefined;
    const slots = w.outputs.sortedSlots(&order);
    if (slots.len == 0) return open(w, title, .{ .fullscreen = true });
    const n = @min(slots.len, max_surfaces);
    for (slots[0..n], 0..) |slot, i| try openOn(w, @intCast(i), title, &w.outputs.list[slot]);
    w.n_surfaces = @intCast(n);
    try finishOpen(w);
}

/// One fullscreen surface on the output whose logical rectangle starts
/// at x, y; open(.{ .fullscreen = true }) when there is none.
pub fn openOnOutputAt(w: *Window, title: []const u8, x: i32, y: i32) !void {
    const o = w.outputs.atOrigin(x, y) orelse return open(w, title, .{ .fullscreen = true });
    try openOn(w, 0, title, o);
    w.n_surfaces = 1;
    return finishOpen(w);
}

/// Surface idx fullscreen on output o, starting at the output's scale.
fn openOn(w: *Window, idx: u8, title: []const u8, o: *const Output) !void {
    try surface.create(w, idx, title, .{ .fullscreen = true }, o.id, o.global);
    const s = &w.surfaces[idx];
    s.int_scale = @max(1, o.scale);
    if (s.fs_obj == 0) s.scale120 = @intCast(s.int_scale * 120);
    output.setOutputRect(s, o);
}

/// Take the seat's devices, the data device, text input and cursors, then
/// wait for the initial configure of every surface.
fn finishOpen(w: *Window) !void {
    try registry.updateSeatDevices(w);
    try data_device.ensureDevice(w);
    try text_input.ensureObject(w);
    if (w.cursors.surface == 0) try cursor.init(w);
    while (!allConfigured(w)) try events.dispatchOne(w);
}

fn allConfigured(w: *const Window) bool {
    for (w.surfaces[0..w.n_surfaces]) |s| {
        if (s.alive and !s.configured) return false;
    }
    return true;
}

/// Destroy the visible window(s) (keeps the connection alive so an
/// offered clipboard selection can still be served). Fullscreen ones
/// show a clear frame first (vanish.zig).
pub fn closeWindow(w: *Window) void {
    dump.dumpFrames(w);
    var clear: vanish.Clear = .{};
    vanish.vanish(w, &clear);
    text_input.destroy(w);
    for (0..w.n_surfaces) |i| surface.destroy(w, @intCast(i));
    clear.release(&w.conn);
    w.conn.flush() catch {};
}

pub fn deinit(w: *Window) void {
    dump.dumpFrames(w);
    clipboard.dropSource(w);
    drag.endDrag(w);
    for (&w.surfaces) |*s| buffers.destroyPool(&w.conn, s);
    w.cursors.deinit();
    w.queue.deinit(w.alloc);
    w.kb.deinit();
    w.conn.deinit();
}
