//! Caret editing over a UTF-8 byte buffer: insertion, deletion and caret
//! movement by character, word and line. Pure; no rendering.

const std = @import("std");

pub const TextEdit = struct {
    /// byte offset of the caret, always on a character boundary
    caret: usize = 0,

    /// Insert typed or pasted text at the caret. Control characters are
    /// dropped except newlines; CRLF becomes LF.
    pub fn insert(self: *TextEdit, alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '\r') {
                if (i + 1 < s.len and s[i + 1] == '\n') continue;
                try buf.insert(alloc, self.caret, '\n');
            } else if (c == '\t') {
                try buf.insert(alloc, self.caret, ' ');
            } else if (c < 0x20 and c != '\n' or c == 0x7F) {
                continue;
            } else {
                try buf.insert(alloc, self.caret, c);
            }
            self.caret += 1;
        }
    }

    pub fn backspace(self: *TextEdit, buf: *std.ArrayList(u8)) void {
        if (self.caret == 0) return;
        const start = prevBoundary(buf.items, self.caret);
        buf.replaceRangeAssumeCapacity(start, self.caret - start, &.{});
        self.caret = start;
    }

    pub fn delete(self: *TextEdit, buf: *std.ArrayList(u8)) void {
        if (self.caret >= buf.items.len) return;
        const stop = nextBoundary(buf.items, self.caret);
        buf.replaceRangeAssumeCapacity(self.caret, stop - self.caret, &.{});
    }

    /// Delete back to the start of the previous word (Ctrl+Backspace).
    pub fn backspaceWord(self: *TextEdit, buf: *std.ArrayList(u8)) void {
        const start = wordLeftOf(buf.items, self.caret);
        buf.replaceRangeAssumeCapacity(start, self.caret - start, &.{});
        self.caret = start;
    }

    pub fn left(self: *TextEdit, s: []const u8) void {
        self.caret = prevBoundary(s, self.caret);
    }
    pub fn right(self: *TextEdit, s: []const u8) void {
        self.caret = nextBoundary(s, self.caret);
    }
    pub fn wordLeft(self: *TextEdit, s: []const u8) void {
        self.caret = wordLeftOf(s, self.caret);
    }
    pub fn wordRight(self: *TextEdit, s: []const u8) void {
        var i = self.caret;
        while (i < s.len and isSpace(s[i])) i += 1;
        while (i < s.len and !isSpace(s[i])) i += 1;
        self.caret = i;
    }
    pub fn home(self: *TextEdit, s: []const u8) void {
        self.caret = lineStart(s, self.caret);
    }
    pub fn end(self: *TextEdit, s: []const u8) void {
        self.caret = lineEnd(s, self.caret);
    }
    pub fn up(self: *TextEdit, s: []const u8) void {
        const ls = lineStart(s, self.caret);
        if (ls == 0) {
            self.caret = 0;
            return;
        }
        const col = charsBetween(s, ls, self.caret);
        const prev = lineStart(s, ls - 1);
        self.caret = advanceChars(s, prev, col, ls - 1);
    }
    pub fn down(self: *TextEdit, s: []const u8) void {
        const le = lineEnd(s, self.caret);
        if (le >= s.len) {
            self.caret = s.len;
            return;
        }
        const col = charsBetween(s, lineStart(s, self.caret), self.caret);
        self.caret = advanceChars(s, le + 1, col, lineEnd(s, le + 1));
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n';
}

fn wordLeftOf(s: []const u8, from: usize) usize {
    var i = from;
    while (i > 0 and isSpace(s[i - 1])) i -= 1;
    while (i > 0 and !isSpace(s[i - 1])) i -= 1;
    return i;
}

pub fn prevBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
    return j;
}

pub fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
    return j;
}

pub fn lineStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

pub fn lineEnd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

fn charsBetween(s: []const u8, a: usize, b: usize) usize {
    var n: usize = 0;
    var i = a;
    while (i < b) : (i = nextBoundary(s, i)) n += 1;
    return n;
}

fn advanceChars(s: []const u8, from: usize, n: usize, limit: usize) usize {
    var i = from;
    var k: usize = 0;
    while (k < n and i < limit) : (k += 1) i = nextBoundary(s, i);
    return i;
}

test "insert, backspace and delete are UTF-8 aware" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var te: TextEdit = .{};
    try te.insert(alloc, &buf, "año");
    try std.testing.expectEqualStrings("año", buf.items);
    try std.testing.expectEqual(@as(usize, 4), te.caret);
    te.left(buf.items);
    te.left(buf.items);
    try std.testing.expectEqual(@as(usize, 1), te.caret);
    te.delete(&buf);
    try std.testing.expectEqualStrings("ao", buf.items);
    try te.insert(alloc, &buf, "ñ");
    te.backspace(&buf);
    te.backspace(&buf);
    try std.testing.expectEqualStrings("o", buf.items);
    try std.testing.expectEqual(@as(usize, 0), te.caret);
    te.backspace(&buf); // at start: no-op
    te.end(buf.items);
    te.delete(&buf); // at end: no-op
    try std.testing.expectEqualStrings("o", buf.items);
}

test "control characters are filtered, CRLF normalised" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var te: TextEdit = .{};
    try te.insert(alloc, &buf, "a\r\nb\x07\tc\rd");
    try std.testing.expectEqualStrings("a\nb c\nd", buf.items);
}

test "word and line movement" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var te: TextEdit = .{};
    try te.insert(alloc, &buf, "hello big world\nsecond line\nxy");
    const s = buf.items;
    te.caret = 0;
    te.wordRight(s);
    try std.testing.expectEqual(@as(usize, 5), te.caret);
    te.wordRight(s);
    try std.testing.expectEqual(@as(usize, 9), te.caret);
    te.wordLeft(s);
    try std.testing.expectEqual(@as(usize, 6), te.caret);
    // down keeps the column; clamps on a short line
    te.down(s);
    try std.testing.expectEqual(@as(usize, 16 + 6), te.caret);
    te.down(s);
    try std.testing.expectEqual(s.len, te.caret); // "xy" is shorter
    te.up(s);
    try std.testing.expectEqual(@as(usize, 16 + 2), te.caret);
    te.home(s);
    try std.testing.expectEqual(@as(usize, 16), te.caret);
    te.end(s);
    try std.testing.expectEqual(@as(usize, 27), te.caret);
    te.up(s);
    te.up(s);
    te.up(s);
    try std.testing.expectEqual(@as(usize, 0), te.caret);
    te.caret = 15;
    te.backspaceWord(&buf);
    try std.testing.expectEqualStrings("hello big \nsecond line\nxy", buf.items);
}
