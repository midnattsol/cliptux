//! The messages for a command line the parser refused (to stderr; the
//! process then exits with status 2).

const std = @import("std");
const parse = @import("parse.zig");

pub const exit_code: u8 = 2;

/// "shotlet gnome-integration install"
pub fn writeChain(w: *std.Io.Writer, chain: parse.Chain) !void {
    try w.writeAll("shotlet");
    for (chain.slice()) |c| try w.print(" {s}", .{c.name});
}

pub fn write(w: *std.Io.Writer, f: parse.Failure) !void {
    try writeChain(w, f.chain);
    try w.writeAll(": ");
    switch (f.kind) {
        .unknown_command => try w.print("unknown command '{s}'", .{f.token}),
        .unknown_option => try w.print("unknown option '{s}'", .{f.token}),
        .missing_value => try w.print("option '{s}' needs a value ({s})", .{ f.token, f.detail }),
        .unexpected_value => try w.print("option '{s}' takes no value", .{f.token}),
        .bad_value => try w.print("invalid value '{s}' for {s}: {s}", .{ f.token, f.what, f.detail }),
        .extra_arg => try w.print("unexpected argument '{s}'", .{f.token}),
        .missing_arg => try w.print("missing {s}", .{f.token}),
    }
    try w.writeAll("\n");
    if (f.suggestion) |s| try w.print("Did you mean '{s}'?\n", .{s});
    try w.writeAll("Run '");
    try writeChain(w, f.chain);
    try w.writeAll(" --help'.\n");
}

fn expectMessage(args: []const [:0]const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try parse.parse(arena.allocator(), args);
    var buf: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(&buf.writer, out.fail);
    try std.testing.expectEqualStrings(want, buf.written());
}

test "error messages" {
    try expectMessage(&.{"recrod"},
        \\shotlet: unknown command 'recrod'
        \\Did you mean 'record'?
        \\Run 'shotlet --help'.
        \\
    );
    try expectMessage(&.{ "permissions", "--bogus" },
        \\shotlet permissions: unknown option '--bogus'
        \\Run 'shotlet permissions --help'.
        \\
    );
    try expectMessage(&.{ "permissions", "reset", "--dry-rn" },
        \\shotlet permissions reset: unknown option '--dry-rn'
        \\Did you mean '--dry-run'?
        \\Run 'shotlet permissions reset --help'.
        \\
    );
    try expectMessage(&.{ "record", "--seconds" },
        \\shotlet record: option '--seconds' needs a value (N)
        \\Run 'shotlet record --help'.
        \\
    );
    try expectMessage(&.{ "timer", "99" },
        \\shotlet timer: invalid value '99' for SECONDS: expected a whole number from 0 to 60
        \\Run 'shotlet timer --help'.
        \\
    );
    try expectMessage(&.{"edit"},
        \\shotlet edit: missing FILE
        \\Run 'shotlet edit --help'.
        \\
    );
}
