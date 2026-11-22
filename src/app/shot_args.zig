//! `shotlet shot|text [--FLAG VALUE]...` (src/cli/cmds_capture.zig lists
//! the flags). Dev/testing flags: --from FILE (skip portal), --sel
//! X,Y,W,H (preset selection), --smoke MS (auto-cancel, for leak runs),
//! --from-monitors A.png,B.png (one image per monitor, side by side).
//! The GNOME extension's hand-off: --from-shell ID and its companions.

const std = @import("std");
const shot = @import("shot.zig");
const shell = @import("../platform/api.zig").shell;
const Env = @import("env.zig").Env;

const ShotArgs = struct {
    from: ?[]const u8 = null,
    from_monitors: ?[]const u8 = null,
    from_shell: ?shell.HandedCapture = null,
    shell_monitors: []const u8 = "",
    shell_pieces: []const u8 = "",
    t0: ?i64 = null,
    sel: ?[4]i32 = null,
    smoke_ms: i64 = 0,
    then_record: bool = false,
    req: @import("modes/mode.zig").Request = .{},
};

/// `flags`: flag/value pairs.
pub fn run(gpa: std.mem.Allocator, env: Env, flags: []const [:0]const u8) !void {
    var o: ShotArgs = .{};
    var i: usize = 0;
    while (i + 1 < flags.len) : (i += 2) try parseFlag(&o, flags[i], flags[i + 1]);
    if (o.from_shell) |*fs| {
        fs.monitors = o.shell_monitors;
        fs.pieces = o.shell_pieces;
        fs.t0_ms = o.t0;
    }
    if (o.then_record and o.from_shell != null) return @import("../record/cli.zig").fromShell(gpa, env, o.from_shell.?);
    try shot.run(gpa, env, .{ .file = o.from, .monitors = o.from_monitors, .shell = o.from_shell, .req = o.req }, o.sel, o.smoke_ms);
}

fn parseFlag(o: *ShotArgs, flag: []const u8, value: [:0]const u8) !void {
    const eql = std.mem.eql;
    if (eql(u8, flag, "--from")) {
        o.from = value;
    } else if (eql(u8, flag, "--from-monitors")) {
        o.from_monitors = value;
    } else if (eql(u8, flag, "--from-shell")) {
        // the GNOME Shell extension's capture (src/app/shellcap.zig)
        o.from_shell = .{ .id = value };
    } else if (eql(u8, flag, "--monitors")) {
        o.shell_monitors = value;
    } else if (eql(u8, flag, "--pieces")) {
        o.shell_pieces = value;
    } else if (eql(u8, flag, "--then")) {
        // the extension's record shortcut: the picker on this capture
        if (eql(u8, value, "record")) o.then_record = true;
    } else if (eql(u8, flag, "--mode")) {
        o.req.withModeArg(value);
    } else if (eql(u8, flag, "--pointer")) {
        o.req.withPointerArg(value);
    } else if (eql(u8, flag, "--t0")) {
        o.t0 = std.fmt.parseInt(i64, value, 10) catch null;
    } else if (eql(u8, flag, "--smoke")) {
        o.smoke_ms = std.fmt.parseInt(i64, value, 10) catch 0;
    } else if (eql(u8, flag, "--sel")) {
        o.sel = try parseSel(value);
    }
}

/// "X,Y,W,H" for --sel.
fn parseSel(value: []const u8) ![4]i32 {
    var it = std.mem.splitScalar(u8, value, ',');
    var vals: [4]i32 = undefined;
    for (&vals) |*v| {
        v.* = std.fmt.parseInt(i32, it.next() orelse return error.BadSelArg, 10) catch return error.BadSelArg;
    }
    return vals;
}
