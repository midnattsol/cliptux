//! Tray daemon: owns the StatusNotifierItem and spawns capture children.
//! Detaches from the terminal (double fork + setsid) unless asked to stay
//! in the foreground; only one instance can own org.midnattsol.shotlet.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const sys = @import("../platform/sys.zig");
const env_mod = @import("env.zig");
const Env = env_mod.Env;

pub fn run(gpa: std.mem.Allocator, env: Env, foreground: bool) !void {
    const tray_mod = @import("tray.zig");
    const linux = std.os.linux;

    if (!foreground) {
        // first fork: parent returns control to the shell immediately
        if ((sys.fork() catch 0) != 0) sys.exitProcess(0);
        sys.setsid(); // drop the controlling terminal
        // second fork: can never reacquire a tty
        if ((sys.fork() catch 0) != 0) sys.exitProcess(0);
        sys.chdirRoot();
        redirectStdio(env);
    }

    // auto-reap capture children
    var sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.CHLD, &sa, null);

    var conn = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer conn.deinit();

    // single instance: lose the name race -> another daemon already runs
    if (!(conn.requestName("org.midnattsol.shotlet") catch true)) {
        std.log.warn("shotlet daemon is already running", .{});
        return;
    }
    portal.ensureAppScope(gpa, &conn);

    const icon22 = try tray_mod.drawIcon(gpa, 22);
    defer gpa.free(icon22);
    const icon44 = try tray_mod.drawIcon(gpa, 44);
    defer gpa.free(icon44);
    const icons = [_]tray_mod.Tray.IconPixmap{
        .{ .width = 22, .height = 22, .argb = icon22 },
        .{ .width = 44, .height = 44, .argb = icon44 },
    };
    var tray = try tray_mod.Tray.init(gpa, &conn, &icons);

    std.log.info("shotlet daemon running (tray icon registered)", .{});
    var log = LogFile.init(env, foreground);
    while (true) {
        // wake up now and then to keep the log bounded: children write to
        // it through the stderr they inherit
        const maybe = conn.nextMessageDeadline(sys.monoMs() + 60_000) catch |err| {
            if (err == error.Disconnected) {
                std.log.warn("session bus closed; exiting daemon", .{});
                return;
            }
            if (dbus.isFatal(err)) return err;
            // one malformed message must never take the tray down
            std.log.warn("dropped malformed bus message: {t}", .{err});
            continue;
        };
        log.check();
        var msg = maybe orelse continue;
        defer msg.deinit(gpa);

        const action = tray.handleMessage(&msg) catch |err| blk: {
            std.log.warn("tray message error: {t}", .{err});
            if (msg.type == .method_call) {
                conn.replyError(&msg, "org.freedesktop.DBus.Error.InvalidArgs", "malformed arguments") catch {};
            }
            break :blk .none;
        };
        switch (action) {
            .capture => spawnChild(env, "shot"),
            .settings => spawnChild(env, "settings"),
            .quit => return,
            .none => {},
        }
    }
}

/// Fork+exec a shotlet subcommand child so the daemon stays responsive and
/// a crash in the editor can't take down the tray.
fn spawnChild(env: Env, subcommand: [*:0]const u8) void {
    const linux = std.os.linux;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        std.log.err("fork failed", .{});
        return;
    }
    if (pid != 0) return; // parent

    // child: exec ourselves with the daemon's own environment, so locale,
    // XDG dirs, TZ, PATH and the rest reach the editor unchanged
    const argv = [_:null]?[*:0]const u8{ "shotlet", subcommand };
    _ = linux.execve("/proc/self/exe", &argv, env.envp);
    quitChild();
}

fn quitChild() noreturn {
    std.os.linux.exit(127);
}

/// stdin -> /dev/null; stdout/stderr -> append-only daemon log.
fn redirectStdio(env: Env) void {
    if (sys.openRw("/dev/null")) |null_fd| {
        sys.dup2(null_fd, 0);
        if (null_fd > 2) sys.close(null_fd);
    } else |_| {}
    var log = LogFile.init(env, false);
    log.rotateIfBig();
    log.reopen();
}

/// The daemon log in $XDG_STATE_HOME/shotlet (0600). Rotated past
/// `max_bytes` into a single .old file, checked at start and while running,
/// so it stays around 2 * max_bytes even with chatty children.
const LogFile = struct {
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,
    enabled: bool = false,
    last_check_ms: i64 = 0,

    const max_bytes = 1024 * 1024;

    fn init(env: Env, foreground: bool) LogFile {
        var self = LogFile{};
        if (foreground) return self; // logging to the terminal
        var dir_buf: [1024]u8 = undefined;
        const dir = env_mod.stateDir(&dir_buf, env.home) catch return self;
        sys.mkdirAll(dir, 0o700);
        const p = std.fmt.bufPrint(&self.path_buf, "{s}/daemon.log", .{dir}) catch return self;
        self.path_len = p.len;
        self.enabled = true;
        return self;
    }

    fn path(self: *const LogFile) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Point stdout/stderr at a fresh handle on the log file.
    fn reopen(self: *LogFile) void {
        if (!self.enabled) return;
        const log_fd = sys.openAppend(self.path()) catch return;
        sys.fchmod(log_fd, 0o600); // older versions created it 0644
        sys.dup2(log_fd, 1);
        sys.dup2(log_fd, 2);
        if (log_fd > 2) sys.close(log_fd);
    }

    fn rotateIfBig(self: *LogFile) void {
        if (!self.enabled) return;
        if ((sys.fileSize(self.path()) catch 0) <= max_bytes) return;
        var old_buf: [1100]u8 = undefined;
        const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{self.path()}) catch return;
        sys.rename(self.path(), old_path) catch {};
    }

    /// Called from the main loop; cheap, rate-limited to every few seconds.
    fn check(self: *LogFile) void {
        if (!self.enabled) return;
        const now = sys.monoMs();
        if (now - self.last_check_ms < 5_000) return;
        self.last_check_ms = now;
        const size = sys.fdSize(2) catch return;
        if (size <= max_bytes) return;
        self.rotateIfBig();
        self.reopen();
        // children started before the rotation keep appending to .old;
        // cut it if one of them is very chatty
        var old_buf: [1100]u8 = undefined;
        const old_path = std.fmt.bufPrint(&old_buf, "{s}.old", .{self.path()}) catch return;
        if ((sys.fileSize(old_path) catch 0) > 4 * max_bytes) {
            if (sys.openRw(old_path)) |fd| {
                sys.ftruncateFd(fd, 0);
                sys.close(fd);
            } else |_| {}
        }
        std.log.info("daemon log rotated", .{});
    }
};
