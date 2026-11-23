//! The Wayland connection and its globals: connecting, binding what the
//! registry announces, global removal and the seat's input devices.

const std = @import("std");
const wl = @import("../wayland.zig");
const keyboard = @import("../keyboard.zig");
const window = @import("../window.zig");
const output = @import("output.zig");
const Env = @import("../../../app/env.zig").Env;
const pointer = @import("pointer.zig");
const keys = @import("keys.zig");
const events = @import("events.zig");

const Window = window.Window;

/// Bound globals; 0 when the compositor does not offer one.
pub const Globals = struct {
    registry: u32 = 0,
    compositor: u32 = 0,
    compositor_version: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    seat_version: u32 = 0,
    /// wl_seat capabilities last announced (pointer/keyboard bits)
    seat_caps: u32 = 0,
    ddm: u32 = 0, // wl_data_device_manager
    ddm_version: u32 = 0,
    viewporter: u32 = 0,
    fs_manager: u32 = 0, // wp_fractional_scale_manager_v1
    xdg_output_manager: u32 = 0,
    ti_manager: u32 = 0, // zwp_text_input_manager_v3
    rel_manager: u32 = 0, // zwp_relative_pointer_manager_v1
    layer_shell: u32 = 0, // zwlr_layer_shell_v1
    layer_shell_version: u32 = 0,
    cursor_shape: u32 = 0, // wp_cursor_shape_manager_v1
    /// zxdg_exporter_v2, else zxdg_exporter_v1 (window/foreign.zig)
    exporter: u32 = 0,
    /// whose window effects a closing window gets (window/vanish.zig)
    effects: Effects = .none,
};

/// Compositors known to animate windows that close, told apart by a
/// global only they offer; .none for the rest (wlroots' sway and labwc
/// animate nothing).
pub const Effects = enum {
    none,
    /// GNOME's mutter (gtk_shell1)
    mutter,
    /// KDE's KWin (org_kde_kwin_blur_manager)
    kwin,

    fn of(iface: []const u8) ?Effects {
        if (std.mem.eql(u8, iface, "gtk_shell1")) return .mutter;
        if (std.mem.eql(u8, iface, "org_kde_kwin_blur_manager")) return .kwin;
        return null;
    }
};

/// Connect to the session's display (Env.session).
pub fn init(alloc: std.mem.Allocator, env: Env) !Window {
    return connect(alloc, env.runtime_dir, env.session.display);
}

/// Connect to Wayland display `display` (a name in `runtime_dir`, or a
/// path).
pub fn connect(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8) !Window {
    var self = Window{
        .alloc = alloc,
        .conn = try wl.Connection.connect(alloc, runtime_dir, display),
    };
    errdefer self.conn.deinit();
    self.kb = keyboard.Keyboard.init();
    errdefer self.kb.deinit();

    self.globals.registry = try self.conn.getRegistry();
    // collect globals until the sync callback fires
    try roundtrip(&self);
    const g = &self.globals;
    if (g.compositor == 0 or g.shm == 0 or g.wm_base == 0)
        return error.MissingGlobals;
    // outputs announce their geometry after binding: one more roundtrip
    // so openOutputs() knows them up front
    if (try output.ensureAllXdg(&self)) try roundtrip(&self);
    return self;
}

/// Dispatch events until the compositor has handled everything sent so far.
pub fn roundtrip(w: *Window) !void {
    const cb = try w.conn.sync();
    while (true) {
        const ev = try w.conn.readEvent();
        if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) return;
        try events.handleEvent(w, ev);
    }
}

/// The compositor offers zwlr_layer_shell_v1 (KDE, wlroots; not GNOME).
pub fn hasLayerShell(w: *const Window) bool {
    return w.globals.layer_shell != 0;
}

/// wl_registry events.
pub fn handleEvent(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_registry.ev_global => {
            const name = try r.uint();
            const iface = try r.string();
            const version = try r.uint();
            try handleGlobal(w, name, iface, version);
        },
        wl.wl_registry.ev_global_remove => try handleGlobalRemove(w, try r.uint()),
        else => {},
    }
}

