//! The help texts: every command's renders in clean columns within 80,
//! and the overview lists exactly the user-facing commands.

const std = @import("std");
const help = @import("help.zig");
const commands = @import("commands.zig");
const parse = @import("parse.zig");
const t = std.testing;

/// Every line fits 80 columns; in each headed section every line is a
/// row ("  LABEL  text", the text at the section's one column) or the
/// wrapped rest of the row above, aligned under its text; never a label
/// alone or a text alone.
fn expectLayout(s: []const u8) !void {
    var blocks = std.mem.splitSequence(u8, s, "\n\n");
    while (blocks.next()) |block| {
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |l| if (l.len > 80) return error.TooWide;
        var it = std.mem.splitScalar(u8, block, '\n');
        const head = it.next().?;
        if (head.len == 0 or head[0] == ' ' or !std.mem.endsWith(u8, head, ":")) continue;
        try expectColumns(&it);
    }
}

fn expectColumns(it: *std.mem.SplitIterator(u8, .scalar)) !void {
    var col: ?usize = null;
    while (it.next()) |l| {
        if (l.len == 0) continue;
        if (col) |c| if (l.len > c and isBlank(l[0..c]) and l[c] != ' ') continue;
        const at = textColumn(l) orelse return error.NotARow;
        if (col != null and col.? != at) return error.Misaligned;
        col = at;
    }
}

/// Where the text of "  LABEL  text" starts; null when it is no row.
fn textColumn(l: []const u8) ?usize {
    if (l.len < 3 or !std.mem.startsWith(u8, l, "  ")) return null;
    const start = std.mem.indexOfNone(u8, l, " ") orelse return null;
    if (start != 2 and start != 6) return null;
    const gap = std.mem.indexOfPos(u8, l, start, "  ") orelse return null;
    return std.mem.indexOfNonePos(u8, l, gap, " ");
}

fn isBlank(s: []const u8) bool {
    return std.mem.indexOfNone(u8, s, " ") == null;
}

test "the overview groups the user-facing commands" {
    var buf: std.Io.Writer.Allocating = .init(t.allocator);
    defer buf.deinit();
    try help.overview(&buf.writer, .{});
    const s = buf.written();
    expectLayout(s) catch |err| {
        std.debug.print("in the overview:\n{s}\n", .{s});
        return err;
    };
    for (help.groups) |g| {
        var hb: [64]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, s, try std.fmt.bufPrint(&hb, "\n{s}:\n", .{g.title()})) != null);
    }
    for (&commands.all) |*c| {
        var lb: [64]u8 = undefined;
        var nb: [80]u8 = undefined;
        const label = if (c.internal()) c.name else help.commandLabel(&lb, c);
        const needle = try std.fmt.bufPrint(&nb, "\n  {s}  ", .{label});
        try t.expectEqual(!c.internal(), std.mem.indexOf(u8, s, needle) != null);
    }
    try t.expect(std.mem.indexOf(u8, s, "\x1b") == null);
}

fn expectCommandHelp(chain: parse.Chain) !void {
    var buf: std.Io.Writer.Allocating = .init(t.allocator);
    defer buf.deinit();
    try help.command(&buf.writer, .{}, chain);
    const s = buf.written();
    expectLayout(s) catch |err| {
        std.debug.print("in the help of {s}:\n{s}\n", .{ chain.leaf().?.name, s });
        return err;
    };
    try t.expect(std.mem.startsWith(u8, s, "Usage: shotlet"));
    try t.expect(std.mem.indexOf(u8, s, "\nOptions:\n") != null);
    // one line per example, its comment beside it
    const ex = std.mem.indexOf(u8, s, "\nExamples:\n") orelse return error.NoExamples;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s[ex + 11 ..], "\n"), '\n');
    while (lines.next()) |l| try t.expect(std.mem.startsWith(u8, l, "  shotlet"));
    // plumbing stays out of the help
    try t.expect(std.mem.indexOf(u8, s, "--from-shell") == null);
    for (chain.leaf().?.subs) |*sub| {
        var c = chain;
        c.push(sub);
        try expectCommandHelp(c);
    }
}

test "every command's help has usage, options and examples in columns" {
    for (&commands.all) |*c| try expectCommandHelp(.of(c));
}

test "the layout check catches a text alone on its line" {
    try t.expectError(error.NotARow, expectLayout("Options:\n  --a  one\n          alone\n"));
    try t.expectError(error.Misaligned, expectLayout("Options:\n  --a  one\n  --bb  two\n"));
    try t.expectError(error.NotARow, expectLayout("Options:\n  --label-only\n"));
    try expectLayout("Options:\n  --a      one\n           wrapped\n      --b  two\n");
}

test "bold headings only when asked" {
    var buf: std.Io.Writer.Allocating = .init(t.allocator);
    defer buf.deinit();
    try help.command(&buf.writer, .{ .bold = true }, .of(commands.find("record").?));
    try t.expect(std.mem.indexOf(u8, buf.written(), "\x1b[1mOptions:\x1b[0m") != null);
}
