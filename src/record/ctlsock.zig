//! One recording at a time, controlled from outside: the recording
//! listens on $XDG_RUNTIME_DIR/shotlet-record-<display>.sock; `shotlet
//! record` while one runs (the same shortcut again), `shotlet record
//! --stop` and the tray send it a command instead of starting another.
//!
//!     stop | pause | resume | discard | status    ->  "ok ..." or "err"

const std = @import("std");
const sys = @import("../platform/sys.zig");

pub const Command = enum { stop, pause, resume_, discard, status };

pub fn parse(line: []const u8) ?Command {
    const l = std.mem.trim(u8, line, " \r\n");
    if (std.mem.eql(u8, l, "resume")) return .resume_;
    const c = std.meta.stringToEnum(Command, l) orelse return null;
    return if (c == .resume_) null else c;
}

pub fn path(buf: []u8, runtime_dir: []const u8, display: []const u8) ![]u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, display, '/')) |i| display[i + 1 ..] else display;
    return std.fmt.bufPrint(buf, "{s}/shotlet-record-{s}.sock", .{ runtime_dir, base });
}

/// Send a command to the running recording; its answer, or null when
/// none is running.
pub fn send(runtime_dir: []const u8, display: []const u8, cmd: []const u8, ans: []u8) ?[]const u8 {
    var pbuf: [512]u8 = undefined;
    const p = path(&pbuf, runtime_dir, display) catch return null;
    const fd = sys.socketUnixStream() catch return null;
    defer sys.close(fd);
    sys.connectUnix(fd, p) catch return null;
    var lbuf: [64]u8 = undefined;
    sys.writeAll(fd, std.fmt.bufPrint(&lbuf, "{s}\n", .{cmd}) catch return null) catch return null;
    if (!(sys.waitReadable(fd, sys.monoMs() + 3000) catch false)) return null;
    const n = sys.read(fd, ans) catch return null;
    return std.mem.trimEnd(u8, ans[0..n], "\n");
}

pub const Server = struct {
    fd: sys.fd_t,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    /// Listen; error.AddressInUse when another recording answers there.
    pub fn listen(runtime_dir: []const u8, display: []const u8) !Server {
        var s: Server = .{ .fd = -1 };
        const p = try path(&s.path_buf, runtime_dir, display);
        s.path_len = p.len;
        s.fd = sys.listenUnix(p) catch |err| blk: {
            if (err != error.AddressInUse) return err;
            var ans: [64]u8 = undefined;
            if (send(runtime_dir, display, "status", &ans) != null) return error.AddressInUse;
            // a stale socket of a recording that crashed
            sys.unlink(p) catch {};
            break :blk try sys.listenUnix(p);
        };
        return s;
    }

    pub fn close(self: *Server) void {
        sys.close(self.fd);
        sys.unlink(self.path_buf[0..self.path_len]) catch {};
    }

    /// A waiting command, if any; `reply` answers it.
    pub fn poll(self: *Server, conn_out: *sys.fd_t) ?Command {
        const c = (sys.accept(self.fd) catch return null) orelse return null;
        var buf: [64]u8 = undefined;
        if (!(sys.waitReadable(c, sys.monoMs() + 500) catch false)) {
            sys.close(c);
            return null;
        }
        const n = sys.read(c, &buf) catch 0;
        const cmd = parse(buf[0..n]) orelse {
            sys.writeAll(c, "err\n") catch {};
            sys.close(c);
            return null;
        };
        conn_out.* = c;
        return cmd;
    }

    pub fn reply(conn: sys.fd_t, text: []const u8) void {
        sys.writeAll(conn, text) catch {};
        sys.writeAll(conn, "\n") catch {};
        sys.close(conn);
    }
};

test "commands parse" {
    try std.testing.expectEqual(Command.stop, parse("stop\n").?);
    try std.testing.expectEqual(Command.resume_, parse("resume").?);
    try std.testing.expect(parse("resume_") == null);
    try std.testing.expect(parse("rm -rf") == null);
}
