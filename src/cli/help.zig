//! `shotlet --help` (the overview, grouped) and `shotlet COMMAND --help`
//! (usage, options, examples), from the command table. Every section is
//! two columns: a label, and its text on the same line, aligned in the
//! section and wrapped under itself.

const std = @import("std");
const spec = @import("spec.zig");
const commands = @import("commands.zig");
const text = @import("text.zig");
const Chain = @import("parse.zig").Chain;
const Style = text.Style;
const W = *std.Io.Writer;

pub const groups = [_]spec.Group{ .capture, .record, .edit_pin, .history, .settings, .other };

const top_options = [_]spec.Option{
    .{ .long = "help", .short = 'h', .help = "Show this help" },
    .{ .long = "version", .short = 'V', .help = "Show the version" },
};

const help_option: spec.Option = .{ .long = "help", .short = 'h', .help = "Show this help" };

pub fn overview(w: W, s: Style) !void {
    try w.print("Shotlet — {s}\nVersion {s}\n\nUsage: shotlet [COMMAND] [OPTIONS]\n", .{ commands.tagline, commands.version });
    var buf: [64]u8 = undefined;
    const col = overviewColumn();
    for (groups) |g| {
        try w.writeAll("\n");
        try s.heading(w, g.title());
        for (&commands.all) |*c| if (c.group == g) try text.row(w, commandLabel(&buf, c), col, c.summary);
    }
    try w.writeAll("\n");
    try s.heading(w, "Options");
    for (top_options) |o| try text.row(w, optionLabel(&buf, o), col, o.help);
    try w.writeAll("\nRun 'shotlet help COMMAND' or 'shotlet COMMAND --help' for details.\n");
}

fn overviewColumn() usize {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (&commands.all) |*c| if (!c.internal()) {
        n = @max(n, commandLabel(&buf, c).len);
    };
    for (top_options) |o| n = @max(n, optionLabel(&buf, o).len);
    return text.column(n);
}

/// "timer [SECONDS]", "edit FILE"; "(none)" for the default capture.
pub fn commandLabel(buf: []u8, c: *const spec.Command) []const u8 {
    if (c == commands.default) return "(none)";
    var fw: std.Io.Writer = .fixed(buf);
    fw.writeAll(c.name) catch {};
    for (c.args) |a| if (!a.hidden) {
        const dots = if (a.repeat) "..." else "";
        if (a.required) fw.print(" {s}{s}", .{ a.name, dots }) catch {} else fw.print(" [{s}{s}]", .{ a.name, dots }) catch {};
    };
    return fw.buffered();
}

/// "-f, --foreground", "    --region X,Y,W,H": long options line up
/// whether or not there is a short one.
pub fn optionLabel(buf: []u8, o: spec.Option) []const u8 {
    var fw: std.Io.Writer = .fixed(buf);
    if (o.short) |c| fw.print("-{c}, ", .{c}) catch {} else fw.writeAll("    ") catch {};
    fw.print("--{s}", .{o.long}) catch {};
    if (o.value) |v| fw.print(" {s}", .{v}) catch {};
    return fw.buffered();
}

/// The full help of the last command in `chain`.
pub fn command(w: W, s: Style, chain: Chain) !void {
    const c = chain.leaf().?;
    for (c.usage, 0..) |u, i| {
        const lead = if (i == 0) "Usage: " else "       ";
        try w.print("{s}shotlet{s}{s}\n", .{ lead, if (u.len > 0) " " else "", u });
    }
    try w.writeAll("\n");
    try text.wrap(w, if (c.description.len > 0) c.description else c.summary, 0, 0);
    try subcommands(w, s, c);
    try arguments(w, s, c);
    try options(w, s, c, .normal, "Options");
    try options(w, s, c, .dev, "Testing options");
    try examples(w, s, c);
}

fn subcommands(w: W, s: Style, c: *const spec.Command) !void {
    if (c.subs.len == 0) return;
    try w.writeAll("\n");
    try s.heading(w, "Commands");
    var n: usize = 0;
    for (c.subs) |sub| n = @max(n, sub.name.len);
    for (c.subs) |sub| try text.row(w, sub.name, text.column(n), sub.summary);
}

fn arguments(w: W, s: Style, c: *const spec.Command) !void {
    var n: usize = 0;
    for (c.args) |a| if (!a.hidden) {
        n = @max(n, a.name.len);
    };
    if (n == 0) return;
    try w.writeAll("\n");
    try s.heading(w, "Arguments");
    for (c.args) |a| if (!a.hidden) try text.row(w, a.name, text.column(n), a.help);
}

fn options(w: W, s: Style, c: *const spec.Command, vis: spec.Visibility, title: []const u8) !void {
    var buf: [64]u8 = undefined;
    var n: usize = if (vis == .normal) optionLabel(&buf, help_option).len else 0;
    for (c.options) |o| if (o.vis == vis) {
        n = @max(n, optionLabel(&buf, o).len);
    };
    if (n == 0) return;
    try w.writeAll("\n");
    try s.heading(w, title);
    for (c.options) |o| if (o.vis == vis) try optionRow(w, text.column(n), o);
    if (vis == .normal) try text.row(w, optionLabel(&buf, help_option), text.column(n), help_option.help);
}

fn optionRow(w: W, col: usize, o: spec.Option) !void {
    var buf: [64]u8 = undefined;
    var hbuf: [256]u8 = undefined;
    const help = if (o.default) |d|
        std.fmt.bufPrint(&hbuf, "{s} (default: {s})", .{ o.help, d }) catch o.help
    else
        o.help;
    try text.row(w, optionLabel(&buf, o), col, help);
}

/// "  shotlet record --stop    # Stop the recording under way"
fn examples(w: W, s: Style, c: *const spec.Command) !void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (c.examples) |e| n = @max(n, exampleLabel(&buf, e).len);
    try w.writeAll("\n");
    try s.heading(w, "Examples");
    var cbuf: [256]u8 = undefined;
    for (c.examples) |e| {
        const comment = std.fmt.bufPrint(&cbuf, "# {s}", .{e.what}) catch e.what;
        try text.row(w, exampleLabel(&buf, e), text.column(n), comment);
    }
}

fn exampleLabel(buf: []u8, e: spec.Example) []const u8 {
    return std.fmt.bufPrint(buf, "shotlet{s}{s}", .{ if (e.cmd.len > 0) " " else "", e.cmd }) catch e.cmd;
}
