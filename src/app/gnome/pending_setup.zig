//! The second half of an install that has to wait for the next login: a
//! freshly copied extension only loads then, and pointing it at shotlet
//! and moving the shortcuts needs it running. Install records the
//! person's answer ($XDG_STATE_HOME/shotlet/gnome-setup-pending: "move"
//! or "keep"); the first shotlet the extension starts, or the tray
//! daemon once it is active, runs `gnome-integration install` with that
//! answer, once.

const std = @import("std");
const sys = @import("../../platform/sys.zig");
const env_mod = @import("../env.zig");
const Env = env_mod.Env;

fn markerPath(buf: []u8, home: []const u8) ![]u8 {
    var dbuf: [1024]u8 = undefined;
    const dir = try env_mod.stateDir(&dbuf, home);
    return std.fmt.bufPrint(buf, "{s}/gnome-setup-pending", .{dir});
}

/// Remember to finish the install once the extension runs; `move`: the
/// shortcuts go to it (--move-shortcut), else they stay (--keep-shortcut).
pub fn record(home: []const u8, move: bool) void {
    var dbuf: [1024]u8 = undefined;
    const dir = env_mod.stateDir(&dbuf, home) catch return;
    sys.mkdirAll(dir, 0o700);
    var pbuf: [1100]u8 = undefined;
    const p = markerPath(&pbuf, home) catch return;
    sys.writeFile(p, if (move) "move\n" else "keep\n") catch |err|
        std.log.warn("could not remember to finish the setup: {t}", .{err});
}

/// Nothing is pending any more (install ran by hand, or uninstall).
pub fn clear(home: []const u8) void {
    var pbuf: [1100]u8 = undefined;
    sys.unlink(markerPath(&pbuf, home) catch return) catch {};
}

/// The recorded answer, taken: only the caller that removed the marker
/// gets it, so the setup runs once.
fn take(home: []const u8) ?bool {
    var pbuf: [1100]u8 = undefined;
    const p = markerPath(&pbuf, home) catch return null;
    var buf: [16]u8 = undefined;
    const fd = sys.openRead(p) catch return null;
    const n = sys.read(fd, &buf) catch 0;
    sys.close(fd);
    sys.unlink(p) catch return null;
    return parseAnswer(buf[0..n]);
}

fn parseAnswer(s: []const u8) ?bool {
    const a = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.eql(u8, a, "move")) return true;
    if (std.mem.eql(u8, a, "keep")) return false;
    return null;
}

/// The extension runs: finish a pending install in the background.
pub fn finish(env: Env) void {
    const move = take(env.home) orelse return;
    std.log.info("finishing the GNOME integration setup ({s} the shortcuts)", .{if (move) "moving" else "keeping"});
    @import("../keep.zig").spawnSelf(env, &.{ "gnome-integration", "install", if (move) "--move-shortcut" else "--keep-shortcut" });
}

test "the recorded answer is read back, anything else is ignored" {
    try std.testing.expectEqual(@as(?bool, true), parseAnswer("move\n"));
    try std.testing.expectEqual(@as(?bool, false), parseAnswer("keep"));
    try std.testing.expectEqual(@as(?bool, null), parseAnswer("yes"));
    try std.testing.expectEqual(@as(?bool, null), parseAnswer(""));
}
