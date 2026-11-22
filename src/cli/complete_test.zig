//! The generated scripts and man page are well-formed: bash -n, zsh -n,
//! fish -n and groff -ww check them where installed.

const std = @import("std");
const complete = @import("complete.zig");
const man = @import("man.zig");
const proc = @import("../encode/proc.zig");
const sys = @import("../platform/sys.zig");
const t = std.testing;

fn render(shell: ?complete.Shell) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer buf.deinit();
    if (shell) |s| try complete.write(&buf.writer, s) else try man.write(&buf.writer);
    return buf.toOwnedSlice();
}

/// Runs `sh -c script` with `input` on stdin; its exit status and what
/// it printed (stderr folded into stdout by the script).
fn check(script: [:0]const u8, input: []const u8) !?u8 {
    var pbuf: [256]u8 = undefined;
    const sh = proc.which(&pbuf, "sh") orelse return error.SkipZigTest;
    const envp: proc.Envp = @ptrCast(std.c.environ);
    var c = try proc.spawn(&.{ sh.ptr, "-c", script.ptr }, envp, .{ .stdin = true });
    try sys.writeAll(c.stdin.?, input);
    return c.wait(20000);
}

fn hasProgram(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    return proc.which(&buf, name) != null;
}

fn expectContains(s: []const u8, needles: []const []const u8) !void {
    for (needles) |n| {
        if (std.mem.indexOf(u8, s, n) == null) std.debug.print("missing: {s}\n", .{n});
        try t.expect(std.mem.indexOf(u8, s, n) != null);
    }
}

test "bash completions parse and cover commands, options and choices" {
    const s = try render(.bash);
    defer t.allocator.free(s);
    try expectContains(s, &.{ "\"permissions/reset\") cmd=permissions/reset", "\"/--daemon\") cmd=daemon", "\"record --format\") COMPREPLY=($(compgen -W \"mp4 gif\"", "\"completions\") words=\"bash zsh fish\"", "\"edit\") words=\"\" opts=\"--help -h\" files=1", "complete -o filenames -F _shotlet shotlet" });
    try t.expect(std.mem.indexOf(u8, s, "quick-video") == null and std.mem.indexOf(u8, s, "--from-shell") == null);
    if (!hasProgram("bash")) return error.SkipZigTest;
    try t.expectEqual(@as(?u8, 0), try check("bash -n", s));
}

test "zsh completions parse" {
    const s = try render(.zsh);
    defer t.allocator.free(s);
    try expectContains(s, &.{ "#compdef shotlet", "'reset:Forget them all: the next capture asks again'", "\"record --format\") compadd -- mp4 gif" });
    if (!hasProgram("zsh")) return error.SkipZigTest;
    try t.expectEqual(@as(?u8, 0), try check("zsh -n", s));
}

test "fish completions parse" {
    const s = try render(.fish);
    defer t.allocator.free(s);
    try expectContains(s, &.{ "-n '__fish_seen_subcommand_from record' -l format -x -a 'mp4 gif'", "-n '__fish_seen_subcommand_from pin' -F", "-a 'bash zsh fish'" });
    if (!hasProgram("fish")) return error.SkipZigTest;
    try t.expectEqual(@as(?u8, 0), try check("fish -n", s));
}

test "the man page is well-formed roff" {
    const s = try render(null);
    defer t.allocator.free(s);
    try t.expect(std.mem.startsWith(u8, s, ".TH SHOTLET 1 "));
    try expectContains(s, &.{ ".SH NAME\n", ".SH SYNOPSIS\n", ".SH \"CAPTURE COMMANDS\"\n", ".SS \"shotlet permissions reset\"\n", "\\fB\\-\\-dry\\-run\\fR" });
    const macros = [_][]const u8{ ".TH ", ".SH ", ".SS ", ".TP", ".PP", ".B ", ".I ", ".RI ", ".nf", ".fi", ".RS", ".RE" };
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |l| {
        try t.expect(!std.mem.startsWith(u8, l, "'"));
        if (!std.mem.startsWith(u8, l, ".")) continue;
        var known = false;
        for (macros) |m| known = known or std.mem.startsWith(u8, l, m);
        if (!known) std.debug.print("unknown request: {s}\n", .{l});
        try t.expect(known);
    }
    if (!hasProgram("groff")) return error.SkipZigTest;
    // warnings (-ww) on stderr fail the check
    try t.expectEqual(@as(?u8, 0), try check("out=$(groff -man -Tutf8 -ww -z 2>&1) && [ -z \"$out\" ]", s));
}
