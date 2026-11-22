//! The editor's way out after Copy, Save or Cancel. The editor eases back
//! to the plain capture (ui/editor/fade.zig) while a worker thread keeps
//! the capture and starts its thumbnail; the window goes once the
//! thumbnail committed its first frame, so there is no moment with
//! neither on screen. The slower rest of the history entry (the source
//! to edit it again, pruning) is written after that.

const std = @import("std");
const config = @import("../config.zig");
const env_mod = @import("../env.zig");
const keep_mod = @import("../keep.zig");
const sys = @import("../../platform/sys.zig");
const window = @import("../../ui/window.zig");
const editor_mod = @import("../../ui/editor.zig");

const Env = env_mod.Env;

/// How long the faded-out editor waits for the thumbnail at most.
const ready_timeout_ms = 1500;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: *const config.Config,
    win: *window.Window,
    ed: *editor_mod.Editor,
};

/// Close the editor. `what`: the capture to keep (null: nothing, a
/// Cancel); `thumbnail`: show it in the floating thumbnail.
pub fn close(c: Ctx, what: ?keep_mod.What, thumbnail: bool) void {
    var job: Keeping = .{ .gpa = c.gpa, .env = c.env, .cfg = c.cfg, .thumbnail = thumbnail };
    if (what) |w| job.what = w;
    const worker = if (what != null) std.Thread.spawn(.{}, Keeping.work, .{&job}) catch blk: {
        job.work();
        break :blk null;
    } else null;
    c.ed.fadeOut() catch |err| std.log.debug("editor fade: {t}", .{err});
    if (worker) |t| t.join();
    if (job.ready >= 0) {
        waitReady(c.win, job.ready);
        sys.close(job.ready);
    }
    c.win.closeWindow();
    if (job.kept) |*k| keep_mod.finishEntry(c.gpa, c.cfg, k, job.what);
}

/// Keeping the capture and starting its thumbnail, off the main thread.
const Keeping = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: *const config.Config,
    thumbnail: bool,
    what: keep_mod.What = .{ .image_png = "" },
    kept: ?keep_mod.Kept = null,
    /// read end of the thumbnail's ready pipe (-1: none)
    ready: sys.fd_t = -1,

    fn work(self: *Keeping) void {
        self.kept = keep_mod.keepEntry(self.gpa, self.env, self.cfg, self.what);
        const k = &(self.kept orelse return);
        if (!self.thumbnail) return;
        const fds = sys.pipe() catch {
            keep_mod.spawnQuick(self.gpa, self.env, k, null);
            return;
        };
        keep_mod.spawnQuick(self.gpa, self.env, k, fds[1]);
        sys.close(fds[1]);
        self.ready = fds[0];
    }
};

/// Until the thumbnail says its first frame is out (or gave up), the
/// editor answering the compositor meanwhile.
fn waitReady(win: *window.Window, ready: sys.fd_t) void {
    const deadline = sys.monoMs() + ready_timeout_ms;
    while (sys.monoMs() < deadline) {
        var fds = [_]sys.pollfd{
            .{ .fd = ready, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
        };
        _ = sys.poll(&fds, @intCast(@max(1, deadline - sys.monoMs()))) catch return;
        if (fds[0].revents != 0) return;
        _ = win.nextEventTimeout(0) catch return;
        win.queue.clearRetainingCapacity();
    }
    std.log.info("the thumbnail took over {d} ms to show; closing the editor anyway", .{ready_timeout_ms});
}
