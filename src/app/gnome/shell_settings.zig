//! GNOME Shell's own extension settings (org.gnome.shell): whether the
//! extension is in `enabled-extensions` (and not in
//! `disabled-extensions`), and `disable-user-extensions`. A running shell
//! only learns new extensions at login and EnableExtension does nothing
//! for one it does not know, so install puts the uuid in the list itself.

const std = @import("std");
const gsettings = @import("../gsettings.zig");
const Env = @import("../env.zig").Env;
const uuid = @import("extension.zig").uuid;

const schema = "org.gnome.shell";

/// `key` (a string list of org.gnome.shell) as it is now.
fn readList(arena: std.mem.Allocator, env: Env, key: []const u8) ![]const []const u8 {
    const items = try gsettings.parseStrv(arena, try gsettings.get(arena, env, null, schema, key));
    return items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, item)) return true;
    return false;
}

/// `list` with `item` at the end; null when it is there already.
pub fn withItem(arena: std.mem.Allocator, list: []const []const u8, item: []const u8) !?[]const []const u8 {
    if (contains(list, item)) return null;
    const out = try arena.alloc([]const u8, list.len + 1);
    @memcpy(out[0..list.len], list);
    out[list.len] = item;
    return out;
}

/// `list` without any `item`; null when it was not there.
pub fn withoutItem(arena: std.mem.Allocator, list: []const []const u8, item: []const u8) !?[]const []const u8 {
    if (!contains(list, item)) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |s| if (!std.mem.eql(u8, s, item)) try out.append(arena, s);
    return out.items;
}

/// The extension is in `enabled-extensions` and not in
/// `disabled-extensions` (GNOME 40+; older ones lack the key).
pub fn enabled(arena: std.mem.Allocator, env: Env) bool {
    const on = readList(arena, env, "enabled-extensions") catch return false;
    const off = readList(arena, env, "disabled-extensions") catch &.{};
    return contains(on, uuid) and !contains(off, uuid);
}

/// Put the extension in `enabled-extensions` (once) and take it out of
/// `disabled-extensions`; true when something changed.
pub fn enable(arena: std.mem.Allocator, env: Env) !bool {
    var changed = false;
    const on = try readList(arena, env, "enabled-extensions");
    if (try withItem(arena, on, uuid)) |l| {
        try gsettings.set(arena, env, null, schema, "enabled-extensions", try gsettings.formatStrv(arena, l));
        changed = true;
    }
    const off = readList(arena, env, "disabled-extensions") catch return changed;
    if (try withoutItem(arena, off, uuid)) |l| {
        try gsettings.set(arena, env, null, schema, "disabled-extensions", try gsettings.formatStrv(arena, l));
        changed = true;
    }
    return changed;
}

/// GNOME's switch that turns every user extension off is on.
pub fn userExtensionsOff(arena: std.mem.Allocator, env: Env) bool {
    const v = gsettings.get(arena, env, null, schema, "disable-user-extensions") catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, v, " \t\r\n"), "true");
}

pub fn turnUserExtensionsOn(arena: std.mem.Allocator, env: Env) !void {
    try gsettings.set(arena, env, null, schema, "disable-user-extensions", "false");
}

test "the extension list gains the uuid once and loses it entirely" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = (try withItem(arena, &.{"other@x"}, uuid)).?;
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings(uuid, a[1]);
    try std.testing.expect(try withItem(arena, a, uuid) == null);
    try std.testing.expectEqual(@as(usize, 1), (try withItem(arena, &.{}, uuid)).?.len);
    const b = (try withoutItem(arena, &.{ uuid, "other@x", uuid }, uuid)).?;
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqualStrings("other@x", b[0]);
    try std.testing.expect(try withoutItem(arena, &.{"other@x"}, uuid) == null);
}
