//! `shotlet record`: pick an area (or the whole screen) and record it.
//!
//!     shotlet record                  pick an area, then record
//!     shotlet record --full           the whole monitor under the pointer
//!     shotlet record --region X,Y,W,H an area (logical pixels), no picker
//!     shotlet record --stop | --pause | --resume | --discard
//!                                     control the recording under way
//!     options: --gif | --mp4 | --format mp4|gif, --fps N, --mic, --system-audio, --clicks,
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
const shellrec = @import("shellrec.zig");
const picker = @import("../ui/recui/picker.zig");
const capture = @import("../app/capture.zig");
const config = @import("../app/config.zig");
const gnome = @import("../app/gnome.zig");
const shot = @import("../app/shot.zig");
const shellcap = @import("../app/shellcap.zig");
const dbus = @import("../platform/linux/dbus.zig");
const portal = @import("../platform/linux/portal.zig");
const text = @import("../gfx/text.zig");
const theme = @import("../ui/theme.zig");
const Env = env_mod.Env;

pub const Args = struct {
    area: ?region.Rect = null,
    full: bool = false,
    seconds: ?u32 = null,
    out: ?[]const u8 = null,
    control: bool = true,
    /// a command for the running recording
    command: ?[]const u8 = null,
    /// the option `parse` did not know, for the caller's message
    unknown: ?[]const u8 = null,
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
        } else if (eq(arg, "--format")) {
            set.format = std.meta.stringToEnum(@TypeOf(set.format), next) orelse return error.BadArgs;
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
            a.unknown = arg;
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
    parse(argv, &a, &set) catch |err| {
        if (a.unknown) |opt| std.log.warn("record: unknown option {s}", .{opt});
        return err;
    };
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
    if (a.area != null or a.full) return run_mod.run(gpa, env, a, set, null);
    try pickThenRun(gpa, env, a, set);
}

/// The picker on a capture of the desktop: taken by the GNOME Shell
/// extension (which then starts `shotlet --from-shell ... --then record`),
/// else as for screenshots (direct or the portal).
fn pickThenRun(gpa: std.mem.Allocator, env: Env, a: Args, set: settings_mod.Settings) !void {
    var bus = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer bus.deinit();
    if (gnome.isGnome() and shellrec.available(gpa, &bus)) {
        if (shellrec.select(gpa, &bus)) {
            std.log.info("record: the picker is up through the GNOME integration", .{});
            return;
        } else |err| std.log.info("record: GNOME integration: {t}", .{err});
    }
    var cfg = config.load(gpa, env.home);
    portal.registerApp(gpa, &bus);
    var cap = (try shot.acquire(gpa, env, &bus, &cfg, .{})) orelse return;
    defer cap.deinit(gpa);
    try pickOn(gpa, env, a, set, &cap, false);
}

/// `shotlet --from-shell ID ... --then record`
pub fn fromShell(gpa: std.mem.Allocator, env: Env, args: shellcap.Args) !void {
    var cap = try shellcap.load(gpa, env.runtime_dir, args);
    defer cap.deinit(gpa);
    try pickOn(gpa, env, .{}, settings_mod.load(gpa, env.home), &cap, true);
}

/// The picker on a capture already taken (the editor's Record mode).
pub fn pickOnCapture(gpa: std.mem.Allocator, env: Env, cap: *const capture.Capture, overlays: bool) !void {
    try pickOn(gpa, env, .{}, settings_mod.load(gpa, env.home), cap, overlays);
}

fn pickOn(gpa: std.mem.Allocator, env: Env, a: Args, set0: settings_mod.Settings, cap: *const capture.Capture, overlays: bool) !void {
    var set = set0;
    text.init(gpa);
    std.log.info("record: picker up", .{});
    const res = picker.pick(gpa, env, cap, &set, overlays, appearance(gpa, env));
    text.deinit();
    const area = switch (try res) {
        .area => |r| r,
        .cancelled => {
            std.log.info("record: cancelled in the picker", .{});
            return;
        },
    };
    saveChoices(gpa, env.home, &set0, &set);
    std.log.info("record: picked {d},{d} {d}x{d}", .{ area.x, area.y, area.w, area.h });
    try run_mod.run(gpa, env, a, set, area);
}

/// The desktop's light or dark look and accent, for the picker.
fn appearance(gpa: std.mem.Allocator, env: Env) theme.Theme {
    var bus = dbus.Connection.connectSession(gpa, env.bus_addr) catch return theme.Theme.get(true, null);
    defer bus.deinit();
    return theme.readPrefs(&bus, 300).theme();
}

/// Remember the bar's choices for next time.
fn saveChoices(gpa: std.mem.Allocator, home: []const u8, old: *const settings_mod.Settings, new: *const settings_mod.Settings) void {
    const tf = struct {
        fn f(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.f;
    if (old.format != new.format) settings_mod.save(gpa, home, "record_format", @tagName(new.format));
    if (old.mic != new.mic) settings_mod.save(gpa, home, "record_mic", tf(new.mic));
    if (old.system_audio != new.system_audio) settings_mod.save(gpa, home, "record_system_audio", tf(new.system_audio));
    if (old.clicks != new.clicks) settings_mod.save(gpa, home, "record_clicks", tf(new.clicks));
    if (old.keys != new.keys) settings_mod.save(gpa, home, "record_keys", tf(new.keys));
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
    try std.testing.expectEqualStrings("--bogus", b.unknown.?);
    try parse(&.{ "--format", "mp4" }, &b, &s);
    try std.testing.expectEqual(.mp4, s.format);
}
