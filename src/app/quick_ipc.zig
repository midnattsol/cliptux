//! Quick access runs once: a later capture hands its entry to the
//! running thumbnail process over a unix socket in the runtime directory.

const std = @import("std");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const sys = @import("../platform/api.zig").sys;
const Env = env_mod.Env;

pub fn socketPath(buf: []u8, env: Env) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet-quick-{s}.sock", .{ env.runtime_dir, env.session.tag() });
}

/// Hand an entry to a running quick-access process; false when none
/// answered.
pub fn handOff(env: Env, root: []const u8, id: []const u8) bool {
    var pbuf: [512]u8 = undefined;
    const path = socketPath(&pbuf, env) catch return false;
    const fd = sys.socketUnixStream() catch return false;
    defer sys.close(fd);
    sys.connectUnix(fd, path) catch return false;
    var lbuf: [1200]u8 = undefined;
    const line = std.fmt.bufPrint(&lbuf, "add {s}\t{s}\n", .{ root, id }) catch return false;
    sys.writeAll(fd, line) catch return false;
    var ans: [8]u8 = undefined;
    if (!(sys.waitReadable(fd, sys.monoMs() + 2000) catch false)) return false;
    const n = sys.read(fd, &ans) catch return false;
    return n >= 2 and std.mem.eql(u8, ans[0..2], "ok");
}

/// Parse "add ROOT\tID\n".
pub fn parseAdd(line: []const u8) ?struct { root: []const u8, id: []const u8 } {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, l, "add ")) return null;
    const rest = l[4..];
    const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const root = rest[0..tab];
    const id = rest[tab + 1 ..];
    if (root.len == 0 or root[0] != '/' or !history.Id.valid(id)) return null;
    return .{ .root = root, .id = id };
}

test "hand-off lines are checked" {
    const a = parseAdd("add /home/u/.local/state/shotlet/history\t1763740953123-0a1b2c3d\n").?;
    try std.testing.expectEqualStrings("/home/u/.local/state/shotlet/history", a.root);
    try std.testing.expectEqualStrings("1763740953123-0a1b2c3d", a.id);
    try std.testing.expect(parseAdd("add relative\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r\t../../x") == null);
    try std.testing.expect(parseAdd("del /r\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r 1763740953123-0a1b2c3d") == null);
}
