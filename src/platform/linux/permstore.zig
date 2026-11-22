//! Client for xdg-desktop-portal's permission store
//! (org.freedesktop.impl.portal.PermissionStore on the session bus): the
//! tables where portals keep what the person allowed, per app id. Only
//! the calls `shotlet permissions` needs: List, Lookup, Delete and
//! DeletePermission. Replies are parsed with bounds checks; strings are
//! copied into the caller's arena.

const std = @import("std");
const dbus = @import("dbus.zig");

const dest = "org.freedesktop.impl.portal.PermissionStore";
const path = "/org/freedesktop/impl/portal/PermissionStore";
const iface = "org.freedesktop.impl.portal.PermissionStore";
const timeout_ms = 5000;
/// more entries than any real table holds: a reply past this is refused
const max_items = 4096;

/// One app's permissions in an entry: app id ("" for apps without one)
/// and its permission strings.
pub const AppPerms = struct {
    app: []const u8,
    perms: []const []const u8,
};

/// The ids of `table`'s entries.
pub fn list(arena: std.mem.Allocator, bus: *dbus.Connection, table: []const u8) ![]const []const u8 {
    var reply = (try call(bus, "List", "s", &.{table})) orelse return &.{};
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return parseIds(arena, &r);
}

/// The apps and permissions of entry `id` of `table`; null when there is
/// no such entry. The entry's data (a variant) is not read.
pub fn lookup(arena: std.mem.Allocator, bus: *dbus.Connection, table: []const u8, id: []const u8) !?[]const AppPerms {
    var reply = (try call(bus, "Lookup", "ss", &.{ table, id })) orelse return null;
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return try parseAppPerms(arena, &r);
}

/// Remove entry `id` of `table` with every app's permissions in it.
pub fn delete(bus: *dbus.Connection, table: []const u8, id: []const u8) !void {
    var reply = (try call(bus, "Delete", "ss", &.{ table, id })) orelse return;
    reply.deinit(bus.alloc);
}

/// Remove one app's permissions from entry `id` of `table`.
pub fn deletePermission(bus: *dbus.Connection, table: []const u8, id: []const u8, app: []const u8) !void {
    var reply = (try call(bus, "DeletePermission", "sss", &.{ table, id, app })) orelse return;
    reply.deinit(bus.alloc);
}

/// Call `member` with string arguments. The reply, or null when the
/// store says the table or entry does not exist (NotFound); other error
/// replies are errors.
fn call(bus: *dbus.Connection, member: []const u8, sig: []const u8, args: []const []const u8) !?dbus.Message {
    var m = dbus.Marshal.init(bus.alloc);
    defer m.deinit();
    for (args) |a| try m.putString(a);
    const serial = try bus.callMethod(dest, path, iface, member, sig, m.buf.items);
    var reply = try bus.waitReplyOrError(serial, timeout_ms);
    if (reply.type != .@"error") return reply;
    defer reply.deinit(bus.alloc);
    const name = reply.error_name orelse "";
    if (std.mem.endsWith(u8, name, ".NotFound")) return null;
    std.log.info("permission store {s}: {s}", .{ member, name });
    return if (std.mem.eql(u8, name, "org.freedesktop.DBus.Error.ServiceUnknown")) error.NoPermissionStore else error.DBusError;
}

/// An `as` reply: the strings, copied.
pub fn parseIds(arena: std.mem.Allocator, r: *dbus.Reader) ![]const []const u8 {
    return readStrings(arena, r);
}

/// The `a{sas}` that starts a Lookup reply (its `v` is left unread).
pub fn parseAppPerms(arena: std.mem.Allocator, r: *dbus.Reader) ![]const AppPerms {
    const end = try arrayEnd(r, 8);
    var out: std.ArrayList(AppPerms) = .empty;
    while (r.pos < end) {
        r.pad(8);
        if (r.pos >= end) break;
        if (out.items.len == max_items) return error.TooManyItems;
        const app = try arena.dupe(u8, try r.readString());
        const perms = try readStrings(arena, r);
        if (r.pos > end) return error.BadArrayLength;
        try out.append(arena, .{ .app = app, .perms = perms });
    }
    return out.toOwnedSlice(arena);
}

