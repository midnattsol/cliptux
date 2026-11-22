//! Shell completions from the command table: `shotlet completions
//! bash|zsh|fish`. They complete the user-facing commands, subcommands,
//! options, values with fixed choices and file names; internal commands
//! and testing options stay out.

const std = @import("std");
const spec = @import("spec.zig");
const commands = @import("commands.zig");

pub const Shell = enum { bash, zsh, fish };

pub fn write(w: *std.Io.Writer, shell: Shell) !void {
    switch (shell) {
        .bash => try @import("complete_bash.zig").write(w),
        .zsh => try @import("complete_zsh.zig").write(w),
        .fish => try @import("complete_fish.zig").write(w),
    }
}

/// The options shown at the top level, before a command.
pub const top_options = [_]spec.Option{
    .{ .long = "help", .short = 'h', .help = "Show the help" },
    .{ .long = "version", .short = 'V', .help = "Show the version" },
};

/// The options a command completes: its own (not testing or plumbing
/// ones), then --help.
pub fn options(c: *const spec.Command, buf: []spec.Option) []const spec.Option {
    var n: usize = 0;
    for (c.options) |o| if (o.vis == .normal and n + 1 < buf.len) {
        buf[n] = o;
        n += 1;
    };
    buf[n] = .{ .long = "help", .short = 'h', .help = "Show the help" };
    return buf[0 .. n + 1];
}

/// "record", "gnome-integration/install": a command's key in the
/// scripts' state.
pub fn key(buf: []u8, parent: ?*const spec.Command, c: *const spec.Command) []const u8 {
    const p = parent orelse return c.name;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ p.name, c.name }) catch c.name;
}

/// Calls `f(ctx, parent, command)` for every user-facing command and
/// subcommand.
pub fn each(ctx: anytype, comptime f: anytype) !void {
    for (&commands.all) |*c| if (!c.internal()) {
        try f(ctx, null, c);
        for (c.subs) |*s| try f(ctx, c, s);
    };
}

/// The first visible argument's spec, which the words complete.
pub fn firstArg(c: *const spec.Command) ?spec.Arg {
    for (c.args) |a| if (!a.hidden) return a;
    return null;
}

/// `s` in single quotes for sh, zsh and fish (a quote inside closes,
/// escapes and reopens; fish reads \' inside quotes).
pub fn quoted(w: *std.Io.Writer, s: []const u8, fish: bool) !void {
    try w.writeByte('\'');
    for (s) |ch| {
        if (ch == '\'') {
            try w.writeAll(if (fish) "\\'" else "'\\''");
        } else if (ch == '\\' and fish) {
            try w.writeAll("\\\\");
        } else try w.writeByte(ch);
    }
    try w.writeByte('\'');
}
