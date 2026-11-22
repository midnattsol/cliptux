//! Runs the command the command line named (src/cli/ parsed and checked
//! it). The switch covers every command of the table.

const std = @import("std");
const Env = @import("env.zig").Env;
const Parsed = @import("../cli/parse.zig").Parsed;
const errors = @import("../cli/errors.zig");
const launch = @import("../ui/tools/launch.zig");
const gnome = @import("gnome.zig");

pub fn run(gpa: std.mem.Allocator, env: Env, p: Parsed) !void {
    const r = p.rest;
    switch (p.id()) {
        .shot, .text => try runShot(gpa, env, p),
        .area, .fullscreen, .screens, .previous, .window, .scroll, .timer => {
            _ = try @import("modes/cli.zig").run(gpa, env, p.chain.items[0].name, r);
        },
        .record => try @import("../record/cli.zig").main(gpa, env, r),
        .edit => try runEdit(gpa, env, p.positionals),
        .pin => if (p.positionals.len > 0)
            try @import("pin.zig").run(gpa, env, p.positionals[0], if (p.value("at")) |a| @import("pin.zig").parseAt(a) else null)
        else
            try @import("clipimg.zig").pinClipboard(gpa, env),
        .history => try @import("history_ui.zig").run(gpa, env, smoke(p)),
        .history_clear => try clearHistory(env),
        .thumbnail => try @import("lastthumb.zig").run(gpa, env),
        .settings => try @import("../ui/settings.zig").run(gpa, env, smoke(p)),
        .daemon => try @import("daemon.zig").run(gpa, env, p.flag("foreground")),
        .gnome_integration, .gnome_status => try gnome.runCli(gpa, env, "status", &.{}),
        .gnome_install => try gnome.runCli(gpa, env, "install", r),
        .gnome_uninstall => try gnome.runCli(gpa, env, "uninstall", &.{}),
        .gnome_shortcut => try gnome.runCli(gpa, env, "shortcut", p.positionals),
        .permissions => try @import("permissions.zig").run(gpa, env, &.{}),
        .permissions_reset => try @import("permissions.zig").run(gpa, env, if (p.flag("dry-run")) &.{ "reset", "--dry-run" } else &.{"reset"}),
        // answered by src/cli/front.zig
        .help, .completions, .man_page => unreachable,
        .quick => try @import("quick.zig").run(gpa, env, (try need(p, 2))[0], r[1], readyFd(r[2..])),
        .quick_video => try @import("../record/quickvid.zig").run(gpa, env, (try need(p, 2))[0], r[1]),
        .trim => try @import("../ui/recui/trimui.zig").run(gpa, env, (try need(p, 2))[0], r[1], r[2..]),
        .toast => try @import("toastwin.zig").run(gpa, env, (try need(p, 1))[0], if (r.len > 1) r[1] else ""),
        .test_window, .test_grab, .test_font, .test_decode => {
            _ = try @import("devtools.zig").run(gpa, env, p.chain.items[0].name, r);
        },
    }
}

/// The shot or text capture; `shotlet --from-shell ...` is the GNOME
/// Shell extension starting one.
fn runShot(gpa: std.mem.Allocator, env: Env, p: Parsed) !void {
    if (p.shell_launch) {
        launch.takeHandOff(env.runtime_dir);
        // the extension runs: an install that waited for it can finish
        gnome.finishPendingSetup(env);
    }
    // `shotlet text` is a capture whose region's text is copied
    if (p.id() == .text) launch.text_capture = true;
    try @import("shot_args.zig").run(gpa, env, p.rest);
}

/// `edit FILE`, or `edit ROOT ID`: a history entry again (the thumbnail).
fn runEdit(gpa: std.mem.Allocator, env: Env, args: []const [:0]const u8) !void {
    if (args.len > 1) return @import("shot.zig").runEdit(gpa, env, args[0], args[1]);
    try @import("editfile.zig").run(gpa, env, args[0]);
}

fn clearHistory(env: Env) !void {
    const history = @import("history.zig");
    var buf: [1024]u8 = undefined;
    history.clear(try history.historyRoot(&buf, env.home));
    std.debug.print("history cleared\n", .{});
}

/// `quick ROOT ID READY-FD`: the pipe the editor waits on, if any.
fn readyFd(rest: []const [:0]const u8) ?i32 {
    if (rest.len == 0) return null;
    const fd = std.fmt.parseInt(i32, rest[0], 10) catch return null;
    return if (fd > 2) fd else null;
}

/// `--smoke MS`: auto-close after MS (leak runs); 0 when absent.
fn smoke(p: Parsed) i64 {
    const v = p.value("smoke") orelse return 0;
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

/// An internal command's arguments, when it got at least `n`; else the
/// usage error (exit status 2).
fn need(p: Parsed, n: usize) ![]const [:0]const u8 {
    if (p.rest.len >= n) return p.rest;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    errors.writeChain(&w, p.chain) catch {};
    w.print(": missing arguments (usage: shotlet {s})\n", .{p.chain.items[0].usage[0]}) catch {};
    @import("../platform/sys.zig").writeAll(2, w.buffered()) catch {};
    std.process.exit(errors.exit_code);
}