fn handleGlobal(w: *Window, name: u32, iface: []const u8, version: u32) !void {
    if (Effects.of(iface)) |e| w.globals.effects = e;
    if (try bindCore(w, name, iface, version)) return;
    if (try bindExtension(w, name, iface, version)) return;
    if (std.mem.eql(u8, iface, "wl_output")) try output.add(w, name, iface, version);
}

/// Core protocol globals; false when `iface` is none of them.
fn bindCore(w: *Window, name: u32, iface: []const u8, version: u32) !bool {
    const eql = std.mem.eql;
    const g = &w.globals;
    const c = &w.conn;
    if (eql(u8, iface, "wl_compositor")) {
        // v6 for wl_surface.preferred_buffer_scale
        g.compositor_version = @min(version, 6);
        g.compositor = try c.bind(g.registry, name, iface, g.compositor_version);
    } else if (eql(u8, iface, "wl_shm")) {
        g.shm = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "xdg_wm_base")) {
        // v2 for the tiled_* states (a tiled window draws no shadow)
        g.wm_base = try c.bind(g.registry, name, iface, @min(version, 2));
    } else if (eql(u8, iface, "wl_seat") and g.seat == 0) {
        // v8 adds axis_value120 (exact wheel notches); keymaps are
        // already mapped MAP_PRIVATE as v7 requires
        g.seat_version = @min(version, 8);
        g.seat = try c.bind(g.registry, name, iface, g.seat_version);
    } else if (eql(u8, iface, "wl_data_device_manager")) {
        // v3: drag-and-drop actions (copy) for startDrag
        g.ddm_version = @min(version, 3);
        g.ddm = try c.bind(g.registry, name, iface, g.ddm_version);
    } else return false;
    return true;
}

/// Optional protocol extensions; false when `iface` is none of them.
fn bindExtension(w: *Window, name: u32, iface: []const u8, version: u32) !bool {
    const eql = std.mem.eql;
    const g = &w.globals;
    const c = &w.conn;
    if (eql(u8, iface, "zwlr_layer_shell_v1")) {
        if (std.c.getenv("SHOTLET_NO_LAYER_SHELL") == null) {
            g.layer_shell_version = @min(version, 4);
            g.layer_shell = try c.bind(g.registry, name, iface, g.layer_shell_version);
        }
    } else if (eql(u8, iface, "wp_viewporter")) {
        g.viewporter = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "wp_fractional_scale_manager_v1")) {
        if (std.c.getenv("SHOTLET_NO_FRACTIONAL") == null)
            g.fs_manager = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        if (std.c.getenv("SHOTLET_NO_CURSOR_SHAPE") == null)
            g.cursor_shape = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "zxdg_output_manager_v1")) {
        g.xdg_output_manager = try c.bind(g.registry, name, iface, @min(version, 3));
        _ = try output.ensureAllXdg(w);
    } else if (eql(u8, iface, "zwp_relative_pointer_manager_v1")) {
        g.rel_manager = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "zxdg_exporter_v2")) {
        g.exporter = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "zxdg_exporter_v1")) {
        // the same requests and events; v2 wins when both are offered
        if (g.exporter == 0) g.exporter = try c.bind(g.registry, name, iface, 1);
    } else if (eql(u8, iface, "zwp_text_input_manager_v3")) {
        g.ti_manager = try c.bind(g.registry, name, iface, 1);
    } else return false;
    return true;
}

pub fn handleGlobalRemove(w: *Window, name: u32) !void {
    try output.remove(w, name);
}

/// wl_seat events: follow its capabilities.
pub fn handleSeat(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    if (opcode != wl.wl_seat.ev_capabilities) return;
    w.globals.seat_caps = try r.uint();
    try updateSeatDevices(w);
    try w.conn.flush();
}

/// Take the pointer and keyboard the seat actually has, and let go of
/// ones it lost. Asking for a device the seat does not announce is
/// legal but has crashed compositors (mutter's headless backend).
pub fn updateSeatDevices(w: *Window) !void {
    if (w.globals.seat == 0 or w.surfaces[0].wl_surface == 0) return;
    const caps = w.globals.seat_caps;
    try pointer.updateDevice(w, caps & wl.wl_seat.cap_pointer != 0);
    try keys.updateDevice(w, caps & wl.wl_seat.cap_keyboard != 0);
}
