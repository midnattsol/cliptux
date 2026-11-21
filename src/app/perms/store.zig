//! Shotlet's entries in the portal permission store: the screen-cast
//! grants (table `screencast`, one entry per grant, keyed by its restore
//! token) and its "yes" in the Screenshot portal's entry (table
//! `screenshot`, id `screenshot`, shared by every app). Finding and
//! removing them.

const std = @import("std");
const dbus = @import("../../platform/dbus.zig");
const permstore = @import("../../platform/permstore.zig");
const select = @import("select.zig");

pub const Table = enum {
    screencast,
    screenshot,

    /// The table's entries are each one app's grant: they may go whole.
    fn wholeOk(t: Table) bool {
        return t == .screencast;
    }
};

/// One entry with Shotlet's apps in it. Its id is a restore token for
/// screen casts: never printed.
pub const Entry = struct {
    table: Table,
    id: []const u8,
    pick: select.Pick,

    /// Shotlet's id in it is an older version's.
    pub fn older(e: Entry) bool {
        for (e.pick.apps) |a| if (select.origin(a) == .current) return false;
        return true;
    }
};

/// Every entry of Shotlet's in both tables.
pub fn find(arena: std.mem.Allocator, bus: *dbus.Connection) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    try findIn(arena, bus, .screencast, try permstore.list(arena, bus, "screencast"), &out);
    try findIn(arena, bus, .screenshot, &.{"screenshot"}, &out);
    return out.items;
}

fn findIn(arena: std.mem.Allocator, bus: *dbus.Connection, table: Table, ids: []const []const u8, out: *std.ArrayList(Entry)) !void {
    for (ids) |id| {
        const perms = (try permstore.lookup(arena, bus, @tagName(table), id)) orelse continue;
        const p = (try select.pick(arena, perms, table.wholeOk())) orelse continue;
        try out.append(arena, .{ .table = table, .id = id, .pick = p });
    }
}

/// Remove Shotlet's part of `e`: the whole entry when it is all
/// Shotlet's, else each of its apps' permissions.
pub fn remove(bus: *dbus.Connection, e: Entry) !void {
    if (e.pick.whole) return permstore.delete(bus, @tagName(e.table), e.id);
    for (e.pick.apps) |app| try permstore.deletePermission(bus, @tagName(e.table), e.id, app);
}

/// How many of `entries` are in `table`: Shotlet's own, and older
/// versions'.
pub const Count = struct { current: usize = 0, older: usize = 0 };

pub fn count(entries: []const Entry, table: Table) Count {
    var c: Count = .{};
    for (entries) |e| {
        if (e.table != table) continue;
        if (e.older()) c.older += 1 else c.current += 1;
    }
    return c;
}

test "entries are counted per table, older versions apart" {
    const cur: select.Pick = .{ .whole = true, .apps = &.{"io.github.midnattsol.Shotlet"} };
    const old: select.Pick = .{ .whole = true, .apps = &.{"cliptux"} };
    const entries = [_]Entry{
        .{ .table = .screencast, .id = "a", .pick = cur },
        .{ .table = .screencast, .id = "b", .pick = old },
        .{ .table = .screencast, .id = "c", .pick = old },
        .{ .table = .screenshot, .id = "screenshot", .pick = .{ .whole = false, .apps = &.{ "shotlet", "io.github.midnattsol.Shotlet" } } },
    };
    const sc = count(&entries, .screencast);
    try std.testing.expectEqual(@as(usize, 1), sc.current);
    try std.testing.expectEqual(@as(usize, 2), sc.older);
    const ss = count(&entries, .screenshot);
    try std.testing.expectEqual(@as(usize, 1), ss.current);
    try std.testing.expectEqual(@as(usize, 0), ss.older);
}
