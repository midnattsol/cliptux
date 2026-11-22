//! Child processes of the contract: a program found on PATH started with
//! pipes and waited for with a deadline (the ffmpeg program), Shotlet
//! itself started detached, and the devices hardware encoding may use.

const std = @import("std");
const sys = @import("sys.zig");

/// The environment handed to children (envp).
pub const Envp = [*:null]const ?[*:0]const u8;

pub const Pipes = struct {
    stdin: bool = false,
    stdout: bool = false,
    /// a second input, read by the child as fd 3 (`pipe:3`)
    fd3: bool = false,
    /// keep stderr (else discarded)
    stderr: bool = false,
};

pub const Child = struct {
    pid: i32,
    stdin: ?sys.fd_t = null,
    stdout: ?sys.fd_t = null,
    fd3: ?sys.fd_t = null,

    pub fn closeInputs(self: *Child) void {
        _ = self;
    }
    /// Wait up to `timeout_ms` for the exit, killed after that: the exit
    /// status, or null when it was killed or died of a signal.
    pub fn wait(self: *Child, timeout_ms: i64) ?u8 {
        _ = .{ self, timeout_ms };
        return null;
    }
    pub fn kill(self: *Child) void {
        _ = self;
    }
};

/// The environment handed to children: the process's own (`environ`:
/// std.process.Init.minimal.environ).
pub fn processEnv(environ: anytype) Envp {
    _ = environ;
    return &empty;
}
const empty = [_:null]?[*:0]const u8{};

/// The program's absolute path on PATH (into buf), or null.
pub fn which(buf: []u8, name: []const u8) ?[:0]const u8 {
    _ = .{ buf, name };
    return null;
}

/// Start `argv[0]` (an absolute path) with the pipes asked for.
pub fn spawn(argv: []const ?[*:0]const u8, envp: Envp, pipes: Pipes) error{ TooManyArgs, ForkFailed, SyscallFailed }!Child {
    _ = .{ argv, envp, pipes };
    return error.ForkFailed;
}

/// Run to completion, collecting stdout (at most `max` bytes).
pub fn output(gpa: std.mem.Allocator, argv: []const ?[*:0]const u8, envp: Envp, max: usize, timeout_ms: i64) error{ TooManyArgs, ForkFailed, SyscallFailed, TooMuchOutput, OutOfMemory }!struct { status: ?u8, out: []u8 } {
    _ = .{ gpa, argv, envp, max, timeout_ms };
    return error.ForkFailed;
}

/// Run Shotlet itself with `args` (argv[1..]) detached; `keep` stays open
/// in the child.
pub fn spawnSelf(envp: Envp, args: []const [*:0]const u8, keep: ?sys.fd_t) void {
    _ = .{ envp, args, keep };
}

/// Devices hardware H.264 encoding may use (ffmpeg's -vaapi_device), best
/// first.
pub fn hwEncodeDevices(buf: *[2][:0]const u8) []const [:0]const u8 {
    return buf[0..0];
}
