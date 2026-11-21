//! GNOME integration: the Shotlet GNOME Shell extension (gnome-extension/
//! in the source tree, embedded in the binary) places the quick-access
//! thumbnail and keeps it and pins above other windows, which a Wayland
//! client cannot do on mutter (no layer shell there).
//!
//!     shotlet gnome-integration status|install|uninstall
//!
//! install asks GNOME Shell to install it from extensions.gnome.org
//! (InstallRemoteExtension: GNOME asks for confirmation and loads it at
//! once); when that is not possible it copies the bundled extension to
//! ~/.local/share/gnome-shell/extensions and enables it. GNOME Shell on
//! Wayland only discovers a newly copied extension at the next login.
//!
//! The extension also captures without prompts (see its extension.js):
//! its own shortcut, and dev.shotlet.Shell1.Capture() for Shotlet's tray
//! and a `shotlet` run from a terminal. Once it is active, install points
//! it at this binary and offers to move custom shortcuts that run shotlet
//! to the extension's shortcut (uninstall puts them back).
//!
//!     shotlet gnome-integration shortcut [ACCEL... | none]
//!     shotlet gnome-integration shortcut MODE [ACCEL... | none]

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const sys = @import("../platform/sys.zig");
const env_mod = @import("env.zig");
const gsettings = @import("gsettings.zig");
const Env = env_mod.Env;

pub const uuid = "shotlet@midnattsol.github.io";
/// owned by the extension while it is active
pub const bus_name = "dev.shotlet.Shell1";

const ext_js = @embedFile("gnome_ext_js");
const ext_metadata = @embedFile("gnome_ext_metadata");
/// extension.js's own modules: file name, contents
const ext_modules = [_][2][]const u8{
    .{ "modes.js", @embedFile("gnome_ext_modes_js") },
    .{ "windowpick.js", @embedFile("gnome_ext_windowpick_js") },
    .{ "scroll.js", @embedFile("gnome_ext_scroll_js") },
    .{ "util.js", @embedFile("gnome_ext_util_js") },
};
const ext_schema = @embedFile("gnome_ext_schema");
const ext_schema_compiled = @embedFile("gnome_ext_schema_compiled");
const schema_file = "org.gnome.shell.extensions.shotlet.gschema.xml";

/// the extension's own settings (schemas/ in its directory)
pub const ext_schema_id = "org.gnome.shell.extensions.shotlet";
const shell1_path = "/dev/shotlet/Shell1";
const shell1_iface = "dev.shotlet.Shell1";
const media_keys = "org.gnome.settings-daemon.plugins.media-keys";
const custom_schema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";

const shell_dest = "org.gnome.Shell.Extensions";
const shell_path = "/org/gnome/Shell/Extensions";
const shell_iface = "org.gnome.Shell.Extensions";

/// XDG_CURRENT_DESKTOP names GNOME.
pub fn isGnome() bool {
    const d = std.mem.span(std.c.getenv("XDG_CURRENT_DESKTOP") orelse return false);
    var it = std.mem.splitScalar(u8, d, ':');
    while (it.next()) |part| if (std.ascii.eqlIgnoreCase(part, "GNOME")) return true;
    return false;
}

/// The extension is loaded and running in this session.
pub fn extensionActive(bus: *dbus.Connection) bool {
    return bus.nameHasOwner(bus_name) catch false;
}

/// GNOME Shell's view of the extension (org.gnome.Shell.Extensions
/// state): 1 active, 2 inactive, 3 error, 4 out of date, 6 initialized,
/// 99 unknown to it; null without GNOME Shell.
pub fn shellState(gpa: std.mem.Allocator, bus: *dbus.Connection) ?u32 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(uuid) catch return null;
    const serial = bus.callMethod(shell_dest, shell_path, shell_iface, "GetExtensionInfo", "s", m.buf.items) catch return null;
    var reply = bus.waitReplyTimeout(serial, 5000) catch return null;
    defer reply.deinit(gpa);
    var r = reply.reader();
    var it = r.readDictSV() catch return null;
    while (it.next() catch return null) |kv| {
        if (std.mem.eql(u8, kv.key, "state")) return switch (kv.value) {
            .f64_ => |v| @intFromFloat(@max(0, v)),
            .u32_ => |v| v,
            .i32_ => |v| @intCast(@max(0, v)),
            else => null,
        };
    }
    return 99; // an empty dict: not installed
}

fn callBool(gpa: std.mem.Allocator, bus: *dbus.Connection, member: []const u8, timeout_ms: i64) !bool {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(uuid);
    const serial = try bus.callMethod(shell_dest, shell_path, shell_iface, member, "s", m.buf.items);
    var reply = try bus.waitReplyTimeout(serial, timeout_ms);
    defer reply.deinit(gpa);
    var r = reply.reader();
    return (try r.readU32()) != 0;
}

