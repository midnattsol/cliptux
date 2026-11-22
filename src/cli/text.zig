//! Plain-text layout for the help: headings and text wrapped in columns.

const std = @import("std");

pub const width = 80;

pub const Style = struct {
    /// bold headings (a terminal, NO_COLOR unset)
    bold: bool = false,

    pub fn heading(s: Style, w: *std.Io.Writer, title: []const u8) !void {
        if (s.bold) {
            try w.print("\x1b[1m{s}:\x1b[0m\n", .{title});
        } else try w.print("{s}:\n", .{title});
    }
};

/// Writes `text` from column `col` (where the cursor is), wrapping at
/// `width` with continuation lines indented to `indent`; ends the line.
pub fn wrap(w: *std.Io.Writer, text: []const u8, col: usize, indent: usize) !void {
    var at = col;
    var first = true;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (!first and at + 1 + word.len > width) {
            try w.writeAll("\n");
            try w.splatByteAll(' ', indent);
            at = indent;
        } else if (!first) {
            try w.writeAll(" ");
            at += 1;
        }
        try w.writeAll(word);
        at += word.len;
        first = false;
    }
    try w.writeAll("\n");
}

/// "  LABEL   text...": the label padded to `col` (the caller makes it
/// wide enough for every label of the section), then the text, wrapped
/// with a hanging indent under its first word.
pub fn row(w: *std.Io.Writer, label: []const u8, col: usize, text: []const u8) !void {
    try w.print("  {s}", .{label});
    try w.splatByteAll(' ', col -| (2 + label.len));
    try wrap(w, text, @max(col, 2 + label.len), col);
}

/// The column a section's text starts at: its longest label, indented
/// by 2 and followed by a 2-space gap.
pub fn column(longest_label: usize) usize {
    return 2 + longest_label + 2;
}

test "wrap at the width with an indent" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const long = "word word word word word word word word word word word word word word word word word";
    try row(&buf.writer, "name", 10, long);
    var lines = std.mem.splitScalar(u8, buf.written(), '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "  name    word word"));
    while (lines.next()) |l| {
        try std.testing.expect(l.len <= width);
        if (l.len > 0) try std.testing.expect(std.mem.startsWith(u8, l, "          word"));
    }
}
