//! Save dialogs through the FileChooser portal. Over a window (Save As
//! from the editor, like a macOS sheet) the dialog is parented to it
//! (xdg-foreign), and the window keeps answering the compositor
//! meanwhile; cancelling leaves it exactly as it was.

const std = @import("std");
const dbus = @import("../dbus.zig");
const portal = @import("../portal.zig");
const sys = @import("../sys.zig");
const window = @import("../window.zig");
const types = @import("../../api/desktop.zig");

/// Ask where to save; with `over`, the dialog belongs to that window.
pub fn askSavePath(gpa: std.mem.Allocator, conn: *dbus.Connection, opts: types.SaveOptions, over: ?*window.Window) !types.Choice {
    var buf: [256]u8 = undefined;
    const parent: []const u8 = if (over) |win| win.parentHandle(&buf) catch |err| blk: {
        std.log.info("save as: no parent for the dialog ({t})", .{err});
        break :blk "";
    } else "";
    defer if (over) |win| win.unexport();
    var req = try portal.beginSaveFile(gpa, conn, .{
        .title = opts.title,
        .current_name = opts.current_name,
        .current_folder = opts.current_folder,
        .parent_window = parent,
    });
    defer req.deinit(gpa);
    if (over) |win| {
        try (OverWindow{ .gpa = gpa, .conn = conn, .win = win }).wait(&req);
    } else {
        try req.wait(gpa, conn, portal.timeout_file_chooser_ms);
    }
    return switch (try portal.savedPath(gpa, &req)) {
        .granted => |p| .{ .chosen = p },
        .cancelled, .denied, .timeout => .cancelled,
        .unavailable => .unavailable,
    };
}

const OverWindow = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    win: *window.Window,

    /// Bus messages for the request and Wayland events for the window
    /// until the dialog is answered (or the portal never takes it).
    pub fn wait(self: OverWindow, req: *portal.Request) !void {
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

    fn takeMessages(self: OverWindow, req: *portal.Request) !void {
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

/// What reaches the window while the dialog is up is not for it; a
/// resize is kept for when it is back.
fn dropInput(win: *window.Window) void {
    var i: usize = 0;
    while (i < win.queue.items.len) {
        if (win.queue.items[i] == .resize) i += 1 else _ = win.queue.orderedRemove(i);
    }
}
