//! The first capture through the Screenshot portal: GNOME only asks the
//! focused app for consent, so Shotlet asks from a small window of its own.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const sys = @import("../platform/sys.zig");
const Env = @import("env.zig").Env;

/// First-run consent: open a small focused window, re-request the screenshot
/// so GNOME can show its permission dialog, then recapture once granted.
/// Null when the person closes the window.
pub fn permissionFlow(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) !?[]u8 {
    const window = @import("../ui/window.zig");
    const render = @import("../gfx/render.zig");

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = false, .width = 640, .height = 220 });

    var pending: ?portal.Request = null;
    defer if (pending) |*p| p.deinit(gpa);
    var status: []const u8 = "Press Enter to request it";
    var hint_logged = false;

    var uri: ?[]u8 = null;
    defer if (uri) |u| gpa.free(u);

    outer: while (uri == null) {
        // draw the dialog
        if (!win.frame_pending and win.width > 0) {
            const px = try win.backBuffer();
            @memset(px, 0xFF1D2125);
            var canvas = render.Canvas.init(px, win.width, win.height);
            const w: i32 = @intCast(win.width);
            canvas.rectOutline(0, 0, w, @intCast(win.height), 1, 0xFF3A3F44);
            const title = "Shotlet needs screenshot permission";
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, title), 2), 42, 2, 0xFFE9ECEF, title);
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, status), 2), 96, 2, 0xFF74B3F2, status);
            const hint = "GNOME remembers it (once more after an update)   Esc: cancel";
            canvas.text(@divTrunc(w - render.Canvas.textWidth(1, hint), 2), 156, 1, 0xFF868E96, hint);
            try win.present();
        }

        // pump both wayland and dbus
        try win.conn.flush();
        var fds = [_]sys.pollfd{
            .{ .fd = win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = conn.fd, .events = sys.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&fds, 200);

        if (fds[0].revents != 0 or win.queue.items.len > 0) {
            while (try win.nextEventTimeout(0)) |ev| switch (ev) {
                .key => |k| {
                    if (!k.pressed) continue;
                    if (k.code == window.KEY_ESC) return null;
                    if (k.code == window.KEY_ENTER and pending == null) {
                        pending = try portal.beginScreenshot(gpa, conn, false);
                        status = "Waiting for the system dialog...";
                    }
                },
                .close => return null,
                else => {},
            };
        }
        if (fds[1].revents != 0 or conn.hasPending()) {
            var msg = conn.nextMessage() catch |err| {
                if (dbus.isFatal(err)) return err;
                continue;
            };
            // without an in-flight request, unrelated bus traffic is drained
            // and discarded so poll() never spins on an unread socket
            const req = if (pending) |*p| p else {
                msg.deinit(gpa);
                continue;
            };
            const kept = req.handle(gpa, &msg) catch false;
            if (!kept) msg.deinit(gpa);
            const outcome = req.outcome orelse continue;
            switch (outcome) {
                .granted => {
                    uri = try gpa.dupe(u8, try portal.screenshotUri(req));
                    break :outer;
                },
                .cancelled => return null,
                .unavailable, .timeout => return error.NoScreenshotPortal,
                .denied => {
                    // stay open and let the user retry
                    status = "Denied by the portal - Enter to retry";
                    if (!hint_logged) {
                        hint_logged = true;
                        std.log.warn("portal denied the request; manual grant (plain DBus):", .{});
                        std.log.warn("  busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission sbssas screenshot true screenshot shotlet 1 yes", .{});
                    }
                    req.deinit(gpa);
                    pending = null;
                    continue :outer;
                },
            }
        }
    }

    // this capture contains our dialog; discard and retake without it
    const tainted = try portal.readAndUnlink(gpa, uri.?);
    gpa.free(tainted);
    win.closeWindow();
    // give the compositor a moment to unmap our window
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 400 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    return switch (try portal.screenshot(gpa, conn, false, portal.timeout_dialog_ms)) {
        .granted => |d| d,
        .cancelled => null,
        else => error.NoScreenshotPortal,
    };
}
