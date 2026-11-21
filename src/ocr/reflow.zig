//! Recognised words back into text a person would paste: lines that only
//! wrapped (they reach their column's right edge and the next one starts
//! at its left) join into one paragraph, words broken by a hyphen are
//! joined again, paragraphs and columns (Tesseract's blocks) are kept
//! apart by a blank line, and lists, code and short lines keep their
//! line breaks.

const std = @import("std");
const page_mod = @import("page.zig");
const Rect = @import("../ui/shapes.zig").Rect;
const Word = page_mod.Word;

const Line = struct {
    block: u32,
    box: Rect,
    /// the line's words in `words`
    first: usize,
    end: usize,

    fn chars(self: Line, words: []const Word) usize {
        var n: usize = 0;
        for (words[self.first..self.end]) |w| n += std.unicode.utf8CountCodepoints(w.text) catch w.text.len;
        return n + (self.end - self.first) -| 1;
    }
};

/// Words grouped into lines, in Tesseract's reading order.
fn groupLines(alloc: std.mem.Allocator, words: []const Word) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(alloc);
    var i: usize = 0;
    while (i < words.len) {
        var j = i + 1;
        var box = words[i].box;
        while (j < words.len and words[j].block == words[i].block and words[j].par == words[i].par and words[j].line == words[i].line) : (j += 1) {
            box = Rect.unite(box, words[j].box);
        }
        try lines.append(alloc, .{ .block = words[i].block, .box = box, .first = i, .end = j });
        i = j;
    }
    return lines;
}

/// The text of `words` (owned).
pub fn reflow(alloc: std.mem.Allocator, words: []const Word) ![]u8 {
    var lines = try groupLines(alloc, words);
    defer lines.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var b: usize = 0;
    while (b < lines.items.len) {
        var e = b + 1;
        while (e < lines.items.len and lines.items[e].block == lines.items[b].block) e += 1;
        if (b > 0) try out.appendSlice(alloc, "\n\n");
        try writeBlock(alloc, &out, words, lines.items[b..e]);
        b = e;
    }
    return out.toOwnedSlice(alloc);
}

fn writeBlock(alloc: std.mem.Allocator, out: *std.ArrayList(u8), words: []const Word, lines: []const Line) !void {
    var left: i32 = std.math.maxInt(i32);
    var right: i32 = std.math.minInt(i32);
    var heights: i64 = 0;
    for (lines) |l| {
        left = @min(left, l.box.x);
        right = @max(right, l.box.right());
        heights += l.box.h;
    }
    const lh: i32 = @intCast(@divTrunc(heights, @as(i64, @intCast(lines.len))));
    for (lines, 0..) |l, k| {
        if (k > 0) {
            const prev = lines[k - 1];
            const sep = separator(prev, l, words, left, right, lh);
            const hyphen = sep == .join and endsWithHyphen(words[prev.end - 1].text) and startsLower(words[l.first].text);
            if (hyphen) {
                out.items.len -= 1; // the hyphen
            } else try out.appendSlice(alloc, switch (sep) {
                .join => " ",
                .newline => "\n",
                .paragraph => "\n\n",
            });
        }
        for (words[l.first..l.end], 0..) |w, i| {
            if (i > 0) try out.append(alloc, ' ');
            try out.appendSlice(alloc, w.text);
        }
    }
}

const Sep = enum { join, newline, paragraph };

fn separator(prev: Line, cur: Line, words: []const Word, left: i32, right: i32, lh: i32) Sep {
    const gap = cur.box.y - prev.box.bottom();
    if (gap > @divTrunc(lh * 3, 4)) return .paragraph;
    // the width of a character, from the previous line's own text
    const cw: i32 = @max(4, @divTrunc(prev.box.w, @as(i32, @intCast(@max(1, prev.chars(words))))));
    const prev_full = prev.box.right() >= right - @max(3 * cw, @divTrunc(right - left, 8));
    const cur_at_left = cur.box.x <= left + 2 * cw;
    const prev_ends_sentence_short = !prev_full;
    if (prev_ends_sentence_short or !cur_at_left) return .newline;
    if (isListItem(words[cur.first].text)) return .newline;
    // a full line ending a sentence still flows on (a wrapped paragraph)
    return .join;
}

