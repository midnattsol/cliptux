//! Which permission-store entries are Shotlet's: those of its app id and
//! of the ids older versions had (`shotlet`, `cliptux`). An entry of other
//! apps, or with an empty app id (apps the portal could not identify),
//! is never Shotlet's.

const std = @import("std");
const permstore = @import("../../platform/linux/permstore.zig");
const app_id = @import("../../app_id.zig").app_id;

pub const Origin = enum { current, older };

/// Shotlet's app ids, newest first.
pub const ids = [_][]const u8{ app_id, "shotlet", "cliptux" };

/// Whether `app` is one of Shotlet's ids, and which.
pub fn origin(app: []const u8) ?Origin {
    if (app.len == 0) return null;
    for (ids, 0..) |id, i| {
        if (std.mem.eql(u8, app, id)) return if (i == 0) .current else .older;
    }
    return null;
}

/// What to remove from one entry.
pub const Pick = struct {
    /// every app in it is Shotlet's: delete the entry itself
    whole: bool,
    /// Shotlet's apps in it
    apps: []const []const u8,
};

/// Shotlet's part of an entry; null when it has none. `whole_ok`: the
/// table's entries may go as a whole (each screen-cast grant is its own
/// entry; the screenshot table's one entry is shared by every app).
pub fn pick(arena: std.mem.Allocator, perms: []const permstore.AppPerms, whole_ok: bool) !?Pick {
    var ours: std.ArrayList([]const u8) = .empty;
    var others: usize = 0;
    for (perms) |p| {
        if (origin(p.app) != null) try ours.append(arena, p.app) else others += 1;
    }
    if (ours.items.len == 0) return null;
    return .{ .whole = whole_ok and others == 0, .apps = ours.items };
}

const testing = std.testing;

test "only Shotlet's app ids are Shotlet's" {
    try testing.expectEqual(@as(?Origin, .current), origin("io.github.midnattsol.Shotlet"));
    try testing.expectEqual(@as(?Origin, .older), origin("shotlet"));
    try testing.expectEqual(@as(?Origin, .older), origin("cliptux"));
    try testing.expectEqual(@as(?Origin, null), origin(""));
    try testing.expectEqual(@as(?Origin, null), origin("io.github.midnattsol.Shotlet.Other"));
    try testing.expectEqual(@as(?Origin, null), origin("Shotlet"));
}

test "an entry goes whole only when every app in it is Shotlet's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const yes: []const []const u8 = &.{"yes"};
    // a screen-cast grant of Shotlet's
    const own = (try pick(arena, &.{.{ .app = app_id, .perms = yes }}, true)).?;
    try testing.expect(own.whole);
    try testing.expectEqualStrings(app_id, own.apps[0]);
    // shared with an unidentified app: only Shotlet's permission goes
    const shared = (try pick(arena, &.{ .{ .app = "", .perms = yes }, .{ .app = "cliptux", .perms = yes } }, true)).?;
    try testing.expect(!shared.whole);
    try testing.expectEqual(@as(usize, 1), shared.apps.len);
    try testing.expectEqualStrings("cliptux", shared.apps[0]);
    // other apps' entries and unidentified ones are left alone
    try testing.expect(try pick(arena, &.{.{ .app = "", .perms = yes }}, true) == null);
    try testing.expect(try pick(arena, &.{.{ .app = "org.gnome.Other", .perms = yes }}, true) == null);
    try testing.expect(try pick(arena, &.{}, true) == null);
    // the screenshot table's shared entry never goes whole
    const shot = (try pick(arena, &.{.{ .app = app_id, .perms = yes }}, false)).?;
    try testing.expect(!shot.whole);
}