/// InstallRemoteExtension: "successful", "cancelled", or an error.
fn installRemote(gpa: std.mem.Allocator, bus: *dbus.Connection) !bool {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(uuid);
    const serial = try bus.callMethod(shell_dest, shell_path, shell_iface, "InstallRemoteExtension", "s", m.buf.items);
    // GNOME shows a confirmation dialog: give the person time
    var reply = try bus.waitReplyTimeout(serial, 120_000);
    defer reply.deinit(gpa);
    var r = reply.reader();
    return std.mem.eql(u8, try r.readString(), "successful");
}

fn extensionDir(buf: []u8, home: []const u8) ![]u8 {
    const data_home = env_mod.absolute(if (std.c.getenv("XDG_DATA_HOME")) |p| std.mem.span(p) else null);
    if (data_home) |d| return std.fmt.bufPrint(buf, "{s}/gnome-shell/extensions/{s}", .{ d, uuid });
    return std.fmt.bufPrint(buf, "{s}/.local/share/gnome-shell/extensions/{s}", .{ home, uuid });
}

/// Copy the bundled extension into the user's extension directory.
pub fn writeBundled(home: []const u8) ![]const u8 {
    const S = struct {
        var dir_buf: [1024]u8 = undefined;
    };
    const dir = try extensionDir(&S.dir_buf, home);
    sys.mkdirAll(dir, 0o755);
    var p: [1100]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/extension.js", .{dir}), ext_js);
    try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/metadata.json", .{dir}), ext_metadata);
    for (ext_modules) |mod| try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, mod[0] }), mod[1]);
    const schemas = try std.fmt.bufPrint(&p, "{s}/schemas", .{dir});
    sys.mkdirAll(schemas, 0o755);
    var q: [1200]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&q, "{s}/" ++ schema_file, .{schemas}), ext_schema);
    try sys.writeFile(try std.fmt.bufPrint(&q, "{s}/gschemas.compiled", .{schemas}), ext_schema_compiled);
    return dir;
}

pub const InstallResult = enum { active, installed_relogin, failed };

/// What to do with custom shortcuts that run shotlet once the extension
/// is active.
pub const MoveShortcuts = enum { ask, yes, no };

/// Install and enable the extension (see the top of the file); once it
/// is active, set it up for prompt-free captures.
pub fn install(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection, move: MoveShortcuts) InstallResult {
    const r = installExtension(gpa, env, bus_opt);
    if (r == .active) setUp(gpa, env, bus_opt.?, move);
    return r;
}

fn installExtension(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection) InstallResult {
    const bus = bus_opt orelse return .failed;
    if (extensionActive(bus)) return .active;
    const state = shellState(gpa, bus);
    if (state == null) {
        std.log.warn("GNOME Shell is not running here", .{});
        return .failed;
    }
    if (state.? == 99) {
        if (installRemote(gpa, bus)) |ok| {
            if (ok and waitActive(bus)) return .active;
        } else |err| std.log.info("extensions.gnome.org install not possible ({t}); using the bundled copy", .{err});
    }
    const dir = writeBundled(env.home) catch |err| {
        std.log.warn("could not copy the extension: {t}", .{err});
        return .failed;
    };
    std.log.info("installed the GNOME Shell extension in {s}", .{dir});
    _ = callBool(gpa, bus, "EnableExtension", 5000) catch |err|
        std.log.warn("could not enable the extension: {t}", .{err});
    if (waitActive(bus)) return .active;
    return .installed_relogin;
}

