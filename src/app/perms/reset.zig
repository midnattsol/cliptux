//! Resetting Shotlet's capture permissions (`shotlet permissions reset`
//! and Settings' Reset permissions): forget the ScreenCast restore token
//! (only that config key changes) and remove Shotlet's entries from the
//! portal permission store, so the next portal capture asks again.

const std = @import("std");
const dbus = @import("../../platform/dbus.zig");
const config = @import("../config.zig");
const Env = @import("../env.zig").Env;
const store = @import("store.zig");

pub const Outcome = struct {
    /// a restore token was stored (and is now forgotten)
    token: bool = false,
    /// Shotlet's entries found (and removed, but for `failed`)
    entries: []const store.Entry = &.{},
    /// entries that could not be removed
    failed: usize = 0,
    /// the permission store could not be read (null: it was)
    store_error: ?anyerror = null,

    pub fn nothing(o: Outcome) bool {
        return !o.token and o.entries.len == 0;
    }
};

/// Reset, or with `dry_run` only find what a reset would remove.
pub fn run(arena: std.mem.Allocator, env: Env, bus: ?*dbus.Connection, dry_run: bool) Outcome {
    var o: Outcome = .{};
    o.token = forgetToken(arena, env, dry_run);
    const b = bus orelse {
        o.store_error = error.NoSessionBus;
        return o;
    };
    o.entries = store.find(arena, b) catch |err| {
        o.store_error = err;
        return o;
    };
    if (!dry_run) o.failed = removeAll(b, o.entries);
    return o;
}

/// Whether a token was stored; forgets it unless `dry_run`.
fn forgetToken(arena: std.mem.Allocator, env: Env, dry_run: bool) bool {
    const cfg = config.load(arena, env.home);
    if (cfg.scToken() == null) return false;
    if (!dry_run) config.saveScreencastToken(arena, env.home, "") catch |err| {
        std.log.warn("could not forget the restore token: {t}", .{err});
        return false;
    };
    return true;
}

fn removeAll(bus: *dbus.Connection, entries: []const store.Entry) usize {
    var failed: usize = 0;
    for (entries) |e| store.remove(bus, e) catch |err| {
        std.log.warn("could not remove a {t} permission: {t}", .{ e.table, err });
        failed += 1;
    };
    return failed;
}

/// One short line about a reset, for Settings (beside its button).
pub fn summary(o: Outcome, buf: []u8) []const u8 {
    if (o.store_error != null and !o.token) return "Permission store not reachable";
    if (o.nothing()) return "Nothing was remembered";
    if (o.failed > 0) return std.fmt.bufPrint(buf, "{d} could not be removed", .{o.failed}) catch "";
    const n = o.entries.len;
    const s = if (n == 1) "" else "s";
    if (n == 0) return "Forgot the remembered screens";
    if (o.token) return std.fmt.bufPrint(buf, "Forgot the screens and {d} permission{s}", .{ n, s }) catch "";
    return std.fmt.bufPrint(buf, "Forgot {d} permission{s}", .{ n, s }) catch "";
}

test "the Settings line says what a reset did" {
    var buf: [128]u8 = undefined;
    const e: store.Entry = .{ .table = .screencast, .id = "x", .pick = .{ .whole = true, .apps = &.{"shotlet"} } };
    try std.testing.expectEqualStrings("Nothing was remembered", summary(.{}, &buf));
    try std.testing.expectEqualStrings("Forgot the screens and 1 permission", summary(.{ .token = true, .entries = &.{e} }, &buf));
    try std.testing.expectEqualStrings("Forgot 2 permissions", summary(.{ .entries = &.{ e, e } }, &buf));
    try std.testing.expectEqualStrings("Forgot the remembered screens", summary(.{ .token = true }, &buf));
    try std.testing.expectEqualStrings("Permission store not reachable", summary(.{ .store_error = error.X }, &buf));
}
