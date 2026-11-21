//! Test helpers shared by the bidi submodules.

const std = @import("std");

/// UTF-32 codepoints of a comptime UTF-8 string.
pub fn u32s(comptime s: []const u8) [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 {
    @setEvalBranchQuota(100_000);
    var out: [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 = undefined;
    var it = std.unicode.Utf8View.initComptime(s).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) out[i] = cp;
    return out;
}
