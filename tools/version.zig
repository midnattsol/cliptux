//! The version `shotlet --version` prints, worked out at build time.
//!
//! A release passes its tag (`-Dversion=0.1.7`), which may not be older than
//! build.zig.zon's. Any other build takes it from `git describe`: on a tag,
//! that tag; past it, the next patch as a prerelease naming the distance and
//! the commit (`0.1.7-dev.365+02eccf3`). Without git, build.zig.zon's.
//! `git describe` runs at make time, on every build, so the version follows
//! commits without re-running build.zig's configure phase.

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
    var rest: []const u8 = std.mem.trim(u8, text, " \r\n");
    const dirty = std.mem.endsWith(u8, rest, "-dirty");
    if (dirty) rest = rest[0 .. rest.len - "-dirty".len];
    const g = std.mem.lastIndexOf(u8, rest, "-g") orelse return error.BadDescribe;
    const hash = rest[g + 2 ..];
    const d = std.mem.lastIndexOfScalar(u8, rest[0..g], '-') orelse return error.BadDescribe;
    const distance = std.fmt.parseInt(u32, rest[d + 1 .. g], 10) catch return error.BadDescribe;
    var tag: []const u8 = rest[0..d];
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
/// output and build.zig.zon's version, written into `buf`.
pub fn fromDescribe(buf: []u8, describe: []const u8, zon: []const u8) ![]const u8 {
    const d = try parseDescribe(describe);
    const floor = Version.parse(zon) catch return error.BadVersion;
    const t = d.tag;
    if (d.distance == 0 and !d.dirty)
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ t.major, t.minor, t.patch });
    // the next release: one patch past the tag, or build.zig.zon's when it
    // already names a later one
    var next: Version = .{ .major = t.major, .minor = t.minor, .patch = t.patch + 1 };
    if (floor.order(next) == .gt) next = .{ .major = floor.major, .minor = floor.minor, .patch = floor.patch };
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}-dev.{d}+{s}{s}", .{
        next.major, next.minor, next.patch, d.distance, d.hash, if (d.dirty) ".dirty" else "",
    });
}

/// The version compiled in: the release's when `-Dversion` gave one, else
/// from `git describe` (run at every build), else build.zig.zon's.
pub fn resolve(comptime release_tag: []const u8, comptime describe: []const u8, comptime zon: []const u8) []const u8 {
    if (release_tag.len > 0) return release_tag;
    comptime {
        @setEvalBranchQuota(100_000);
        var buf: [128]u8 = undefined;
        const s = fromDescribe(&buf, describe, zon) catch return zon;
        const out: [s.len]u8 = s[0..s.len].*;
        return &out;
    }
}

/// What `shotlet --version` prints (the "version" module build.zig makes).
pub const string = resolve(
    @import("build_options").release,
    @embedFile("git_describe"),
    @import("build_options").zon,
);

test "a release takes its tag, not older than build.zig.zon's" {
    try std.testing.expectEqualStrings("0.1.7", try release("v0.1.7", "0.1.6"));
    try std.testing.expectEqualStrings("0.2.0", try release("0.2.0", "0.2.0"));
    try std.testing.expectError(error.OlderThanZon, release("v0.1.5", "0.1.6"));
    try std.testing.expectError(error.BadVersion, release("v0.1", "0.1.6"));
}

test "on a tag, the tag" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1.6", try fromDescribe(&buf, "v0.1.6-0-g02eccf3\n", "0.1.6"));
}

test "past a tag, the next patch as a prerelease" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.1.7-dev.365+02eccf3", try fromDescribe(&buf, "v0.1.6-365-g02eccf3", "0.1.6"));
    try std.testing.expectEqualStrings("0.1.7-dev.0+02eccf3.dirty", try fromDescribe(&buf, "v0.1.6-0-g02eccf3-dirty", "0.1.6"));
}

test "build.zig.zon naming a later release wins over the next patch" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.2.0-dev.3+abc1234", try fromDescribe(&buf, "v0.1.6-3-gabc1234", "0.2.0"));
}

test "at compile time: the release, else git's, else build.zig.zon's" {
    try std.testing.expectEqualStrings("0.1.7", comptime resolve("0.1.7", "v0.1.6-3-gabc1234", "0.1.6"));
    try std.testing.expectEqualStrings("0.1.7-dev.3+abc1234", comptime resolve("", "v0.1.6-3-gabc1234\n", "0.1.6"));
    try std.testing.expectEqualStrings("0.1.6", comptime resolve("", "", "0.1.6"));
}

test "describe output that is not a tag's is refused" {
    try std.testing.expectError(error.BadDescribe, parseDescribe("02eccf3"));
    try std.testing.expectError(error.BadDescribe, parseDescribe("main-3-gabc"));
}
