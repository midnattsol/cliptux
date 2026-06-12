//! Tray daemon: owns the StatusNotifierItem and spawns capture children.
//! Detaches from the terminal (double fork + setsid) unless asked to stay
//! in the foreground; only one instance can own org.midnattsol.cliptux.

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const sys = @import("sys.zig");
const Env = @import("env.zig").Env;

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
    if (!(conn.requestName("org.midnattsol.cliptux") catch true)) {
        std.log.warn("cliptux daemon is already running", .{});
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

    std.log.info("cliptux daemon running (tray icon registered)", .{});
    while (true) {
        var msg = conn.nextMessage() catch |err| switch (err) {
            error.Disconnected => {
                std.log.warn("session bus closed; exiting daemon", .{});
                return;
            },
            else => return err,
        };
        defer msg.deinit(gpa);

        const action = tray.handleMessage(&msg) catch |err| blk: {
            std.log.warn("tray message error: {t}", .{err});
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

/// Fork+exec a cliptux subcommand child so the daemon stays responsive and
/// a crash in the editor can't take down the tray.
fn spawnChild(env: Env, subcommand: [*:0]const u8) void {
    const linux = std.os.linux;
    var stack_buf: [8 * 4096]u8 = undefined; // env strings live on our stack until execve
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const a = fba.allocator();

    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        std.log.err("fork failed", .{});
        return;
    }
    if (pid != 0) return; // parent

    // child: exec ourselves with a minimal environment
    const argv = [_:null]?[*:0]const u8{ "cliptux", subcommand };
    const envp = [_:null]?[*:0]const u8{
        (std.fmt.allocPrintSentinel(a, "DBUS_SESSION_BUS_ADDRESS={s}", .{env.bus_addr}, 0) catch quitChild()).ptr,
        (std.fmt.allocPrintSentinel(a, "XDG_RUNTIME_DIR={s}", .{env.runtime_dir}, 0) catch quitChild()).ptr,
        (std.fmt.allocPrintSentinel(a, "WAYLAND_DISPLAY={s}", .{env.wayland_display}, 0) catch quitChild()).ptr,
        (std.fmt.allocPrintSentinel(a, "HOME={s}", .{env.home}, 0) catch quitChild()).ptr,
    };
    _ = linux.execve("/proc/self/exe", &argv, &envp);
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

    var buf: [512]u8 = undefined;
    const dir1 = std.fmt.bufPrint(&buf, "{s}/.local", .{env.home}) catch return;
    sys.mkdir(dir1);
    const dir2 = std.fmt.bufPrint(&buf, "{s}/.local/state", .{env.home}) catch return;
    sys.mkdir(dir2);
    const dir3 = std.fmt.bufPrint(&buf, "{s}/.local/state/cliptux", .{env.home}) catch return;
    sys.mkdir(dir3);
    const log_path = std.fmt.bufPrint(&buf, "{s}/.local/state/cliptux/daemon.log", .{env.home}) catch return;
    const log_fd = sys.openAppend(log_path) catch return;
    sys.dup2(log_fd, 1);
    sys.dup2(log_fd, 2);
    if (log_fd > 2) sys.close(log_fd);
}