/// An `as` at the reader: its strings, copied.
fn readStrings(arena: std.mem.Allocator, r: *dbus.Reader) ![]const []const u8 {
    const end = try arrayEnd(r, 4);
    var out: std.ArrayList([]const u8) = .empty;
    while (r.pos < end) {
        if (out.items.len == max_items) return error.TooManyItems;
        try out.append(arena, try arena.dupe(u8, try r.readString()));
        if (r.pos > end) return error.BadArrayLength;
    }
    return out.toOwnedSlice(arena);
}

/// Read an array's length, align to its elements and return where its
/// data ends; an array that runs past the message is an error.
fn arrayEnd(r: *dbus.Reader, elem_align: usize) !usize {
    const len = try r.readU32();
    r.pad(elem_align);
    if (r.pos > r.data.len or len > r.data.len - r.pos) return error.ShortRead;
    return r.pos + len;
}

// --- tests

const testing = std.testing;

/// An a{sas} body as the store sends it, followed by a variant.
fn testLookupBody(m: *dbus.Marshal, entries: []const AppPerms) !void {
    const outer = try m.beginArray(8);
    for (entries) |e| {
        try m.beginStruct();
        try m.putString(e.app);
        const inner = try m.beginArray(4);
        for (e.perms) |p| try m.putString(p);
        m.endArray(inner);
    }
    m.endArray(outer);
    try m.putVariantU32(1);
}

test "a Lookup reply gives each app's permissions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = dbus.Marshal.init(testing.allocator);
    defer m.deinit();
    try testLookupBody(&m, &.{
        .{ .app = "", .perms = &.{"yes"} },
        .{ .app = "io.github.midnattsol.Shotlet", .perms = &.{ "yes", "no" } },
        .{ .app = "other", .perms = &.{} },
    });
    var r: dbus.Reader = .{ .data = m.buf.items, .pos = 0 };
    const got = try parseAppPerms(arena, &r);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("", got[0].app);
    try testing.expectEqualStrings("io.github.midnattsol.Shotlet", got[1].app);
    try testing.expectEqualStrings("no", got[1].perms[1]);
    try testing.expectEqual(@as(usize, 0), got[2].perms.len);
    // the variant after it is still there to read
    try testing.expectEqual(@as(u32, 1), (try r.readVariant()).u32_);
}

test "a List reply gives the ids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var m = dbus.Marshal.init(testing.allocator);
    defer m.deinit();
    const a = try m.beginArray(4);
    try m.putString("bef5da89-6cfc");
    try m.putString("screenshot");
    m.endArray(a);
    var r: dbus.Reader = .{ .data = m.buf.items, .pos = 0 };
    const ids = try parseIds(arena_state.allocator(), &r);
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("screenshot", ids[1]);
}

test "malformed replies are errors, never reads past the message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = dbus.Marshal.init(testing.allocator);
    defer m.deinit();
    try testLookupBody(&m, &.{.{ .app = "io.github.midnattsol.Shotlet", .perms = &.{"yes"} }});
    // every truncation fails cleanly
    var n: usize = 0;
    while (n < m.buf.items.len - 8) : (n += 1) {
        var r: dbus.Reader = .{ .data = m.buf.items[0..n], .pos = 0 };
        if (parseAppPerms(arena, &r)) |_| {
            // only an empty prefix can parse: it says length 0 or fails
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // an outer length past the end
    var bad = try testing.allocator.dupe(u8, m.buf.items);
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0xFFFF_0000, .little);
    var r: dbus.Reader = .{ .data = bad, .pos = 0 };
    try testing.expectError(error.ShortRead, parseAppPerms(arena, &r));
    // an inner array longer than its entry
    var m2 = dbus.Marshal.init(testing.allocator);
    defer m2.deinit();
    try testLookupBody(&m2, &.{.{ .app = "a", .perms = &.{"yes"} }});
    std.mem.writeInt(u32, m2.buf.items[0..4], 16, .little); // entry cut before its perms end
    var r2: dbus.Reader = .{ .data = m2.buf.items, .pos = 0 };
    try testing.expectError(error.BadArrayLength, parseAppPerms(arena, &r2));
}