fn waitActive(bus: *dbus.Connection) bool {
    const end = sys.monoMs() + 2000;
    while (sys.monoMs() < end) {
        if (extensionActive(bus)) return true;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return false;
}

// --- prompt-free captures

pub const CaptureRequest = enum {
    /// the extension took the screenshot and started the editor
    started,
    /// a capture is already under way, or the screen is locked: nothing
    /// else should capture now
    declined,
    /// not possible (an older extension, a failure): capture another way
    unavailable,
};

/// Ask the extension to take a screenshot and start Shotlet's editor on
/// it (dev.shotlet.Shell1.Capture: no pixels come back over the bus).
pub fn requestCapture(gpa: std.mem.Allocator, bus: *dbus.Connection) CaptureRequest {
    const serial = bus.callMethod(bus_name, shell1_path, shell1_iface, "Capture", "", "") catch return .unavailable;
    var reply = bus.waitReplyOrError(serial, 5000) catch |err| {
        std.log.info("GNOME integration capture: {t}", .{err});
        return .unavailable;
    };
    defer reply.deinit(gpa);
    var r = reply.reader();
    if (reply.type == .@"error") {
        const name = reply.error_name orelse "?";
        std.log.info("GNOME integration capture refused: {s} ({s})", .{ name, r.readString() catch "" });
        if (std.mem.eql(u8, name, shell1_iface ++ ".Error.Busy") or std.mem.eql(u8, name, shell1_iface ++ ".Error.Locked")) return .declined;
        return .unavailable;
    }
    return if ((r.readU32() catch 0) != 0) .started else .unavailable;
}

/// How captures go, for `status` and the Settings window.
pub const CaptureInfo = struct {
    /// the extension is active and captures (version 2 and later)
    capture: bool = false,
    /// its bound shortcut, or the one GNOME's screenshot tool holds
    shortcut_buf: [64]u8 = undefined,
    shortcut_len: usize = 0,
    blocked: bool = false,

    pub fn shortcut(self: *const CaptureInfo) ?[]const u8 {
        return if (self.shortcut_len > 0) self.shortcut_buf[0..self.shortcut_len] else null;
    }
};

pub fn captureInfo(gpa: std.mem.Allocator, bus: *dbus.Connection) CaptureInfo {
    var info: CaptureInfo = .{};
    if (!extensionActive(bus)) return info;
    var msg = getProperty(gpa, bus, "Version") catch return info;
    defer msg.deinit(gpa);
    var r = msg.reader();
    const v = r.readVariant() catch return info;
    if (v != .u32_ or v.u32_ < 2) return info;
    info.capture = true;
    for ([_][]const u8{ "Shortcuts", "BlockedShortcuts" }) |prop| {
        var m = getProperty(gpa, bus, prop) catch continue;
        defer m.deinit(gpa);
        var pr = m.reader();
        const first = readFirstOfStrvVariant(&pr) catch continue;
        if (first) |acc| {
            const n = @min(acc.len, info.shortcut_buf.len);
            @memcpy(info.shortcut_buf[0..n], acc[0..n]);
            info.shortcut_len = n;
            info.blocked = std.mem.eql(u8, prop, "BlockedShortcuts");
            break;
        }
    }
    return info;
}

fn getProperty(gpa: std.mem.Allocator, bus: *dbus.Connection, prop: []const u8) !dbus.Message {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(shell1_iface);
    try m.putString(prop);
    const serial = try bus.callMethod(bus_name, shell1_path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items);
    return bus.waitReplyTimeout(serial, 2000);
}

/// A variant holding `as`: its first string, if any.
fn readFirstOfStrvVariant(r: *dbus.Reader) !?[]const u8 {
    const sig = try r.readSignature();
    if (!std.mem.eql(u8, sig, "as")) return error.BadSignature;
    const len = try r.readU32();
    if (len == 0) return null;
    return try r.readString();
}

/// GNOME Shell's "path" for the extension (its schemas live there).
fn extensionPath(gpa: std.mem.Allocator, bus: *dbus.Connection, buf: []u8) ?[]const u8 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(uuid) catch return null;
    const serial = bus.callMethod(shell_dest, shell_path, shell_iface, "GetExtensionInfo", "s", m.buf.items) catch return null;
    var reply = bus.waitReplyTimeout(serial, 5000) catch return null;
    defer reply.deinit(gpa);
    var r = reply.reader();
    var it = r.readDictSV() catch return null;
    while (it.next() catch return null) |kv| {
        if (std.mem.eql(u8, kv.key, "path") and kv.value == .string) {
            if (kv.value.string.len > buf.len) return null;
            @memcpy(buf[0..kv.value.string.len], kv.value.string);
            return buf[0..kv.value.string.len];
        }
    }
    return null;
}

/// --schemadir for the extension's settings.
pub fn schemaDir(gpa: std.mem.Allocator, env: Env, bus: ?*dbus.Connection, buf: []u8) ![]const u8 {
    var pbuf: [1024]u8 = undefined;
    const dir = (if (bus) |b| extensionPath(gpa, b, &pbuf) else null) orelse try extensionDir(&pbuf, env.home);
    return std.fmt.bufPrint(buf, "{s}/schemas", .{dir});
}

fn selfExe(buf: []u8) ![]const u8 {
    const rc = std.os.linux.readlinkat(std.os.linux.AT.FDCWD, "/proc/self/exe", buf.ptr, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS or rc >= buf.len) return error.NoExe;
    return buf[0..rc];
}

