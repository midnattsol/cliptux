//! The capture seam of the contract: every monitor frozen (asking for
//! permission where the platform does), the windows' frames for
//! click-a-window, window capture, frames for a scrolling capture, and
//! the permissions captures keep.

const std = @import("std");
const types = @import("../api/capture.zig");
const desktop = @import("desktop.zig");
const capture = @import("../../app/capture.zig");
const config = @import("../../app/config.zig");
const mode = @import("../../app/modes/mode.zig");
const geom = @import("../../app/modes/geom.zig");
const png = @import("../../gfx/png.zig");
const Rect = @import("../../ui/shapes.zig").Rect;
const Env = @import("../../app/env.zig").Env;

pub const Path = types.Path;

/// Remember how the last capture went.
pub fn remember(home: []const u8, p: Path) void {
    _ = .{ home, p };
}
/// How the last capture went, if known.
pub fn lastPath(home: []const u8) ?Path {
    _ = home;
    return null;
}
/// Load what the first capture needs ahead, on a thread of the caller's.
pub fn warmup() void {}

/// Every monitor, frozen. Null when the person cancelled.
pub fn screens(gpa: std.mem.Allocator, env: Env, s: *desktop.Session, cfg: *config.Config) error{Unavailable}!?capture.Capture {
    _ = .{ gpa, env, s, cfg };
    return error.Unavailable;
}

pub const max_windows = 64;
/// The windows' frames when `cap` was taken (image pixels, owned).
pub fn windows(gpa: std.mem.Allocator, env: Env, s: *desktop.Session, cap: *const capture.Capture, shell_id: ?[]const u8) []Rect {
    _ = .{ gpa, env, s, cap, shell_id };
    return &.{};
}
/// Whether a window's own pixels can be captured here.
pub fn canCaptureWindow(s: *desktop.Session) bool {
    _ = s;
    return false;
}
/// Window capture without the shell integration: true when it handled it.
pub fn captureWindow(gpa: std.mem.Allocator, env: Env, req: mode.Request) error{Unavailable}!bool {
    _ = .{ gpa, env, req };
    return false;
}

/// Frames of a region for a scrolling capture, and who scrolls.
pub const ScrollSource = union(enum) {
    none,

    /// Whether frames come after a scroll Shotlet makes.
    pub fn scrolls(self: *const ScrollSource) bool {
        _ = self;
        return false;
    }
    pub fn deinit(self: *ScrollSource) void {
        _ = self;
    }
    /// Scroll `clicks` notches (0: none), then the region's frame.
    pub fn grab(self: *ScrollSource, gpa: std.mem.Allocator, env: Env, s: *desktop.Session, clicks: i32) error{Unavailable}!png.Image {
        _ = .{ self, gpa, env, s, clicks };
        return error.Unavailable;
    }
};
pub fn openScroll(gpa: std.mem.Allocator, env: Env, s: *desktop.Session, cap: *const capture.Capture, region: geom.Rect, shell: bool, auto: bool) error{Unavailable}!ScrollSource {
    _ = .{ gpa, env, s, cap, region, shell, auto };
    return error.Unavailable;
}

pub const ResetOutcome = struct {};
/// Forget the permissions captures keep; with `dry_run` only find them.
pub fn resetPermissions(arena: std.mem.Allocator, env: Env, s: ?*desktop.Session, dry_run: bool) ResetOutcome {
    _ = .{ arena, env, s, dry_run };
    return .{};
}
/// A short line about a reset.
pub fn resetSummary(o: ResetOutcome, buf: []u8) []const u8 {
    _ = .{ o, buf };
    return "";
}
/// `shotlet permissions [reset [--dry-run]]`.
pub fn permissionsCli(gpa: std.mem.Allocator, env: Env, args: []const []const u8) error{Unavailable}!void {
    _ = .{ gpa, env, args };
    return error.Unavailable;
}
