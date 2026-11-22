//! Yes/no questions of `gnome-integration install`: asked on a terminal,
//! answered beforehand by its flags (and by the Settings window).

const std = @import("std");
const sys = @import("../../platform/linux/sys.zig");

/// Ask, or the answer given beforehand.
pub const Answer = enum { ask, yes, no };

/// The answer to `question`: `given` unless it is .ask; then the
/// person's on a terminal (Enter: yes), yes without one.
pub fn resolve(given: Answer, question: []const u8) bool {
    return switch (given) {
        .yes => true,
        .no => false,
        .ask => askYes(question),
    };
}

fn askYes(question: []const u8) bool {
    if (std.c.isatty(0) == 0) return true;
    std.debug.print("{s} [Y/n] ", .{question});
    var buf: [64]u8 = undefined;
    const n = sys.read(0, &buf) catch return false;
    const a = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return a.len == 0 or a[0] == 'y' or a[0] == 'Y';
}
