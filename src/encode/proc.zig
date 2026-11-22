//! Child processes with pipes (the ffmpeg program): stdin, stdout and an
//! extra input on fd 3, found on PATH, waited for with a deadline.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;
const linux = std.os.linux;

pub const Envp = [*:null]const ?[*:0]const u8;

pub const Pipes = struct {
    stdin: bool = false,
    stdout: bool = false,
    /// a second input, read by the child as fd 3 (`pipe:3`)
    fd3: bool = false,
    /// keep stderr (else /dev/null)
    stderr: bool = false,
};

pub const Child = struct {
    pid: i32,
    stdin: ?sys.fd_t = null,
    stdout: ?sys.fd_t = null,
    fd3: ?sys.fd_t = null,

    pub fn closeInputs(self: *Child) void {
        if (self.stdin) |f| sys.close(f);
        if (self.fd3) |f| sys.close(f);
        self.stdin = null;
        self.fd3 = null;
    }

    /// Wait up to `timeout_ms` for the exit; killed after that. The exit
    /// status, or null when it was killed or died of a signal.
    pub fn wait(self: *Child, timeout_ms: i64) ?u8 {
        self.closeInputs();
        if (self.stdout) |f| sys.close(f);
        self.stdout = null;
        const deadline = sys.monoMs() + timeout_ms;
        var status: i32 = 0;
        while (true) {
            const rc = linux.wait4(self.pid, &status, linux.W.NOHANG, null);
            if (rc == self.pid) break;
            if (linux.errno(rc) != .SUCCESS) return null;
            if (sys.monoMs() > deadline) {
                _ = linux.kill(self.pid, linux.SIG.KILL);
                _ = linux.wait4(self.pid, &status, 0, null);
                return null;
            }
            var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
        const st: u32 = @bitCast(status);
        if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
        return null;
    }

    pub fn kill(self: *Child) void {
        _ = linux.kill(self.pid, linux.SIG.KILL);
        _ = self.wait(2000);
    }
};

/// The program's absolute path on PATH (into buf), or null.
pub fn which(buf: []u8, name: []const u8) ?[:0]const u8 {
    const path = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue;
        const full = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (linux.access(full.ptr, linux.X_OK) == 0) return full;
    }
    return null;
}

/// Start `argv[0]` (an absolute path) with the pipes asked for.
pub fn spawn(argv: []const ?[*:0]const u8, envp: Envp, pipes: Pipes) !Child {
    var argz: [80:null]?[*:0]const u8 = @splat(null);
    if (argv.len >= argz.len) return error.TooManyArgs;
    for (argv, 0..) |a, i| argz[i] = a;
    var in_p: ?[2]sys.fd_t = if (pipes.stdin) try sys.pipe() else null;
    errdefer if (in_p) |p| closeBoth(p);
    var out_p: ?[2]sys.fd_t = if (pipes.stdout) try sys.pipe() else null;
    errdefer if (out_p) |p| closeBoth(p);
    var f3_p: ?[2]sys.fd_t = if (pipes.fd3) try sys.pipe() else null;
    errdefer if (f3_p) |p| closeBoth(p);

    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) childSetup(&argz, envp, pipes, in_p, out_p, f3_p);

    var c: Child = .{ .pid = @intCast(pid) };
    if (in_p) |p| {
        sys.close(p[0]);
        c.stdin = p[1];
        in_p = null;
    }
    if (out_p) |p| {
        sys.close(p[1]);
        c.stdout = p[0];
        out_p = null;
    }
    if (f3_p) |p| {
        sys.close(p[0]);
        c.fd3 = p[1];
        f3_p = null;
    }
    return c;
}

fn closeBoth(p: [2]sys.fd_t) void {
    sys.close(p[0]);
    sys.close(p[1]);
}

fn childSetup(argz: [*:null]const ?[*:0]const u8, envp: Envp, pipes: Pipes, in_p: ?[2]sys.fd_t, out_p: ?[2]sys.fd_t, f3_p: ?[2]sys.fd_t) noreturn {
    const devnull: i32 = @intCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
    // fd 3 first: the pipes may sit on fds 0..3 themselves
    const f3: i32 = if (f3_p) |p| @intCast(linux.fcntl(p[0], linux.F.DUPFD, 10)) else -1;
    const in: i32 = if (in_p) |p| p[0] else devnull;
    const out: i32 = if (out_p) |p| p[1] else devnull;
    const in_d: i32 = @intCast(linux.fcntl(in, linux.F.DUPFD, 10));
    const out_d: i32 = @intCast(linux.fcntl(out, linux.F.DUPFD, 10));
    _ = linux.dup2(in_d, 0);
    _ = linux.dup2(out_d, 1);
    if (!pipes.stderr) _ = linux.dup2(devnull, 2);
    if (f3 >= 0) _ = linux.dup2(f3, 3);
    // nothing else of ours leaks into the child
    var fd: i32 = 4;
    while (fd < 1024) : (fd += 1) _ = linux.close(fd);
    _ = linux.execve(argz[0].?, argz, envp);
    linux.exit(127);
}

/// Run to completion, collecting stdout (at most `max` bytes).
pub fn output(gpa: std.mem.Allocator, argv: []const ?[*:0]const u8, envp: Envp, max: usize, timeout_ms: i64) !struct { status: ?u8, out: []u8 } {
    var c = try spawn(argv, envp, .{ .stdout = true });
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const deadline = sys.monoMs() + timeout_ms;
    var chunk: [65536]u8 = undefined;
    while (sys.monoMs() < deadline) {
        if (!(sys.waitReadable(c.stdout.?, deadline) catch false)) break;
        const n = sys.read(c.stdout.?, &chunk) catch break;
        if (n == 0) break;
        if (buf.items.len + n > max) return error.TooMuchOutput;
        try buf.appendSlice(gpa, chunk[0..n]);
    }
    const st = c.wait(@max(0, deadline - sys.monoMs()));
    return .{ .status = st, .out = try buf.toOwnedSlice(gpa) };
}

test "spawn runs a program with pipes and reports its status" {
    var buf: [256]u8 = undefined;
    const sh = which(&buf, "sh") orelse return error.SkipZigTest;
    const envp: Envp = @ptrCast(std.c.environ);
    const gpa = std.testing.allocator;
    const r = try output(gpa, &.{ sh.ptr, "-c", "echo hi; exit 3" }, envp, 1024, 5000);
    defer gpa.free(r.out);
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(@as(?u8, 3), r.status);

    // fd 3 reaches the child
    var c = try spawn(&.{ sh.ptr, "-c", "cat <&3 >/dev/null; cat >/dev/null" }, envp, .{ .stdin = true, .fd3 = true });
    try sys.writeAll(c.fd3.?, "abc");
    try std.testing.expectEqual(@as(?u8, 0), c.wait(5000));
}