fn endsWithHyphen(s: []const u8) bool {
    return s.len >= 2 and s[s.len - 1] == '-' and std.ascii.isAlphabetic(s[s.len - 2]);
}

fn startsLower(s: []const u8) bool {
    return s.len > 0 and std.ascii.isLower(s[0]);
}

/// "-", "*", "•", "1.", "2)", "a)" start list items.
fn isListItem(s: []const u8) bool {
    if (std.mem.eql(u8, s, "-") or std.mem.eql(u8, s, "*") or std.mem.startsWith(u8, s, "\u{2022}")) return true;
    if (s.len >= 2 and s.len <= 4 and (s[s.len - 1] == '.' or s[s.len - 1] == ')')) {
        for (s[0 .. s.len - 1]) |c| if (!std.ascii.isDigit(c) and !(s.len == 2 and std.ascii.isLower(c))) return false;
        return true;
    }
    return false;
}

const testing = std.testing;

/// Words of a fake page: each line a string, laid out like a monospace
/// screen font (8 px a character, 20 px lines), starting at `x`.
const Fake = struct {
    words: std.ArrayList(Word) = .empty,

    fn line(self: *Fake, block: u32, x: i32, y: i32, text: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        var cx = x;
        var off: usize = 0;
        while (it.next()) |w| {
            const at = @as(i32, @intCast(std.mem.indexOfPos(u8, text, off, w).?));
            off = @intCast(at + @as(i32, @intCast(w.len)));
            cx = x + at * 8;
            try self.words.append(testing.allocator, .{ .block = block, .par = 1, .line = @intCast(y), .box = .{ .x = cx, .y = y, .w = @intCast(w.len * 8), .h = 14 }, .conf = 90, .text = w });
        }
    }
};

fn expectReflow(f: *Fake, want: []const u8) !void {
    defer f.words.deinit(testing.allocator);
    const got = try reflow(testing.allocator, f.words.items);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "wrapped lines join, short ones keep their break" {
    var f: Fake = .{};
    try f.line(1, 10, 10, "The quick brown fox jumps over the");
    try f.line(1, 10, 30, "lazy dog and keeps on running away");
    try f.line(1, 10, 50, "until it stops.");
    try f.line(1, 10, 70, "Short line.");
    try expectReflow(&f, "The quick brown fox jumps over the lazy dog and keeps on running away until it stops.\nShort line.");
}

test "a gap starts a paragraph, a block another column" {
    var f: Fake = .{};
    try f.line(1, 10, 10, "First paragraph that is long enough");
    try f.line(1, 10, 30, "to wrap.");
    try f.line(1, 10, 70, "Second paragraph.");
    try f.line(2, 400, 10, "Right column text");
    try expectReflow(&f, "First paragraph that is long enough to wrap.\n\nSecond paragraph.\n\nRight column text");
}

test "hyphenated words are joined, lists keep their items" {
    var f: Fake = .{};
    try f.line(1, 10, 10, "A sentence with a long hyphen-");
    try f.line(1, 10, 30, "ated word inside of it, so");
    try f.line(1, 10, 50, "- first item that is long enough");
    try f.line(1, 10, 70, "- second item");
    try expectReflow(&f, "A sentence with a long hyphenated word inside of it, so\n- first item that is long enough\n- second item");
}

test "indented lines (code) keep their breaks" {
    var f: Fake = .{};
    try f.line(1, 10, 10, "fn main() void {");
    try f.line(1, 42, 30, "return;");
    try f.line(1, 10, 50, "}");
    try expectReflow(&f, "fn main() void {\nreturn;\n}");
}

test "list markers" {
    try testing.expect(isListItem("1."));
    try testing.expect(isListItem("12)"));
    try testing.expect(isListItem("a)"));
    try testing.expect(isListItem("\u{2022}"));
    try testing.expect(!isListItem("ok."));
    try testing.expect(!isListItem("end."));
}
