//! Checks an option's or argument's value against its kind.

const std = @import("std");
const Kind = @import("spec.zig").Kind;

/// Null when `v` is fine; else what it should look like.
pub fn check(arena: std.mem.Allocator, kind: Kind, choices: []const []const u8, min: i64, max: i64, v: []const u8) !?[]const u8 {
    return switch (kind) {
        .string, .file => null,
        .int => checkInt(arena, min, max, v),
        .choice => checkChoice(arena, choices, v),
        .rect => if (isRect(v)) null else "expected X,Y,W,H (whole numbers, W and H above 0)",
    };
}

fn checkInt(arena: std.mem.Allocator, min: i64, max: i64, v: []const u8) !?[]const u8 {
    const n = std.fmt.parseInt(i64, v, 10) catch null;
    if (n != null and n.? >= min and n.? <= max) return null;
    return try std.fmt.allocPrint(arena, "expected a whole number from {d} to {d}", .{ min, max });
}

fn checkChoice(arena: std.mem.Allocator, choices: []const []const u8, v: []const u8) !?[]const u8 {
    for (choices) |c| if (std.mem.eql(u8, c, v)) return null;
    const list = try std.mem.join(arena, ", ", choices);
    return try std.fmt.allocPrint(arena, "expected one of: {s}", .{list});
}

fn isRect(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, ',');
    var vals: [4]i64 = undefined;
    for (&vals) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return false, 10) catch return false;
    return it.next() == null and vals[2] > 0 and vals[3] > 0;
}

test "values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .int, &.{}, 0, 60, "10"));
    try std.testing.expectEqualStrings("expected a whole number from 0 to 60", (try check(a, .int, &.{}, 0, 60, "61")).?);
    try std.testing.expect((try check(a, .int, &.{}, 0, 60, "x")) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .choice, &.{ "bash", "zsh" }, 0, 0, "zsh"));
    try std.testing.expectEqualStrings("expected one of: bash, zsh", (try check(a, .choice, &.{ "bash", "zsh" }, 0, 0, "csh")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .rect, &.{}, 0, 0, "-10,20,300,200"));
    try std.testing.expect((try check(a, .rect, &.{}, 0, 0, "10,20,0,200")) != null);
    try std.testing.expect((try check(a, .rect, &.{}, 0, 0, "10,20,30")) != null);
}
