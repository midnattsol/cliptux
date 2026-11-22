//! The man page, shotlet(1), in roff from the command table:
//! `shotlet man-page`, which `zig build man` and install.sh run.

const std = @import("std");
const spec = @import("spec.zig");
const commands = @import("commands.zig");
const help = @import("help.zig");
const W = *std.Io.Writer;

pub fn write(w: W) !void {
    try w.print(".TH SHOTLET 1 \"\" \"shotlet {s}\" \"User Commands\"\n", .{commands.version});
    try w.writeAll(".SH NAME\nshotlet \\- ");
    try text(w, commands.tagline);
    try w.writeAll("\n.SH SYNOPSIS\n.B shotlet\n.RI [ COMMAND ]\n.RI [ OPTIONS ]\n");
    try w.writeAll(".SH DESCRIPTION\n");
    try text(w, "Shotlet captures the screen on Wayland, opens an annotation editor and copies " ++
        "or saves the result; it also records the screen as MP4 or GIF. Without a command it " ++
        "captures an area. Every command takes --help.");
    try w.writeAll("\n.SH OPTIONS\n");
    try optionItem(w, .{ .long = "help", .short = 'h', .help = "Show the overview, or a command's help after it" });
    try optionItem(w, .{ .long = "version", .short = 'V', .help = "Show the version" });
    for (help.groups) |g| {
        try w.writeAll(".SH \"");
        try upper(w, g.title());
        try w.writeAll(" COMMANDS\"\n");
        for (&commands.all) |*c| if (c.group == g) try command(w, c, "shotlet");
    }
    try w.writeAll(files);
}

const files =
    \\.SH FILES
    \\.TP
    \\.I $XDG_CONFIG_HOME/shotlet/config
    \\The settings (shotlet settings edits them).
    \\.TP
    \\.I $XDG_STATE_HOME/shotlet/history
    \\The recent captures.
    \\.SH ENVIRONMENT
    \\.TP
    \\.B NO_COLOR
    \\Set: no bold headings in the help.
    \\.SH "SEE ALSO"
    \\The README, at https://github.com/midnattsol/shotlet
    \\
;

fn command(w: W, c: *const spec.Command, parent: []const u8) !void {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} {s}", .{ parent, c.name }) catch c.name;
    try w.writeAll(".SS \"");
    try text(w, if (c == commands.default) "shotlet, shotlet shot" else name);
    try w.writeAll("\"\n.nf\n");
    for (c.usage) |u| {
        try w.writeAll("\\fBshotlet\\fR");
        if (u.len > 0) try w.writeAll(" ");
        try text(w, u);
        try w.writeAll("\n");
    }
    try w.writeAll(".fi\n.PP\n");
    try text(w, if (c.description.len > 0) c.description else c.summary);
    try w.writeAll("\n");
    for (c.args) |a| if (!a.hidden) try item(w, "\\fI", a.name, a.help);
    for (c.options) |o| if (o.vis != .hidden) try optionItem(w, o);
    try examples(w, c);
    for (c.subs) |*s| try command(w, s, name);
}

fn item(w: W, font: []const u8, label: []const u8, help_text: []const u8) !void {
    try w.print(".TP\n{s}", .{font});
    try text(w, label);
    try w.writeAll("\\fR\n");
    try text(w, help_text);
    try w.writeAll("\n");
}

fn optionItem(w: W, o: spec.Option) !void {
    try w.writeAll(".TP\n");
    if (o.short) |s| try w.print("\\fB\\-{c}\\fR, ", .{s});
    try w.writeAll("\\fB\\-\\-");
    try text(w, o.long);
    try w.writeAll("\\fR");
    if (o.value) |v| {
        try w.writeAll(" \\fI");
        try text(w, v);
        try w.writeAll("\\fR");
    }
    try w.writeAll("\n");
    try text(w, o.help);
    if (o.vis == .dev) try w.writeAll(" (for testing)");
    try w.writeAll("\n");
}

fn examples(w: W, c: *const spec.Command) !void {
    try w.writeAll(".PP\nExamples:\n.RS\n.nf\n");
    for (c.examples) |e| {
        try w.writeAll("shotlet");
        if (e.cmd.len > 0) try w.writeAll(" ");
        try text(w, e.cmd);
        try w.writeAll("    # ");
        try text(w, e.what);
        try w.writeAll("\n");
    }
    try w.writeAll(".fi\n.RE\n");
}

/// `s` escaped for roff: backslashes, hyphens (minus signs in options),
/// and a leading dot or quote that would read as a request.
fn text(w: W, s: []const u8) !void {
    if (s.len > 0 and (s[0] == '.' or s[0] == '\'')) try w.writeAll("\\&");
    for (s) |ch| switch (ch) {
        '\\' => try w.writeAll("\\e"),
        '-' => try w.writeAll("\\-"),
        '\n' => try w.writeAll(" "),
        else => try w.writeByte(ch),
    };
}

fn upper(w: W, s: []const u8) !void {
    for (s) |ch| try w.writeByte(std.ascii.toUpper(ch));
}
