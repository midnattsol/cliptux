//! `shotlet record`: pick an area (or the whole screen) and record it.
//!
//!     shotlet record                  pick an area, then record
//!     shotlet record --full           the whole monitor under the pointer
//!     shotlet record --region X,Y,W,H an area (logical pixels), no picker
//!     shotlet record --stop | --pause | --resume | --discard
//!                                     control the recording under way
//!     options: --gif | --mp4, --fps N, --mic, --system-audio, --clicks,
//!              --keys, --no-countdown, --seconds N (stop after),
//!              --out FILE, --no-control (no floating control)
//!
//! While a recording runs, `shotlet record` again stops it (so one
//! shortcut starts and stops).

const std = @import("std");
const env_mod = @import("../app/env.zig");
const settings_mod = @import("settings.zig");
const region = @import("region.zig");
const ctlsock = @import("ctlsock.zig");
const run_mod = @import("run.zig");
const Env = env_mod.Env;

pub const Args = struct {
    area: ?region.Rect = null,
    full: bool = false,
    seconds: ?u32 = null,
    out: ?[]const u8 = null,
    control: bool = true,
    /// a command for the running recording
    command: ?[]const u8 = null,
};

/// Parse the options into `a` and the settings they override.
pub fn parse(args: []const []const u8, a: *Args, set: *settings_mod.Settings) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (eq(arg, "--region")) {
            a.area = try region.Rect.parse(next);
            i += 1;
        } else if (eq(arg, "--full")) {
            a.full = true;
        } else if (eq(arg, "--seconds")) {
            a.seconds = try std.fmt.parseInt(u32, next, 10);
            i += 1;
        } else if (eq(arg, "--out")) {
            a.out = next;
            i += 1;
        } else if (eq(arg, "--fps")) {
            set.apply(if (set.format == .gif) "record_gif_fps" else "record_fps", next);
            i += 1;
        } else if (eq(arg, "--gif")) {
            set.format = .gif;
        } else if (eq(arg, "--mp4")) {
            set.format = .mp4;
        } else if (eq(arg, "--mic")) {
            set.mic = true;
        } else if (eq(arg, "--system-audio")) {
            set.system_audio = true;
        } else if (eq(arg, "--clicks")) {
            set.clicks = true;
        } else if (eq(arg, "--keys")) {
            set.keys = true;
        } else if (eq(arg, "--no-countdown")) {
            set.countdown = 0;
        } else if (eq(arg, "--no-control")) {
            a.control = false;
        } else if (eq(arg, "--stop") or eq(arg, "--pause") or eq(arg, "--resume") or eq(arg, "--discard")) {
            a.command = arg[2..];
        } else {
            std.log.warn("record: unknown option {s}", .{arg});
            return error.BadArgs;
        }
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `shotlet record ARGS...`
pub fn main(gpa: std.mem.Allocator, env: Env, argv: []const []const u8) !void {
    var set = settings_mod.load(gpa, env.home);
    var a: Args = .{};
    try parse(argv, &a, &set);
    var ans: [64]u8 = undefined;
    if (a.command) |c| {
        const r = ctlsock.send(env.runtime_dir, env.wayland_display, c, &ans) orelse {
            std.debug.print("no recording under way\n", .{});
            return error.NotRecording;
        };
        std.debug.print("{s}\n", .{r});
        return;
    }
    // the same shortcut again: stop the recording under way
    if (ctlsock.send(env.runtime_dir, env.wayland_display, "stop", &ans)) |r| {
        std.log.info("record: stopped the recording under way ({s})", .{r});
        return;
    }
    try run_mod.run(gpa, env, a, set, null);
}

test "record options parse" {
    var a: Args = .{};
    var s: settings_mod.Settings = .{};
    try parse(&.{ "--region", "10,20,300,200", "--gif", "--fps", "12", "--seconds", "2", "--no-countdown", "--keys" }, &a, &s);
    try std.testing.expectEqual(region.Rect{ .x = 10, .y = 20, .w = 300, .h = 200 }, a.area.?);
    try std.testing.expectEqual(@as(u32, 12), s.gif_fps);
    try std.testing.expectEqual(@as(u32, 0), s.countdown);
    try std.testing.expect(s.keys and !s.clicks);
    var b: Args = .{};
    try parse(&.{"--stop"}, &b, &s);
    try std.testing.expectEqualStrings("stop", b.command.?);
    try std.testing.expectError(error.BadArgs, parse(&.{"--bogus"}, &b, &s));
}