/// A custom shortcut's command runs this shotlet, with no arguments (or
/// "shot"): "shotlet", "/usr/bin/shotlet", "~/.local/bin/shotlet shot".
pub fn isShotletCommand(command: []const u8, exe: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    var prog = it.next() orelse return false;
    if (prog.len >= 2 and (prog[0] == '\'' or prog[0] == '"') and prog[prog.len - 1] == prog[0]) prog = prog[1 .. prog.len - 1];
    const base = if (std.mem.lastIndexOfScalar(u8, prog, '/')) |i| prog[i + 1 ..] else prog;
    if (!std.mem.eql(u8, base, "shotlet") and !std.mem.eql(u8, prog, exe)) return false;
    if (it.next()) |arg| {
        if (!std.mem.eql(u8, arg, "shot")) return false;
        if (it.next() != null) return false;
    }
    return true;
}

/// A custom shortcut as GNOME Settings keeps it.
const Custom = struct { path: []const u8, name: []const u8, command: []const u8, binding: []const u8 };

fn customPathSchema(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, custom_schema ++ ":{s}", .{path});
}

fn getString(arena: std.mem.Allocator, env: Env, schema: []const u8, key: []const u8) ![]u8 {
    const out = try gsettings.get(arena, env, null, schema, key);
    return gsettings.parseString(arena, out);
}

/// Custom shortcuts whose command runs shotlet.
fn findShotletShortcuts(arena: std.mem.Allocator, env: Env, exe: []const u8) ![]Custom {
    const list = try gsettings.parseStrv(arena, try gsettings.get(arena, env, null, media_keys, "custom-keybindings"));
    var found: std.ArrayList(Custom) = .empty;
    for (list) |path| {
        const schema = customPathSchema(arena, path) catch continue;
        const command = getString(arena, env, schema, "command") catch continue;
        if (!isShotletCommand(command, exe)) continue;
        const c: Custom = .{
            .path = path,
            .name = getString(arena, env, schema, "name") catch "",
            .command = command,
            .binding = getString(arena, env, schema, "binding") catch "",
        };
        // kept one per line, tab separated (backupPath)
        if (std.mem.indexOfAny(u8, c.name, "\t\n") != null or std.mem.indexOfAny(u8, c.command, "\t\n") != null or
            std.mem.indexOfAny(u8, c.binding, "\t\n") != null or std.mem.indexOfAny(u8, c.path, "\t\n") != null) continue;
        try found.append(arena, c);
    }
    return found.toOwnedSlice(arena);
}

/// Where moved shortcuts are remembered, for uninstall.
fn backupPath(buf: []u8, home: []const u8) ![]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try env_mod.configDir(&dir_buf, home);
    return std.fmt.bufPrint(buf, "{s}/gnome-moved-shortcuts", .{dir});
}

/// Move the shortcuts to the extension's: remembered first, then taken
/// off GNOME's custom list.
fn moveShortcuts(arena: std.mem.Allocator, env: Env, schemadir: []const u8, moved: []const Custom) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    var backup: std.ArrayList(u8) = .empty;
    var pbuf: [1100]u8 = undefined;
    const bpath = try backupPath(&pbuf, env.home);
    // earlier moves stay remembered too
    if (sys.readFileAlloc(arena, bpath, 1024 * 1024)) |old| try backup.appendSlice(arena, old) else |_| {}
    for (moved) |c| {
        try backup.print(arena, "{s}\t{s}\t{s}\t{s}\n", .{ c.path, c.name, c.command, c.binding });
        if (c.binding.len == 0) continue;
        for (keys.items) |k| {
            if (std.mem.eql(u8, k, c.binding)) break;
        } else try keys.append(arena, c.binding);
    }
    var dir_buf: [1024]u8 = undefined;
    sys.mkdirAll(try env_mod.configDir(&dir_buf, env.home), 0o700);
    try sys.writeFile(bpath, backup.items);
    try gsettings.set(arena, env, schemadir, ext_schema_id, "capture-shortcut", try gsettings.formatStrv(arena, keys.items));

    const list = try gsettings.parseStrv(arena, try gsettings.get(arena, env, null, media_keys, "custom-keybindings"));
    var keep: std.ArrayList([]const u8) = .empty;
    for (list) |p| {
        for (moved) |c| {
            if (std.mem.eql(u8, c.path, p)) break;
        } else try keep.append(arena, p);
    }
    try gsettings.set(arena, env, null, media_keys, "custom-keybindings", try gsettings.formatStrv(arena, keep.items));
    for (moved) |c| {
        const schema = try customPathSchema(arena, c.path);
        for ([_][]const u8{ "name", "command", "binding" }) |k| gsettings.reset(arena, env, null, schema, k) catch {};
    }
}

