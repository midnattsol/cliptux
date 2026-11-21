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

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const sys = @import("../platform/sys.zig");
const env_mod = @import("env.zig");
const Env = env_mod.Env;

pub const uuid = "shotlet@midnattsol.github.io";
/// owned by the extension while it is active
pub const bus_name = "dev.shotlet.Shell1";

const ext_js = @embedFile("gnome_ext_js");
const ext_metadata = @embedFile("gnome_ext_metadata");

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
    return dir;
}

pub const InstallResult = enum { active, installed_relogin, failed };

/// Install and enable the extension (see the top of the file).
pub fn install(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection) InstallResult {
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

pub fn runCli(gpa: std.mem.Allocator, env: Env, sub: []const u8) !void {
    var bus = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer bus.deinit();
    const out = std.debug.print;
    if (std.mem.eql(u8, sub, "install")) {
        switch (install(gpa, env, &bus)) {
            .active => out("GNOME integration is active.\n", .{}),
            .installed_relogin => out("Installed and enabled {s}.\nGNOME Shell loads newly copied extensions at login: log out and back in once.\n(If user extensions are disabled: gsettings set org.gnome.shell disable-user-extensions false)\n", .{uuid}),
            .failed => {
                out("Could not install the GNOME integration (see the messages above).\n", .{});
                return error.InstallFailed;
            },
        }
    } else if (std.mem.eql(u8, sub, "uninstall")) {
        _ = callBool(gpa, &bus, "DisableExtension", 5000) catch false;
        var buf: [1024]u8 = undefined;
        const dir = try extensionDir(&buf, env.home);
        sys.removeTree(dir);
        out("Removed {s}.\n", .{dir});
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
    }
}

test "the bundled extension declares the uuid and bus name we look for" {
    try std.testing.expect(std.mem.indexOf(u8, ext_metadata, "\"uuid\": \"" ++ uuid ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_js, bus_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_js, "shotlet:quick") != null);
}
