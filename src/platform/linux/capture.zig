//! The capture seam on Linux: the frozen frame of every monitor, by the
//! first path that works (the compositor directly: KWin's ScreenShot2 or
//! wlroots screencopy; then the ScreenCast portal over PipeWire; then the
//! Screenshot portal, with the first-run consent window), the windows'
//! frames for click-a-window, window capture without the shell
//! integration, frames for a scrolling capture, and the permissions
//! those paths keep.

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const pw = @import("pw.zig");
const png = @import("../../gfx/png.zig");
const capture = @import("../../app/capture.zig");
const config = @import("../../app/config.zig");
const mode = @import("../../app/modes/mode.zig");
const Env = @import("../../app/env.zig").Env;
const direct = @import("capture/direct.zig");
const path = @import("capture/path.zig");
const screencast = @import("capture/screencast.zig").screencast;
const winrects = @import("capture/winrects.zig");
const reset = @import("capture/perms/reset.zig");

pub const Path = path.Path;
/// Remember how the last capture went.
pub const remember = path.remember;
/// How the last capture went, if known.
pub const lastPath = path.last;

/// Load what the first capture needs ahead (libpipewire: ~50-80 ms), on
/// a thread of the caller's while it sets up the rest.
pub fn warmup() void {
    _ = pw.available();
}

/// Every monitor, frozen, by the first path that works. Null when the
/// person cancelled a dialog (or nobody answered it): stop quietly.
pub fn screens(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config) !?capture.Capture {
    // the desktop's own capture interface: no consent dialog
    if (std.c.getenv("SHOTLET_NO_DIRECT") == null) {
        if (tryDirect(gpa, env, conn)) |cap| return cap;
    }
    if (pw.available()) {
        switch (screencast(gpa, env, conn, cfg)) {
            .granted => |cap| {
                std.log.info("capture path: portal (ScreenCast)", .{});
                path.remember(env.home, .portal);
                return cap;
            },
            .cancelled => return null,
            .timeout => return dialogTimedOut(),
            .denied => std.log.info("screencast denied; trying the screenshot portal", .{}),
            .unavailable => std.log.info("screencast unavailable; trying the screenshot portal", .{}),
        }
    }
    return screenshotPortal(gpa, env, conn);
}

/// The compositor's own capture interface; null (logged) when there is
/// none or it failed, for the portal to take over.
fn tryDirect(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) ?capture.Capture {
    const res = direct.captureAll(gpa, env.runtime_dir, env.session.display, conn) catch |err| {
        std.log.info("capture path: direct capture failed ({t}); the portal", .{err});
        return null;
    };
    switch (res) {
        .captured => |c| {
            std.log.info("capture path: direct ({s})", .{c.method.label()});
            path.remember(env.home, .direct);
            return c.cap;
        },
        .unavailable => |why| {
            std.log.info("capture path: no direct capture ({s}); the portal", .{why});
            return null;
        },
    }
}

/// The Screenshot portal, the last resort; null when cancelled.
fn screenshotPortal(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) !?capture.Capture {
    std.log.info("capture path: portal (Screenshot)", .{});
    path.remember(env.home, .portal);
    const png_data = switch (try portal.screenshot(gpa, conn, false, portal.timeout_unfocused_screenshot_ms)) {
        .granted => |d| d,
        .cancelled => return null,
        // GNOME only shows its consent dialog to the focused app, so a
        // windowless first run is denied (or, with no app focused, never
        // answered); ask again from a focused window
        .denied, .timeout => (try @import("capture/first_run.zig").permissionFlow(gpa, env, conn)) orelse return null,
        .unavailable => return error.NoScreenshotPortal,
    };
    defer gpa.free(png_data);
    var img = try png.decode(gpa, png_data);
    errdefer img.deinit(gpa);
    return try capture.Capture.single(gpa, img);
}

/// Nobody answered a consent dialog for timeout_dialog_ms: it was closed;
/// end quietly, like a cancel.
fn dialogTimedOut() ?capture.Capture {
    std.log.info("the permission dialog got no answer; closed it and stopped", .{});
    return null;
}

/// The windows' frames when `cap` was taken (image pixels), for clicking
/// one; `shell_id`: the shell integration's capture, which knows them.
pub const windows = winrects.fetch;
pub const max_windows = winrects.max_windows;

/// Whether a window's own pixels can be captured here (window mode).
pub const canCaptureWindow = winrects.windowCapture;

/// Window capture where the shell integration does not do it (KWin's
/// picker; wlroots has none): true when it handled `req`.
pub const captureWindow = @import("capture/window_direct.zig").run;

/// Frames of a region for a scrolling capture, and who scrolls.
pub const ScrollSource = @import("capture/scroll_source.zig").Source;
pub const openScroll = @import("capture/scroll_source.zig").open;
/// Whether a scrolling capture can run here, before a region is picked.
pub const ScrollSupport = @import("../api/capture.zig").ScrollSupport;
pub const scrollSupport = @import("capture/scroll_support.zig").support;

/// Forget the permissions captures keep (restore token, the portal's
/// grants); with `dry_run` only find them.
pub const resetPermissions = reset.run;
pub const ResetOutcome = reset.Outcome;
/// A short line about a reset.
pub const resetSummary = reset.summary;

/// `shotlet permissions [reset [--dry-run]]`.
pub const permissionsCli = @import("capture/permissions.zig").run;

comptime {
    _ = direct;
    _ = winrects;
    _ = @import("capture/scroll_support.zig");
}
