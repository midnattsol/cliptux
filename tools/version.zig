//! The version `shotlet --version` prints, worked out at build time.
//!
//! A release passes its tag (`-Dversion=0.1.7`), which may not be older than
//! build.zig.zon's. Any other build takes it from `git describe`: on a tag,
//! that tag; past it, the next patch as a prerelease naming the distance and
//! the commit (`0.1.7-dev.365+02eccf3`). Without git, build.zig.zon's.

const std = @import("std");
const Version = std.SemanticVersion;

pub const Error = error{ BadDescribe, BadVersion, OlderThanZon };

/// A release's version: `tag` as given (a leading "v" dropped), refused when
/// it is not semver or is older than `zon`.
pub fn release(tag: []const u8, zon: []const u8) Error![]const u8 {
    const v = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    const given = Version.parse(v) catch return error.BadVersion;
    const floor = Version.parse(zon) catch return error.BadVersion;
    if (given.order(floor) == .lt) return error.OlderThanZon;
    return v;
}

const Describe = struct {
    tag: Version,
    distance: u32,
    hash: []const u8,
    dirty: bool,
};

/// Splits `git describe --tags --long --dirty` output:
/// "v0.1.6-365-g02eccf3" or "v0.1.6-365-g02eccf3-dirty".
fn parseDescribe(text: []const u8) Error!Describe {
    var rest = std.mem.trim(u8, text, " \r\n");
    const dirty = std.mem.endsWith(u8, rest, "-dirty");
    if (dirty) rest = rest[0 .. rest.len - "-dirty".len];
    const g = std.mem.lastIndexOf(u8, rest, "-g") orelse return error.BadDescribe;
    const hash = rest[g + 2 ..];
    const d = std.mem.lastIndexOfScalar(u8, rest[0..g], '-') orelse return error.BadDescribe;
    const distance = std.fmt.parseInt(u32, rest[d + 1 .. g], 10) catch return error.BadDescribe;
    var tag = rest[0..d];
    if (std.mem.startsWith(u8, tag, "v")) tag = tag[1..];
    if (hash.len == 0) return error.BadDescribe;
    return .{
        .tag = Version.parse(tag) catch return error.BadDescribe,
        .distance = distance,
        .hash = hash,
        .dirty = dirty,
    };
}

/// The version of a build from a git checkout, given `git describe`'s
/// output and build.zig.zon's version.
pub fn fromDescribe(gpa: std.mem.Allocator, describe: []const u8, zon: []const u8) ![]const u8 {
    const d = try parseDescribe(describe);
    const floor = Version.parse(zon) catch return error.BadVersion;
    const t = d.tag;
    if (d.distance == 0 and !d.dirty)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}", .{ t.major, t.minor, t.patch });
    // the next release: one patch past the tag, or build.zig.zon's when it
    // already names a later one
    var next: Version = .{ .major = t.major, .minor = t.minor, .patch = t.patch + 1 };
    if (floor.order(next) == .gt) next = .{ .major = floor.major, .minor = floor.minor, .patch = floor.patch };
    return std.fmt.allocPrint(gpa, "{d}.{d}.{d}-dev.{d}+{s}{s}", .{
        next.major, next.minor, next.patch, d.distance, d.hash, if (d.dirty) ".dirty" else "",
    });
}

test "a release takes its tag, not older than build.zig.zon's" {
    try std.testing.expectEqualStrings("0.1.7", try release("v0.1.7", "0.1.6"));
    try std.testing.expectEqualStrings("0.2.0", try release("0.2.0", "0.2.0"));
    try std.testing.expectError(error.OlderThanZon, release("v0.1.5", "0.1.6"));
    try std.testing.expectError(error.BadVersion, release("v0.1", "0.1.6"));
}

test "on a tag, the tag" {
    const v = try fromDescribe(std.testing.allocator, "v0.1.6-0-g02eccf3\n", "0.1.6");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("0.1.6", v);
}

test "past a tag, the next patch as a prerelease" {
    const a = std.testing.allocator;
    const v = try fromDescribe(a, "v0.1.6-365-g02eccf3", "0.1.6");
    defer a.free(v);
    try std.testing.expectEqualStrings("0.1.7-dev.365+02eccf3", v);
    const dirty = try fromDescribe(a, "v0.1.6-0-g02eccf3-dirty", "0.1.6");
    defer a.free(dirty);
    try std.testing.expectEqualStrings("0.1.7-dev.0+02eccf3.dirty", dirty);
}

test "build.zig.zon naming a later release wins over the next patch" {
    const v = try fromDescribe(std.testing.allocator, "v0.1.6-3-gabc1234", "0.2.0");
    defer std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("0.2.0-dev.3+abc1234", v);
}

test "describe output that is not a tag's is refused" {
    try std.testing.expectError(error.BadDescribe, parseDescribe("02eccf3"));
    try std.testing.expectError(error.BadDescribe, parseDescribe("main-3-gabc"));
}
