//! The desktop seam of the contract: a session with the desktop's
//! services (opened once per process), its appearance, file dialogs,
//! notifications and revealing a file in the file manager.

const std = @import("std");
const types = @import("../api/desktop.zig");
const window = @import("window.zig");
const Env = @import("../../app/env.zig").Env;

pub const Appearance = types.Appearance;
pub const SaveOptions = types.SaveOptions;
pub const Choice = types.Choice;

pub const Session = struct {
    pub fn deinit(self: *Session) void {
        _ = self;
    }
};

/// A file dialog in progress, answered through pump().
pub const Dialog = struct {
    pub fn done(self: *const Dialog) bool {
        _ = self;
        return true;
    }
    pub fn deinit(self: *Dialog, gpa: std.mem.Allocator) void {
        _ = .{ self, gpa };
    }
};

/// Where the session's services are, from the environment (`vars.get`);
/// the core keeps them in Env.bus_addr and Env.wayland_display.
pub fn addresses(arena: std.mem.Allocator, vars: anytype, runtime_dir: []const u8) error{OutOfMemory}!struct { bus: []const u8, display: []const u8 } {
    _ = .{ arena, vars, runtime_dir };
    return .{ .bus = "", .display = "" };
}
pub fn connect(gpa: std.mem.Allocator, env: Env) error{Unavailable}!Session {
    _ = .{ gpa, env };
    return error.Unavailable;
}
/// Connect without telling the desktop who we are (identify() does).
pub fn connectBrief(gpa: std.mem.Allocator, env: Env) error{Unavailable}!Session {
    _ = .{ gpa, env };
    return error.Unavailable;
}
/// Tell the desktop's services who we are.
pub fn identify(gpa: std.mem.Allocator, s: *Session) void {
    _ = .{ gpa, s };
}
/// The appearance, waiting at most `timeout_ms`.
pub fn readAppearance(s: *Session, timeout_ms: i64) Appearance {
    _ = .{ s, timeout_ms };
    return .{};
}
/// Follow appearance changes (pump() folds them in).
pub fn watchAppearance(s: *Session) error{Unavailable}!void {
    _ = s;
}
/// What the desktop sent since the last call, without waiting:
/// appearance changes fold into `look` (true when it changed), the
/// answer to `dialog` is kept in it.
pub fn pump(s: *Session, gpa: std.mem.Allocator, look: *Appearance, dialog: ?*Dialog) bool {
    _ = .{ s, gpa, look, dialog };
    return false;
}
/// Ask where to save a file (blocking); over `over` when given.
pub fn askSavePath(gpa: std.mem.Allocator, s: *Session, opts: SaveOptions, over: ?*window.Window) error{OutOfMemory}!Choice {
    _ = .{ gpa, s, opts, over };
    return .unavailable;
}
/// Start asking for a folder without blocking; pump() until done().
pub fn chooseFolder(gpa: std.mem.Allocator, s: *Session, current: ?[]const u8) error{Unavailable}!Dialog {
    _ = .{ gpa, s, current };
    return error.Unavailable;
}
/// A finished dialog's answer.
pub fn dialogChoice(gpa: std.mem.Allocator, d: *const Dialog) Choice {
    _ = .{ gpa, d };
    return .unavailable;
}
/// The tray icon's daemon (`shotlet daemon`).
pub fn daemon(gpa: std.mem.Allocator, env: Env, foreground: bool) error{Unavailable}!void {
    _ = .{ gpa, env, foreground };
    return error.Unavailable;
}
/// The session's descriptor, to poll with others for what it sends.
pub fn pollFd(s: *const Session) @import("sys.zig").fd_t {
    _ = s;
    return -1;
}
/// Whether the session already holds messages (poll would not wake).
pub fn hasPending(s: *Session) bool {
    _ = s;
    return false;
}
pub fn notify(gpa: std.mem.Allocator, s: *Session, summary: []const u8, text: []const u8) void {
    _ = .{ gpa, s, summary, text };
}
/// Show `path` selected in the file manager.
pub fn revealFile(gpa: std.mem.Allocator, s: *Session, path: []const u8) error{Unavailable}!void {
    _ = .{ gpa, s, path };
    return error.Unavailable;
}
