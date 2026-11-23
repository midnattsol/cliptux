//! The magnifier's one-time "Hold Ctrl to zoom" hint
//! (ui/editor_ui/loupe_hint.zig) shows once ever: once it has, an empty
//! $XDG_STATE_HOME/shotlet/zoom-hint-shown says so.

const std = @import("std");
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;

fn markerPath(buf: []u8, home: []const u8) ![]u8 {
    var dbuf: [1024]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/zoom-hint-shown", .{try env_mod.stateDir(&dbuf, home)});
}

/// The hint has not been shown yet.
pub fn due(home: []const u8) bool {
    var pbuf: [1100]u8 = undefined;
    const fd = sys.openRead(markerPath(&pbuf, home) catch return false) catch return true;
    sys.close(fd);
    return false;
}

/// The hint was shown: never again.
pub fn remember(home: []const u8) void {
    var dbuf: [1024]u8 = undefined;
    sys.mkdirAll(env_mod.stateDir(&dbuf, home) catch return, 0o700);
    var pbuf: [1100]u8 = undefined;
    sys.writeFile(markerPath(&pbuf, home) catch return, "") catch |err|
        std.log.warn("could not remember the magnifier hint: {t}", .{err});
}

test "the hint is due until it is remembered" {
    const alloc = std.testing.allocator;
    const home = try sys.makeTempDir(alloc, "/tmp", "shotlet-test");
    defer alloc.free(home);
    defer sys.removeTree(home);
    try std.testing.expect(due(home));
    remember(home);
    try std.testing.expect(!due(home));
}