/// Put moved shortcuts back on GNOME's custom list (uninstall).
fn restoreShortcuts(arena: std.mem.Allocator, env: Env) !usize {
    var pbuf: [1100]u8 = undefined;
    const bpath = try backupPath(&pbuf, env.home);
    const data = sys.readFileAlloc(arena, bpath, 1024 * 1024) catch return 0;
    const list = try gsettings.parseStrv(arena, try gsettings.get(arena, env, null, media_keys, "custom-keybindings"));
    var paths: std.ArrayList([]const u8) = .empty;
    for (list) |p| try paths.append(arena, p);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const path = f.next() orelse continue;
        const name = f.next() orelse continue;
        const command = f.next() orelse continue;
        const binding = f.next() orelse continue;
        if (path.len == 0 or path[0] != '/') continue;
        const schema = try customPathSchema(arena, path);
        try gsettings.set(arena, env, null, schema, "name", try gsettings.formatString(arena, name));
        try gsettings.set(arena, env, null, schema, "command", try gsettings.formatString(arena, command));
        try gsettings.set(arena, env, null, schema, "binding", try gsettings.formatString(arena, binding));
        for (paths.items) |p| {
            if (std.mem.eql(u8, p, path)) break;
        } else try paths.append(arena, path);
        n += 1;
    }
    try gsettings.set(arena, env, null, media_keys, "custom-keybindings", try gsettings.formatStrv(arena, paths.items));
    sys.unlink(bpath) catch {};
    return n;
}

fn askYes(question: []const u8) bool {
    if (std.c.isatty(0) == 0) return true;
    std.debug.print("{s} [Y/n] ", .{question});
    var buf: [64]u8 = undefined;
    const n = sys.read(0, &buf) catch return false;
    const a = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return a.len == 0 or a[0] == 'y' or a[0] == 'Y';
}

pub const sameAccel = @import("accel.zig").sameAccel;

const shell_keys_schema = "org.gnome.shell.keybindings";
/// GNOME's own screenshot shortcuts (the extension yields to them)
const gnome_shot_keys = [_][]const u8{ "show-screenshot-ui", "screenshot", "screenshot-window", "show-screen-recording-ui" };
/// where GNOME's screenshot UI goes when Shotlet takes its key
const ui_moved_to = "<Shift><Super>s";
/// schemas whose keys hold keyboard shortcuts
const binding_schemas = [_][]const u8{
    "org.gnome.shell.keybindings",                  "org.gnome.desktop.wm.keybindings",
    "org.gnome.mutter.keybindings",                 "org.gnome.mutter.wayland.keybindings",
    "org.gnome.settings-daemon.plugins.media-keys",
};

/// Some GNOME shortcut (or a custom one) uses `accel`.
fn accelInUse(arena: std.mem.Allocator, env: Env, accel: []const u8) bool {
    for (binding_schemas) |schema| {
        const all = gsettings.run(arena, env, null, &.{ "list-recursively", schema }) catch continue;
        var lines = std.mem.splitScalar(u8, all, '\n');
        while (lines.next()) |line| {
            const strs = gsettings.quotedStrings(arena, line) catch continue;
            for (strs) |str| if (sameAccel(str, accel)) return true;
        }
    }
    const list = gsettings.parseStrv(arena, gsettings.get(arena, env, null, media_keys, "custom-keybindings") catch return false) catch return false;
    for (list) |path| {
        const schema = customPathSchema(arena, path) catch continue;
        const b = getString(arena, env, schema, "binding") catch continue;
        if (sameAccel(b, accel)) return true;
    }
    return false;
}

/// Where GNOME's own shortcuts that Shotlet took are remembered.
fn keysBackupPath(buf: []u8, home: []const u8) ![]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try env_mod.configDir(&dir_buf, home);
    return std.fmt.bufPrint(buf, "{s}/gnome-moved-keys", .{dir});
}

/// GNOME's screenshot shortcuts that hold one of `ours`.
const Taken = struct { key: []const u8, old: []const u8, new: [][]const u8 };

fn keysToTake(arena: std.mem.Allocator, env: Env, ours: []const []const u8) ![]Taken {
    var out: std.ArrayList(Taken) = .empty;
    for (gnome_shot_keys) |key| {
        const old = std.mem.trim(u8, gsettings.get(arena, env, null, shell_keys_schema, key) catch continue, " \n");
        const list = gsettings.parseStrv(arena, old) catch continue;
        var keep: std.ArrayList([]const u8) = .empty;
        var hit = false;
        for (list) |a| {
            const clash = for (ours) |o| {
                if (sameAccel(a, o)) break true;
            } else false;
            if (clash) hit = true else try keep.append(arena, a);
        }
        if (!hit) continue;
        // GNOME's screenshot UI keeps a key when a free one is at hand
        if (std.mem.eql(u8, key, "show-screenshot-ui") and keep.items.len == 0 and !accelInUse(arena, env, ui_moved_to))
            try keep.append(arena, ui_moved_to);
        try out.append(arena, .{ .key = key, .old = old, .new = keep.items });
    }
    return out.toOwnedSlice(arena);
}

