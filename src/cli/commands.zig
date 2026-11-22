//! Shotlet's command table: every command main dispatches, with what it
//! takes and its help. The parser, the help, the man page and the shell
//! completions all read it.

const std = @import("std");
const spec = @import("spec.zig");

pub const Command = spec.Command;
pub const Id = spec.Id;

pub const version = @import("version").string;

pub const tagline = "screenshots, recordings and annotations for Linux";

/// The top-level commands, in overview order.
pub const all = @import("cmds_capture.zig").list ++ @import("cmds_record.zig").list ++
    @import("cmds_more.zig").list ++ @import("cmds_internal.zig").list;

/// The command run without one.
pub const default: *const Command = &all[0];

/// The top-level command named `name` (or one of its aliases).
pub fn find(name: []const u8) ?*const Command {
    for (&all) |*c| if (c.named(name)) return c;
    return null;
}

/// How many entries (commands and subcommands, recursively) have `id`.
fn countId(cmds: []const Command, id: Id) usize {
    var n: usize = 0;
    for (cmds) |*c| {
        if (c.id == id) n += 1;
        n += countId(c.subs, id);
    }
    return n;
}

fn checkCommand(c: *const Command) !void {
    // one line in the overview, beside the longest name
    try std.testing.expect(c.summary.len > 0 and c.summary.len <= 58);
    try std.testing.expect(c.usage.len > 0);
    try std.testing.expect(c.examples.len > 0);
    try std.testing.expect(c.subs.len == 0 or c.args.len == 0);
    for (c.options) |o| try std.testing.expect(o.help.len > 0);
    for (c.args) |a| try std.testing.expect(a.help.len > 0);
    for (c.subs) |*s| try checkCommand(s);
}

test "every command main dispatches has exactly one table entry" {
    // main's dispatch switches over Id exhaustively, so a command it runs
    // needs an Id, and an Id needs its entry here
    inline for (comptime std.enums.values(Id)) |id| {
        std.testing.expectEqual(@as(usize, 1), countId(&all, id)) catch |err| {
            std.debug.print("command {t}: no single table entry\n", .{id});
            return err;
        };
    }
}

test "every command has a summary, usage, help texts and an example" {
    for (&all) |*c| try checkCommand(c);
}

test "command names are unique" {
    for (&all, 0..) |*a, i| for (all[i + 1 ..]) |*b| {
        try std.testing.expect(!b.named(a.name));
        for (a.aliases) |al| try std.testing.expect(!b.named(al));
    };
}
