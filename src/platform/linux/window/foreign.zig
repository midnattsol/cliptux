//! xdg-foreign (zxdg_exporter_v2, or v1): a handle to the window's
//! toplevel that another client can parent its dialog to, such as the
//! portal's file chooser ("wayland:HANDLE" as its parent_window).

const std = @import("std");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const events = @import("events.zig");

const Window = window.Window;

/// Both versions: exporter request 1 exports a toplevel, the exported
/// object's event 0 is its handle, request 0 destroys either.
const export_toplevel = 1;
const ev_handle = 0;
const destroy = 0;

/// Export surface 0's toplevel; "wayland:HANDLE" in `buf`. It stays
/// exported until unexport() (or another export).
pub fn parentHandle(w: *Window, buf: []u8) ![]const u8 {
    const s = &w.surfaces[0];
    if (w.globals.exporter == 0) return error.Unsupported;
    if (!s.alive or s.toplevel == 0) return error.NoToplevel;
    unexport(w);
    const c = &w.conn;
    const id = c.newId();
    try c.request(w.globals.exporter, export_toplevel, &.{ .{ .new_id = id }, .{ .object = s.wl_surface } });
    w.exported = id;
    const cb = try c.sync();
    var handle: ?[]const u8 = null;
    while (true) {
        const ev = try c.readEvent();
        if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) break;
        if (ev.object == id and ev.opcode == ev_handle) {
            var r = wl.ArgReader{ .data = ev.body };
            handle = try std.fmt.bufPrint(buf, "wayland:{s}", .{try r.string()});
        } else try events.handleEvent(w, ev);
    }
    return handle orelse error.NoHandle;
}

/// Withdraw the handle parentHandle() gave out.
pub fn unexport(w: *Window) void {
    if (w.exported == 0) return;
    w.conn.request(w.exported, destroy, &.{}) catch {};
    w.exported = 0;
    w.conn.flush() catch {};
}
