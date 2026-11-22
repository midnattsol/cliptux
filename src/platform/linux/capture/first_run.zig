//! The first capture through the Screenshot portal: GNOME only asks the
//! focused app for consent, so Shotlet asks from a small window of its own.

const std = @import("std");
const dbus = @import("../dbus.zig");
const portal = @import("../portal.zig");
const sys = @import("../sys.zig");
const Env = @import("../../../app/env.zig").Env;

const window = @import("../window.zig");
const render = @import("../../../gfx/render.zig");

/// First-run consent: open a small focused window, re-request the screenshot
/// so GNOME can show its permission dialog, then recapture once granted.
/// Null when the person closes the window.
pub fn permissionFlow(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) !?[]u8 {
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = false, .width = 640, .height = 220 });

    var dlg: Dialog = .{ .gpa = gpa, .win = &win, .conn = conn };
    defer if (dlg.pending) |*p| p.deinit(gpa);
    const uri = (try dlg.waitForGrant()) orelse return null;
    defer gpa.free(uri);

    // this capture contains our dialog; discard and retake without it
    const tainted = try portal.readAndUnlink(gpa, uri);
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

/// The consent window and the screenshot request it has in flight.
const Dialog = struct {
    gpa: std.mem.Allocator,
    win: *window.Window,
    conn: *dbus.Connection,
    pending: ?portal.Request = null,
    status: []const u8 = "Press Enter to request it",
    hint_logged: bool = false,

    /// What a bus message did to the request.
    const BusStep = union(enum) { wait, cancel, granted: []u8 };

    /// Pumps both Wayland and DBus until the portal grants a screenshot
    /// (its URI, owned) or the person cancels (null).
    fn waitForGrant(d: *Dialog) !?[]u8 {
        while (true) {
            if (!d.win.frame_pending and d.win.width > 0) try d.draw();
            try d.win.conn.flush();
            var fds = [_]sys.pollfd{
                .{ .fd = d.win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
                .{ .fd = d.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            };
            _ = try sys.poll(&fds, 200);
            if (fds[0].revents != 0 or d.win.queue.items.len > 0) {
                if (!try d.pumpWindow()) return null;
            }
            if (fds[1].revents != 0 or d.conn.hasPending()) {
                switch (try d.pumpBus()) {
                    .wait => {},
                    .cancel => return null,
                    .granted => |uri| return uri,
                }
            }
        }
    }

    fn draw(d: *Dialog) !void {
        const win = d.win;
        const px = try win.backBuffer();
        @memset(px, 0xFF1D2125);
        var canvas = render.Canvas.init(px, win.width, win.height);
        const w: i32 = @intCast(win.width);
        canvas.rectOutline(0, 0, w, @intCast(win.height), 1, 0xFF3A3F44);
        const title = "Shotlet needs screenshot permission";
        canvas.text(@divTrunc(w - render.Canvas.textWidth(2, title), 2), 42, 2, 0xFFE9ECEF, title);
        canvas.text(@divTrunc(w - render.Canvas.textWidth(2, d.status), 2), 96, 2, 0xFF74B3F2, d.status);
        const hint = "GNOME remembers it (once more after an update)   Esc: cancel";
        canvas.text(@divTrunc(w - render.Canvas.textWidth(1, hint), 2), 156, 1, 0xFF868E96, hint);
        try win.present();
    }

    /// Handles queued window events; false when the person cancelled.
    fn pumpWindow(d: *Dialog) !bool {
        while (try d.win.nextEventTimeout(0)) |ev| switch (ev) {
            .key => |k| {
                if (!k.pressed) continue;
                if (k.code == .escape) return false;
                if (k.code == .enter and d.pending == null) {
                    d.pending = try portal.beginScreenshot(d.gpa, d.conn, false);
                    d.status = "Waiting for the system dialog...";
                }
            },
            .close => return false,
            else => {},
        };
        return true;
    }

    /// Reads one bus message and feeds it to the pending request.
    fn pumpBus(d: *Dialog) !BusStep {
        const gpa = d.gpa;
        var msg = d.conn.nextMessage() catch |err| {
            if (dbus.isFatal(err)) return err;
            return .wait;
        };
        // without an in-flight request, unrelated bus traffic is drained
        // and discarded so poll() never spins on an unread socket
        const req = if (d.pending) |*p| p else {
            msg.deinit(gpa);
            return .wait;
        };
        const kept = req.handle(gpa, &msg) catch false;
        if (!kept) msg.deinit(gpa);
        const outcome = req.outcome orelse return .wait;
        switch (outcome) {
            .granted => return .{ .granted = try gpa.dupe(u8, try portal.screenshotUri(req)) },
            .cancelled => return .cancel,
            .unavailable, .timeout => return error.NoScreenshotPortal,
            .denied => {
                d.onDenied();
                return .wait;
            },
        }
    }

    /// Stays open so the person can retry; logs the manual grant once.
    fn onDenied(d: *Dialog) void {
        d.status = "Denied by the portal - Enter to retry";
        if (!d.hint_logged) {
            d.hint_logged = true;
            std.log.warn("portal denied the request; manual grant (plain DBus):", .{});
            std.log.warn("  busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission sbssas screenshot true screenshot shotlet 1 yes", .{});
        }
        d.pending.?.deinit(d.gpa);
        d.pending = null;
    }
};
