//! Every pin is a process of its own; Close All Pins reaches the others
//! through a directory of sockets in the runtime directory, one per pin
//! (named after its process), each answering "close".

const std = @import("std");
const env_mod = @import("../env.zig");
const sys = @import("../../platform/api.zig").sys;
const Env = env_mod.Env;

/// This pin's socket, listening; `fd` -1 when there is none (the pin
/// still works, Close All Pins just does not reach it).
pub const Listener = struct {
    fd: sys.fd_t = -1,
    path_buf: [600]u8 = undefined,
    path_len: usize = 0,

    pub fn open(env: Env) Listener {
        var l: Listener = .{};
        var dir_buf: [512]u8 = undefined;
        const dir = dirPath(&dir_buf, env) catch return l;
        sys.mkdirMode(dir, 0o700);
        const path = std.fmt.bufPrint(&l.path_buf, "{s}/{d}.sock", .{ dir, sys.processId() }) catch return l;
        l.path_len = path.len;
        // a socket left by an earlier process with our number is stale
        sys.unlink(path) catch {};
        l.fd = sys.listenUnix(path) catch |err| blk: {
            std.log.warn("pin: Close All Pins will not reach this pin: {t}", .{err});
            break :blk -1;
        };
        return l;
    }

    pub fn close(l: *Listener) void {
        if (l.fd < 0) return;
        sys.close(l.fd);
        l.fd = -1;
        sys.unlink(l.path_buf[0..l.path_len]) catch {};
    }

    /// True when another pin asked this one to close.
    pub fn closeAsked(l: *Listener) bool {
        var asked = false;
        while (sys.accept(l.fd) catch null) |fd| {
            defer sys.close(fd);
            var buf: [16]u8 = undefined;
            if (!(sys.waitReadable(fd, sys.monoMs() + 500) catch false)) continue;
            const n = sys.read(fd, &buf) catch continue;
            if (isClose(buf[0..n])) asked = true;
        }
        return asked;
    }
};

fn dirPath(buf: []u8, env: Env) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet-pins-{s}", .{ env.runtime_dir, env.session.tag() });
}

fn isClose(msg: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, msg, "\r\n"), "close");
}

/// Ask every other pin to close; returns how many were asked. Sockets
/// nobody answers on are stale and go.
pub fn closeOthers(gpa: std.mem.Allocator, env: Env, own: *const Listener) usize {
    var dir_buf: [512]u8 = undefined;
    const dir = dirPath(&dir_buf, env) catch return 0;
    const list = sys.listDir(gpa, dir) catch return 0;
    defer sys.freeNames(gpa, list);
    var n: usize = 0;
    for (list) |e| {
        if (e.is_dir or !std.mem.endsWith(u8, e.name, ".sock")) continue;
        var pbuf: [600]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, e.name }) catch continue;
        if (std.mem.eql(u8, path, own.path_buf[0..own.path_len])) continue;
        if (ask(path)) n += 1 else sys.unlink(path) catch {};
    }
    return n;
}

fn ask(path: []const u8) bool {
    const fd = sys.socketUnixStream() catch return false;
    defer sys.close(fd);
    sys.connectUnix(fd, path) catch return false;
    sys.writeAll(fd, "close\n") catch return false;
    return true;
}

test "only a close message closes a pin" {
    try std.testing.expect(isClose("close\n"));
    try std.testing.expect(isClose("close"));
    try std.testing.expect(!isClose("closed\n"));
    try std.testing.expect(!isClose(""));
}