fn takeKeys(arena: std.mem.Allocator, env: Env, taken: []const Taken) !void {
    var pbuf: [1100]u8 = undefined;
    const bpath = try keysBackupPath(&pbuf, env.home);
    var backup: std.ArrayList(u8) = .empty;
    if (sys.readFileAlloc(arena, bpath, 1024 * 1024)) |old| try backup.appendSlice(arena, old) else |_| {}
    for (taken) |t| try backup.print(arena, "{s}\t{s}\t{s}\n", .{ shell_keys_schema, t.key, t.old });
    var dir_buf: [1024]u8 = undefined;
    sys.mkdirAll(try env_mod.configDir(&dir_buf, env.home), 0o700);
    // remembered before anything changes
    try sys.writeFile(bpath, backup.items);
    for (taken) |t| try gsettings.set(arena, env, null, shell_keys_schema, t.key, try gsettings.formatStrv(arena, t.new));
}

/// Give GNOME's screenshot shortcuts back exactly as they were (a key
/// that was at its default is reset, not set to the same value).
fn restoreKeys(arena: std.mem.Allocator, env: Env) !usize {
    var pbuf: [1100]u8 = undefined;
    const bpath = try keysBackupPath(&pbuf, env.home);
    const data = sys.readFileAlloc(arena, bpath, 1024 * 1024) catch return 0;
    var n: usize = 0;
    // the earliest record of a key is what it was before Shotlet
    var seen: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const schema = f.next() orelse continue;
        const key = f.next() orelse continue;
        const old = f.next() orelse continue;
        if (!std.mem.eql(u8, schema, shell_keys_schema)) continue;
        for (gnome_shot_keys) |k| {
            if (std.mem.eql(u8, k, key)) break;
        } else continue;
        for (seen.items) |k| {
            if (std.mem.eql(u8, k, key)) break;
        } else {
            try seen.append(arena, key);
            try gsettings.reset(arena, env, null, schema, key);
            const now = std.mem.trim(u8, try gsettings.get(arena, env, null, schema, key), " \n");
            if (!std.mem.eql(u8, now, old)) try gsettings.set(arena, env, null, schema, key, old);
            n += 1;
        }
    }
    sys.unlink(bpath) catch {};
    return n;
}

/// A line for the Settings window about the last install.
pub var note_buf: [256]u8 = undefined;
pub var note_len: usize = 0;
pub fn note() ?[]const u8 {
    return if (note_len > 0) note_buf[0..note_len] else null;
}
fn setNote(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&note_buf, fmt, args) catch note_buf[0..0];
    note_len = s.len;
}

const displayAccel = @import("accel.zig").display;

/// The extension is active: point it at this binary and sort out the
/// shortcut (see the top of the file). Messages go to stderr.
fn setUp(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, move: MoveShortcuts) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = std.debug.print;
    var sd_buf: [1100]u8 = undefined;
    const schemadir = schemaDir(gpa, env, bus, &sd_buf) catch return;
    var exe_buf: [1024]u8 = undefined;
    const exe = selfExe(&exe_buf) catch "";
    if (exe.len > 0) {
        const v = gsettings.formatString(arena, exe) catch return;
        gsettings.set(arena, env, schemadir, ext_schema_id, "shotlet-path", v) catch |err| {
            std.log.warn("could not configure the extension ({t}): it may be an older version", .{err});
            return;
        };
    }
    const found = findShotletShortcuts(arena, env, exe) catch &.{};
    if (found.len > 0) {
        var names: std.ArrayList(u8) = .empty;
        for (found, 0..) |c, i| names.print(arena, "{s}\u{201C}{s}\u{201D} ({s})", .{ if (i > 0) ", " else "", c.name, if (c.binding.len > 0) c.binding else "no key" }) catch {};
        out("Your custom shortcut {s} runs shotlet.\n", .{names.items});
        const yes = switch (move) {
            .yes => true,
            .no => false,
            .ask => askYes("Move it to the GNOME integration, so it captures straight away inside GNOME Shell?"),
        };
        if (yes) {
            moveShortcuts(arena, env, schemadir, found) catch |err| {
                out("Could not move it ({t}); it keeps working as it is.\n", .{err});
                return;
            };
            out("Moved: the same key now captures through the GNOME integration, without any prompt.\n" ++
                "`shotlet gnome-integration uninstall` puts the custom shortcut back.\n", .{});
        } else {
            // one key, one binding: leave the key to the custom shortcut
            // (shotlet run from it asks the integration anyway)
            gsettings.set(arena, env, schemadir, ext_schema_id, "capture-shortcut", "@as []") catch {};
            out("Kept it; it captures without prompts too (shotlet asks the integration).\n", .{});
        }
    }
    takeGnomeKey(arena, env, schemadir, move);
    // let the extension pick up its settings
    var tries: usize = 0;
    var info = captureInfo(gpa, bus);
    while (info.shortcut() == null and info.capture and tries < 10) : (tries += 1) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
        info = captureInfo(gpa, bus);
    }
    printShortcut(&info);
}

