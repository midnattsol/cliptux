//! How the last capture got its pixels ($XDG_STATE_HOME/shotlet/
//! capture-path), for Settings and `shotlet permissions`: the GNOME
//! integration, the compositor directly (capture/direct.zig), or a portal.

const std = @import("std");
const sys = @import("../sys.zig");
const env_mod = @import("../../../app/env.zig");

pub const Path = @import("../../api/capture.zig").Path;

fn filePath(buf: []u8, dir_buf: []u8, home: []const u8) ![]u8 {
    const dir = try env_mod.stateDir(dir_buf, home);
    return std.fmt.bufPrint(buf, "{s}/capture-path", .{dir});
}

pub fn remember(home: []const u8, path: Path) void {
    if (last(home) == path) return;
    var dbuf: [1024]u8 = undefined;
    var pbuf: [1100]u8 = undefined;
    const p = filePath(&pbuf, &dbuf, home) catch return;
    sys.mkdirAll(env_mod.stateDir(&dbuf, home) catch return, 0o700);
    sys.writeFile(p, @tagName(path)) catch {};
}

pub fn last(home: []const u8) ?Path {
    var dbuf: [1024]u8 = undefined;
    var pbuf: [1100]u8 = undefined;
    const p = filePath(&pbuf, &dbuf, home) catch return null;
    var buf: [16]u8 = undefined;
    const fd = sys.openRead(p) catch return null;
    defer sys.close(fd);
    const n = sys.read(fd, &buf) catch return null;
    return std.meta.stringToEnum(Path, std.mem.trim(u8, buf[0..n], " \n"));
}
