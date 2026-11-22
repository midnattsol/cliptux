//! "Did you mean ...?": the closest of a few names to a mistyped one.

const std = @import("std");

/// Levenshtein distance (insertions, deletions, substitutions), for
/// names up to 64 bytes; longer ones count as far apart.
pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var row: [65]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diag = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const sub = diag + @intFromBool(ca != cb);
            diag = row[j];
            row[j] = @min(sub, @min(row[j], row[j - 1]) + 1);
        }
    }
    return row[b.len];
}

/// The candidate `word` most likely meant: a close spelling, or one it
/// is the start of; null when none is near.
pub fn closest(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = @max(1, @min(3, word.len / 3));
    for (candidates) |c| {
        const d = distance(word, c);
        if (d <= best_d and (best == null or d < best_d)) {
            best = c;
            best_d = d;
        }
    }
    if (best == null and word.len >= 3) for (candidates) |c| {
        if (std.mem.startsWith(u8, c, word)) return c;
    };
    return best;
}

test "edit distance" {
    try std.testing.expectEqual(@as(usize, 0), distance("record", "record"));
    try std.testing.expectEqual(@as(usize, 1), distance("recrd", "record"));
    try std.testing.expectEqual(@as(usize, 2), distance("pemrissions", "permissions"));
    try std.testing.expectEqual(@as(usize, 3), distance("", "abc"));
}

test "did you mean" {
    const names = [_][]const u8{ "record", "permissions", "pin", "history", "settings" };
    try std.testing.expectEqualStrings("record", closest("recrod", &names).?);
    try std.testing.expectEqualStrings("permissions", closest("permisions", &names).?);
    try std.testing.expectEqualStrings("history", closest("hist", &names).?);
    try std.testing.expectEqual(@as(?[]const u8, null), closest("banana", &names));
}