/// The extension's key is one of GNOME's own screenshot shortcuts (stock
/// GNOME: Print opens its screenshot tool): offer to give it to Shotlet,
/// moving GNOME's screenshot tool to Shift+Super+S when that is free.
/// Only the shortcuts holding that key change; uninstall restores them.
fn takeGnomeKey(arena: std.mem.Allocator, env: Env, schemadir: []const u8, move: MoveShortcuts) void {
    const out = std.debug.print;
    const ours = gsettings.parseStrv(arena, gsettings.get(arena, env, schemadir, ext_schema_id, "capture-shortcut") catch return) catch return;
    if (ours.len == 0) return;
    var cs: std.ArrayList([]const u8) = .empty;
    for (ours) |o| cs.append(arena, o) catch return;
    const taken = keysToTake(arena, env, cs.items) catch return;
    if (taken.len == 0) return;
    var kb: [64]u8 = undefined;
    var mb: [64]u8 = undefined;
    const key = displayAccel(&kb, ours[0]);
    const ui_new = for (taken) |t| {
        if (std.mem.eql(u8, t.key, "show-screenshot-ui")) break if (t.new.len > 0) displayAccel(&mb, t.new[0]) else "";
    } else "";
    const where = if (ui_new.len > 0)
        std.fmt.allocPrint(arena, "GNOME's screenshot tool moves to {s}", .{ui_new}) catch return
    else
        "GNOME's screenshot tool stays in the system menu";
    out("{s} opens GNOME's own screenshot tool.\n", .{key});
    const yes = switch (move) {
        .yes => true,
        .no => false,
        .ask => askYes(std.fmt.allocPrint(arena, "Give {s} to Shotlet? ({s}; uninstall puts it back)", .{ key, where }) catch return),
    };
    if (!yes) {
        out("Kept it: Shotlet's key {s} stays unbound (see `shotlet gnome-integration shortcut`).\n", .{key});
        return;
    }
    takeKeys(arena, env, taken) catch |err| {
        out("Could not change GNOME's shortcuts ({t}).\n", .{err});
        return;
    };
    out("{s} now captures with Shotlet; {s}.\n", .{ key, where });
    setNote("{s} captures with Shotlet; {s}", .{ key, where });
}

fn printShortcut(info: *const CaptureInfo) void {
    const out = std.debug.print;
    if (!info.capture) return;
    if (info.shortcut()) |k| {
        if (info.blocked) {
            out("Shortcut {s}: GNOME's own screenshot tool uses that key, so Shotlet leaves it alone.\n" ++
                "  Pick another: shotlet gnome-integration shortcut '<Shift><Super>s'\n" ++
                "  (or free {s} in GNOME Settings \u{203A} Keyboard \u{203A} View and Customize Shortcuts \u{203A} Screenshots)\n", .{ k, k });
        } else out("Shortcut {s} captures without prompts.\n", .{k});
    } else out("No capture shortcut (shotlet gnome-integration shortcut KEY sets one).\n", .{});
}

