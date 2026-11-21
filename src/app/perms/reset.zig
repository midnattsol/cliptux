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

/// One short line about a reset, for Settings.
pub fn summary(o: Outcome, buf: []u8) []const u8 {
    if (o.store_error != null and !o.token) return "Could not reach the portal permission store";
    if (o.nothing()) return "Nothing to reset: the next capture asks as it is";
    if (o.failed > 0) return std.fmt.bufPrint(buf, "Could not remove {d} permission(s); see shotlet permissions", .{o.failed}) catch "";
    const n = o.entries.len;
    const tok = if (o.token) "the remembered screens" else "";
    const join = if (o.token and n > 0) " and " else "";
    if (n == 0) return std.fmt.bufPrint(buf, "Forgot {s}; the next capture asks again", .{tok}) catch "";
    return std.fmt.bufPrint(buf, "Forgot {s}{s}{d} permission{s}; the next capture asks again", .{ tok, join, n, if (n == 1) "" else "s" }) catch "";
}

test "the Settings line says what a reset did" {
    var buf: [128]u8 = undefined;
    const e: store.Entry = .{ .table = .screencast, .id = "x", .pick = .{ .whole = true, .apps = &.{"shotlet"} } };
    try std.testing.expectEqualStrings("Nothing to reset: the next capture asks as it is", summary(.{}, &buf));
    try std.testing.expectEqualStrings("Forgot the remembered screens and 1 permission; the next capture asks again", summary(.{ .token = true, .entries = &.{e} }, &buf));
    try std.testing.expectEqualStrings("Forgot 2 permissions; the next capture asks again", summary(.{ .entries = &.{ e, e } }, &buf));
    try std.testing.expectEqualStrings("Forgot the remembered screens; the next capture asks again", summary(.{ .token = true }, &buf));
    try std.testing.expectEqualStrings("Could not reach the portal permission store", summary(.{ .store_error = error.X }, &buf));
}
