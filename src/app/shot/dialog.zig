//! Save As over the still-open editor, like a macOS sheet: the
//! FileChooser portal's dialog is parented to the editor (xdg-foreign),
//! which keeps answering the compositor meanwhile. Cancelling leaves the
//! editor exactly as it was.

const std = @import("std");
const config = @import("../config.zig");
const dbus = @import("../../platform/linux/dbus.zig");
const env_mod = @import("../env.zig");
const portal = @import("../../platform/linux/portal.zig");
const sys = @import("../../platform/linux/sys.zig");
const window = @import("../../platform/linux/window.zig");
const save = @import("save.zig");

const Env = env_mod.Env;

/// Ask where to save over `win`'s editor; see save.saveAs.
pub fn saveAs(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *const config.Config, win: *window.Window, data: []const u8) !?[]u8 {
    var buf: [256]u8 = undefined;
    const parent = win.parentHandle(&buf) catch |err| blk: {
        std.log.info("save as: no parent for the dialog ({t})", .{err});
        break :blk "";
    };
    defer win.unexport();
    return save.saveAsWith(gpa, env, conn, cfg, data, OverEditor{ .gpa = gpa, .conn = conn, .win = win, .parent_window = parent });
}

const OverEditor = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    win: *window.Window,
    parent_window: []const u8,

    /// Bus messages for the request and Wayland events for the editor
    /// until the dialog is answered (or the portal never takes it).
    pub fn wait(self: OverEditor, req: *portal.Request) !void {
        const start = sys.monoMs();
        while (!req.done()) {
            try self.takeMessages(req);
            if (req.done() or expired(self.conn, req, start)) return;
            var fds = [_]sys.pollfd{
                .{ .fd = self.conn.fd, .events = sys.POLL.IN, .revents = 0 },
                .{ .fd = self.win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            };
            _ = try sys.poll(&fds, self.win.pollTimeoutMs(250));
            _ = try self.win.nextEventTimeout(0);
            dropInput(self.win);
        }
    }

    fn takeMessages(self: OverEditor, req: *portal.Request) !void {
        while (try self.conn.nextMessageDeadline(sys.monoMs())) |m| {
            var msg = m;
            const kept = req.handle(self.gpa, &msg) catch false;
            if (!kept) msg.deinit(self.gpa);
            if (req.done()) return;
        }
    }
};

/// The portal must take the call within timeout_quick_ms, and the
/// person answer within timeout_file_chooser_ms (as Request.wait).
fn expired(conn: *dbus.Connection, req: *portal.Request, start: i64) bool {
    const age = sys.monoMs() - start;
    if (!req.got_reply and age > portal.timeout_quick_ms) {
        std.log.warn("save as: no reply from the portal; giving up", .{});
        req.outcome = .unavailable;
    } else if (age > portal.timeout_file_chooser_ms) {
        req.close(conn);
        req.outcome = .timeout;
    }
    return req.done();
}

/// What reaches the editor while the dialog is up is not for it; a
/// resize is kept for when it is back.
fn dropInput(win: *window.Window) void {
    var i: usize = 0;
    while (i < win.queue.items.len) {
        if (win.queue.items[i] == .resize) i += 1 else _ = win.queue.orderedRemove(i);
    }
}
