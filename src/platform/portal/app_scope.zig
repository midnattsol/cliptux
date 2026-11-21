//! Telling xdg-desktop-portal who we are: the host Registry on 1.19+, a
//! transient `app-<id>-<pid>.scope` on older portals, nothing in Flatpak.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");

pub const app_id = @import("../../app_id.zig").app_id;

/// Connect to the session bus and tell xdg-desktop-portal who we are,
/// before anything on that connection talks to a portal.
pub fn connectApp(alloc: std.mem.Allocator, bus_addr: []const u8) !dbus.Connection {
    var conn = try dbus.Connection.connectSession(alloc, bus_addr);
    registerApp(alloc, &conn);
    return conn;
}

pub const Identity = enum { registry, scope, sandbox, unknown };

/// Give the portal our app id, so stored consent (screen cast restore,
/// screenshot permission) is found again whatever started us: a GNOME
/// custom shortcut, a terminal, the tray daemon. xdg-desktop-portal 1.19+
/// has org.freedesktop.host.portal.Registry.Register for unsandboxed apps;
/// it applies to this bus connection and must come before any other
/// portal call on it. Older portals derive the id from the systemd unit,
/// so without Registry we move into an `app-<id>-<pid>.scope`. Inside
/// Flatpak the sandbox already names us.
pub fn registerApp(alloc: std.mem.Allocator, conn: *dbus.Connection) void {
    const how = registerAppInner(alloc, conn);
    std.log.info("portal identity: {s} ({t})", .{ app_id, how });
}

fn registerAppInner(alloc: std.mem.Allocator, conn: *dbus.Connection) Identity {
    if (sys.fileSize("/.flatpak-info")) |_| return .sandbox else |_| {}
    switch (registerWithRegistry(alloc, conn)) {
        .ok => return .registry,
        .unsupported => {},
        .failed => return .unknown,
    }
    ensureAppScope(alloc, conn);
    return .scope;
}

const RegisterOutcome = enum { ok, unsupported, failed };

fn registerWithRegistry(alloc: std.mem.Allocator, conn: *dbus.Connection) RegisterOutcome {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    m.putString(app_id) catch return .failed;
    const opts = m.beginArray(8) catch return .failed;
    m.endArray(opts);
    const serial = conn.callMethod(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.host.portal.Registry",
        "Register",
        "sa{sv}",
        m.buf.items,
    ) catch return .failed;
    // the first call may start the portal (bus activation)
    var reply = conn.waitReplyOrError(serial, 15_000) catch |err| {
        std.log.warn("portal registration: {t}", .{err});
        return .failed;
    };
    defer reply.deinit(alloc);
    if (reply.type != .@"error") return .ok;
    const name = reply.error_name orelse "";
    if (registryMissing(name)) return .unsupported;
    std.log.warn("portal registration refused: {s}", .{name});
    return .failed;
}

/// Error names meaning "no Registry here" (an older portal, or none).
pub fn registryMissing(name: []const u8) bool {
    const missing = [_][]const u8{
        "org.freedesktop.DBus.Error.UnknownMethod",
        "org.freedesktop.DBus.Error.UnknownInterface",
        "org.freedesktop.DBus.Error.UnknownObject",
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
    };
    for (missing) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

test "a missing Registry falls back; a refusal does not" {
    try std.testing.expect(registryMissing("org.freedesktop.DBus.Error.UnknownMethod"));
    try std.testing.expect(registryMissing("org.freedesktop.DBus.Error.ServiceUnknown"));
    try std.testing.expect(!registryMissing("org.freedesktop.portal.Error.Failed"));
    try std.testing.expect(!registryMissing(""));
}

/// The scope a portal older than 1.19 reads our app id from.
const scope_prefix = "app-" ++ app_id ++ "-";

/// Move this process into its own `app-<app id>-<pid>.scope` transient
/// systemd scope (as `systemd-run --user --scope` does): xdg-desktop-portal
/// before 1.19 derives the caller's app id from the unit name. Fallback
/// for registerApp.
pub fn ensureAppScope(alloc: std.mem.Allocator, conn: *dbus.Connection) void {
    ensureAppScopeInner(alloc, conn) catch |err| {
        std.log.warn("could not move into an app scope: {t}", .{err});
    };
}

fn ensureAppScopeInner(alloc: std.mem.Allocator, conn: *dbus.Connection) !void {
    if (try inAppScope(alloc)) return; // already there
    if (!systemdOnBus(conn)) return;
    const pid: u32 = @intCast(std.os.linux.getpid());
    try startScopeUnit(alloc, conn, pid);
    try waitForScopeMove(alloc);
}

/// Whether /proc/self/cgroup already names our app scope.
fn inAppScope(alloc: std.mem.Allocator) !bool {
    const cg = try sys.readFileAlloc(alloc, "/proc/self/cgroup", 4096);
    defer alloc.free(cg);
    return std.mem.indexOf(u8, cg, scope_prefix) != null;
}

/// Whether systemd's user manager owns its bus name (logs why not).
fn systemdOnBus(conn: *dbus.Connection) bool {
    const systemd_name = "org.freedesktop.systemd1";
    const has_systemd = conn.nameHasOwner(systemd_name) catch |err| {
        std.log.debug("skipping app scope: could not query {s}: {t}", .{ systemd_name, err });
        return false;
    };
    if (!has_systemd) {
        // dbus-daemon may list systemd1 as activatable even when activating it
        // only spawns a child that exits. Do not pay that cost on every shot.
        std.log.debug("skipping app scope: {s} has no bus owner", .{systemd_name});
        return false;
    }
    return true;
}

/// StartTransientUnit for `app-<id>-<pid>.scope` holding `pid`, in
/// app.slice; waits for the reply.
fn startScopeUnit(alloc: std.mem.Allocator, conn: *dbus.Connection, pid: u32) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, scope_prefix ++ "{d}.scope", .{pid});

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(name);
    try m.putString("fail"); // mode
    const props = try m.beginArray(8); // a(sv)
    {
        try m.beginStruct();
        try m.putString("PIDs");
        try m.putSignature("au");
        const pids = try m.beginArray(4);
        try m.putU32(pid);
        m.endArray(pids);

        try m.beginStruct();
        try m.putString("Slice");
        try m.putVariantString("app.slice");
    }
    m.endArray(props);
    const aux = try m.beginArray(8); // a(sa(sv))
    m.endArray(aux);

    const serial = try conn.callMethod(
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
        m.buf.items,
    );
    var reply = try conn.waitReply(serial);
    reply.deinit(alloc);
}

/// The cgroup move is asynchronous; wait (up to ~1 s) for it to land.
fn waitForScopeMove(alloc: std.mem.Allocator) !void {
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        if (try inAppScope(alloc)) return;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.ScopeMoveTimedOut;
}