pub fn runCli(gpa: std.mem.Allocator, env: Env, sub: []const u8, rest: []const []const u8) !void {
    var bus = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer bus.deinit();
    const out = std.debug.print;
    if (std.mem.eql(u8, sub, "install")) {
        var move: MoveShortcuts = .ask;
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--move-shortcut")) move = .yes;
            if (std.mem.eql(u8, a, "--keep-shortcut")) move = .no;
        }
        switch (install(gpa, env, &bus, move)) {
            .active => out("GNOME integration is active: captures need no permission prompt.\n", .{}),
            .installed_relogin => out("Installed and enabled {s}.\nGNOME Shell loads newly copied extensions at login: log out and back in once,\nthen run `shotlet gnome-integration install` again to set up its shortcut.\n(If user extensions are disabled: gsettings set org.gnome.shell disable-user-extensions false)\n", .{uuid}),
            .failed => {
                out("Could not install the GNOME integration (see the messages above).\n", .{});
                return error.InstallFailed;
            },
        }
    } else if (std.mem.eql(u8, sub, "uninstall")) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        if (restoreKeys(arena_state.allocator(), env)) |n| {
            if (n > 0) out("Gave {d} of GNOME's screenshot shortcut(s) back.\n", .{n});
        } else |err| out("Could not give GNOME's screenshot shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-keys\n", .{err});
        if (restoreShortcuts(arena_state.allocator(), env)) |n| {
            if (n > 0) out("Put {d} custom shortcut(s) running shotlet back.\n", .{n});
        } else |err| out("Could not put the moved shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-shortcuts\n", .{err});
        var sd_buf: [1100]u8 = undefined;
        if (schemaDir(gpa, env, &bus, &sd_buf)) |sd| {
            for ([_][]const u8{ "capture-shortcut", "shotlet-path" }) |k| gsettings.reset(gpa, env, sd, ext_schema_id, k) catch {};
        } else |_| {}
        _ = callBool(gpa, &bus, "DisableExtension", 5000) catch false;
        var buf: [1024]u8 = undefined;
        const dir = try extensionDir(&buf, env.home);
        sys.removeTree(dir);
        out("Removed {s}.\n", .{dir});
    } else if (std.mem.eql(u8, sub, "shortcut")) {
        var sd_buf: [1100]u8 = undefined;
        const sd = try schemaDir(gpa, env, &bus, &sd_buf);
        // a capture mode's own key (app/modes/gnome_keys.zig)
        if (rest.len > 0 and @import("modes/mode.zig").shortcutNamed(rest[0]) != null)
            return @import("modes/gnome_keys.zig").cli(gpa, env, sd, rest);
        if (rest.len > 0) {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const none = rest.len == 1 and std.mem.eql(u8, rest[0], "none");
            for (rest) |a| if (a.len == 0 or a.len > 60 or std.mem.indexOfAny(u8, a, "'\"\\\n") != null) return error.BadShortcut;
            try gsettings.set(arena, env, sd, ext_schema_id, "capture-shortcut", try gsettings.formatStrv(arena, if (none) &.{} else rest));
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        const info = captureInfo(gpa, &bus);
        if (!info.capture) {
            const cur = gsettings.get(gpa, env, sd, ext_schema_id, "capture-shortcut") catch "";
            defer if (cur.len > 0) gpa.free(cur);
            out("capture-shortcut: {s}(the GNOME integration is not active)\n", .{cur});
        } else printShortcut(&info);
        if (rest.len == 0) {
            out("Capture modes (shotlet gnome-integration shortcut MODE KEY):\n", .{});
            try @import("modes/gnome_keys.zig").list(gpa, env, sd, null);
        }
    } else {
        const active = extensionActive(&bus);
        const state = shellState(gpa, &bus);
        out("desktop: {s}\nextension {s}: {s}\n", .{
            if (isGnome()) "GNOME" else "not GNOME",
            uuid,
            if (active) "active" else if (state) |s| switch (s) {
                1 => "enabled",
                2, 6 => "installed, not enabled (shotlet gnome-integration install)",
                3 => "error (see journalctl /usr/bin/gnome-shell)",
                4 => "out of date for this GNOME version",
                99 => "not installed (shotlet gnome-integration install)",
                else => "unknown state",
            } else "GNOME Shell not reachable",
        });
        const info = captureInfo(gpa, &bus);
        out("capture: {s}\n", .{if (info.capture) "through the GNOME integration (no prompts)" else "through the screen-sharing portal"});
        printShortcut(&info);
    }
}

test "custom shortcuts that run shotlet" {
    const exe = "/opt/x/shotlet-bin";
    try std.testing.expect(isShotletCommand("shotlet", exe));
    try std.testing.expect(isShotletCommand("/home/u/.local/bin/shotlet", exe));
    try std.testing.expect(isShotletCommand("  shotlet shot ", exe));
    try std.testing.expect(isShotletCommand("'/usr/bin/shotlet'", exe));
    try std.testing.expect(isShotletCommand("/opt/x/shotlet-bin", exe));
    try std.testing.expect(!isShotletCommand("shotlet history", exe));
    try std.testing.expect(!isShotletCommand("shotlet shot --from x.png", exe));
    try std.testing.expect(!isShotletCommand("sh -c shotlet", exe));
    try std.testing.expect(!isShotletCommand("notshotlet", exe));
    try std.testing.expect(!isShotletCommand("", exe));
}

test "the bundled extension declares the uuid and bus name we look for" {
    try std.testing.expect(std.mem.indexOf(u8, ext_metadata, "\"uuid\": \"" ++ uuid ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_js, bus_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_js, "shotlet:quick") != null);
    // the settings schema the metadata names ships, compiled
    try std.testing.expect(std.mem.indexOf(u8, ext_metadata, "\"settings-schema\": \"" ++ ext_schema_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_schema, "id=\"" ++ ext_schema_id ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_schema_compiled, ext_schema_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_js, "'--from-shell'") != null);
}
