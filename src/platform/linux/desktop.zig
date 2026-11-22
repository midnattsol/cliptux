//! The desktop seam on Linux: the session bus (with the app's identity
//! for the portals), the appearance from the Settings portal, file
//! dialogs (FileChooser portal), notifications and "show in Files"
//! (org.freedesktop.FileManager1).

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const window = @import("window.zig");
const types = @import("../api/desktop.zig");
const appearance = @import("desktop/appearance.zig");
const save_dialog = @import("desktop/save_dialog.zig");
const filemanager = @import("desktop/filemanager.zig");
const Env = @import("../../app/env.zig").Env;

pub const Appearance = types.Appearance;
pub const SaveOptions = types.SaveOptions;
pub const Choice = types.Choice;

/// The connection to the desktop's services: the D-Bus session bus.
pub const Session = dbus.Connection;

/// A file dialog in progress, answered through pump().
pub const Dialog = portal.Request;

/// Connect to the session, telling the portals who we are.
pub fn connect(gpa: std.mem.Allocator, env: Env) !Session {
    return portal.connectApp(gpa, env.bus_addr);
}

/// Connect without telling the portals who we are (identify() does):
/// for a quick question, or to ask the shell first.
pub fn connectBrief(gpa: std.mem.Allocator, env: Env) !Session {
    return dbus.Connection.connectSession(gpa, env.bus_addr);
}

/// Tell the portals who we are, before any portal call on `s`.
pub fn identify(gpa: std.mem.Allocator, s: *Session) void {
    portal.registerApp(gpa, s);
}

/// The appearance, waiting at most `timeout_ms` for the portal.
pub const readAppearance = appearance.read;

/// Subscribe to appearance changes (pump() folds them in).
pub fn watchAppearance(s: *Session) !void {
    return appearance.watch(s);
}

/// What the desktop sent since the last call, without waiting:
/// appearance changes fold into `look` (true when it changed), and the
/// answer to `dialog` is kept in it (Dialog.done()).
pub fn pump(s: *Session, gpa: std.mem.Allocator, look: *Appearance, dialog: ?*Dialog) bool {
    var changed = false;
    var n: usize = 0;
    while (n < 16) : (n += 1) {
        var msg = (s.nextMessageDeadline(@import("sys.zig").monoMs()) catch break) orelse break;
        if (appearance.applySignal(look, &msg)) changed = true;
        const kept = if (dialog) |r| r.handle(gpa, &msg) catch false else false;
        if (!kept) msg.deinit(gpa);
    }
    return changed;
}

/// Ask where to save a file (blocking); over `over` when given.
pub fn askSavePath(gpa: std.mem.Allocator, s: *Session, opts: SaveOptions, over: ?*window.Window) !Choice {
    return save_dialog.askSavePath(gpa, s, opts, over);
}

/// Start asking for a folder without blocking; pump() until done().
pub fn chooseFolder(gpa: std.mem.Allocator, s: *Session, current: ?[]const u8) !Dialog {
    return portal.beginChooseFolder(gpa, s, .{ .current_folder = current });
}

/// A finished dialog's answer.
pub fn dialogChoice(gpa: std.mem.Allocator, d: *const Dialog) Choice {
    if (d.outcome.? != .granted) return .cancelled;
    const p = portal.chosenPath(gpa, d) catch |err| {
        std.log.warn("file chooser: {t}", .{err});
        return .cancelled;
    };
    return .{ .chosen = p };
}

/// The tray icon's daemon (`shotlet daemon`): StatusNotifierItem.
pub const daemon = @import("desktop/daemon.zig").run;

/// The session's descriptor, to poll with others for what it sends.
pub fn pollFd(s: *const Session) @import("sys.zig").fd_t {
    return s.fd;
}

/// Whether the session already holds messages (poll would not wake).
pub fn hasPending(s: *Session) bool {
    return s.hasPending();
}

/// A notification (best effort).
pub fn notify(gpa: std.mem.Allocator, s: *Session, summary: []const u8, text: []const u8) void {
    portal.notify(gpa, s, summary, text);
}

/// Show `path` selected in the file manager.
pub fn revealFile(gpa: std.mem.Allocator, s: *Session, path: []const u8) !void {
    return filemanager.showItem(gpa, s, path);
}

comptime {
    _ = appearance;
    _ = save_dialog;
}
