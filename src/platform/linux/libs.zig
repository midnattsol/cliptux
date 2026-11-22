//! Optional shared libraries, opened at run time so Shotlet keeps zero
//! build dependencies: `lib<base>.so.<version>`, the first that opens.

const std = @import("std");

pub const Lib = std.DynLib;

/// The first of lib`base`.so.`v` for `v` in `versions` that opens (an
/// empty version is the unversioned name); null when none does.
pub fn open(base: []const u8, versions: []const []const u8) ?Lib {
    var buf: [96]u8 = undefined;
    for (versions) |v| {
        const name = if (v.len == 0)
            std.fmt.bufPrint(&buf, "lib{s}.so", .{base}) catch continue
        else
            std.fmt.bufPrint(&buf, "lib{s}.so.{s}", .{ base, v }) catch continue;
        if (std.DynLib.open(name)) |l| return l else |_| {}
    }
    return null;
}

test "a library that does not exist opens as null" {
    try std.testing.expect(open("shotlet-no-such-library", &.{ "1", "" }) == null);
}
