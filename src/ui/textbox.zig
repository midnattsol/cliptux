//! Layout of a text annotation: hard paragraphs (split at newlines), each
//! wrapped to the box width when the box has a fixed width, with the
//! paragraph's direction (from its first strong character) shared by all
//! its visual lines; right-to-left paragraphs align to the right edge.
//! Maps carets to positions and back across wrapped lines, and implements
//! the line-wise caret motions (Up/Down, Home/End). Pure: no editor state.
//!
//! A caret offset at a soft line break is ambiguous (end of one visual
//! line, start of the next); `upstream` picks the end of the line above.

const std = @import("std");
const text = @import("../gfx/text.zig");
const bidi = @import("../gfx/bidi.zig");
const utf8 = @import("../gfx/utf8.zig");

pub const Point = struct { x: i32, y: i32 };

pub const Line = struct {
    /// bytes [start, end) of the line; `end` includes the spaces a soft
    /// line ends with and stops before a newline
    start: usize,
    end: usize,
    /// end of what is drawn and measured (trailing spaces of a soft line
    /// hang past the edge)
    vis_end: usize,
    /// direction of the paragraph the line belongs to
    rtl: bool,
    /// ends at a wrap rather than at a newline or the end of the text
    soft: bool,

    pub fn dir(self: Line) bidi.Direction {
        return if (self.rtl) .rtl else .ltr;
    }
};

/// A caret position with its affinity.
pub const Hit = struct { off: usize, upstream: bool = false };

/// Smallest fixed width, so a box never becomes a column of nothing.
pub fn minWidth(fs: f64) i32 {
    return @max(8, @as(i32, @intFromFloat(@round(fs * 0.8))));
}

/// Width of an auto-sized box at font size `fs`: its widest line, with
/// room for the caret when it is empty.
pub fn autoWidth(fs: f64, str: []const u8) i32 {
    var wmax: i32 = 0;
    var it = std.mem.splitScalar(u8, str, '\n');
    while (it.next()) |line| wmax = @max(wmax, text.width(fs, line));
    return @max(wmax, @as(i32, @intFromFloat(fs * 0.4)));
}

/// Direction of the paragraph `p` (first strong character; LTR if none).
pub fn paragraphRtl(p: []const u8) bool {
    var it = utf8.Iterator.init(p);
    while (it.next()) |cp| switch (bidi.class(cp)) {
        .L => return false,
        .R, .AL => return true,
        else => {},
    };
    return false;
}

/// Width and height of the laid-out box, without an allocator (for
/// geometry queries); a huge text that runs out of memory measures as
/// one line.
pub fn size(str: []const u8, fs: f64, box_w: i32) [2]i32 {
    var buf: [8192]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&buf, std.heap.page_allocator);
    const a = bfa.allocator();
    var l = Layout.init(a, str, fs, box_w) catch
        return .{ if (box_w > 0) @max(box_w, minWidth(fs)) else autoWidth(fs, str), text.height(fs) };
    defer l.deinit(a);
    return .{ l.w, l.height() };
}

pub const Layout = struct {
    lines: std.ArrayList(Line) = .empty,
    fs: f64,
    lh: i32,
    /// box width (fixed, or the widest line)
    w: i32,

    /// Lay out `str` at font size `fs` in a box `box_w` wide (0: as wide
    /// as its longest line, breaking only at newlines).
    pub fn init(alloc: std.mem.Allocator, str: []const u8, fs: f64, box_w: i32) !Layout {
        var self: Layout = .{ .fs = fs, .lh = text.height(fs), .w = 0 };
        errdefer self.lines.deinit(alloc);
        const fixed = box_w > 0;
        self.w = if (fixed) @max(box_w, minWidth(fs)) else autoWidth(fs, str);
        var start: usize = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, str, start, '\n') orelse str.len;
            const para = str[start..nl];
            const rtl = paragraphRtl(para);
            if (fixed) {
                var tmp: std.ArrayList(text.Line) = .empty;
                defer tmp.deinit(alloc);
                try text.wrapLines(alloc, fs, .regular, para, self.w, &tmp);
                try self.lines.ensureUnusedCapacity(alloc, tmp.items.len);
                for (tmp.items) |l| self.lines.appendAssumeCapacity(.{
                    .start = start + l.start,
                    .end = start + l.end,
                    .vis_end = start + l.vis_end,
                    .rtl = rtl,
                    .soft = true,
                });
                // the last line of a paragraph ends at the newline and
                // keeps its trailing spaces
                const last = &self.lines.items[self.lines.items.len - 1];
                last.soft = false;
                last.vis_end = last.end;
            } else {
                try self.lines.append(alloc, .{ .start = start, .end = nl, .vis_end = nl, .rtl = rtl, .soft = false });
            }
            if (nl == str.len) break;
            start = nl + 1;
        }
        return self;
    }

    pub fn deinit(self: *Layout, alloc: std.mem.Allocator) void {
        self.lines.deinit(alloc);
    }

    pub fn height(self: *const Layout) i32 {
        return @as(i32, @intCast(self.lines.items.len)) * self.lh;
    }

    pub fn visible(self: *const Layout, str: []const u8, i: usize) []const u8 {
        const l = self.lines.items[i];
        return str[l.start..l.vis_end];
    }

    /// Where line `i` starts inside a box `w` wide when drawn at font size
    /// `fs` (right-to-left paragraphs hug the right edge).
    pub fn indentAt(self: *const Layout, str: []const u8, i: usize, fs: f64, w: i32) i32 {
        const l = self.lines.items[i];
        if (!l.rtl) return 0;
        return @max(0, w - text.widthDir(fs, .regular, str[l.start..l.vis_end], .rtl));
    }

    pub fn indent(self: *const Layout, str: []const u8, i: usize) i32 {
        return self.indentAt(str, i, self.fs, self.w);
    }

    /// Visual line showing caret `h`.
    pub fn lineOf(self: *const Layout, h: Hit) usize {
        const lines = self.lines.items;
        for (lines, 0..) |l, i| {
            if (h.off > l.end) continue;
            if (h.off == l.end and l.soft and !h.upstream and i + 1 < lines.len) return i + 1;
            return i;
        }
        return lines.len - 1;
    }

    /// x of caret `off` on line `i`, from the box's left edge.
    fn xOn(self: *const Layout, str: []const u8, i: usize, off: usize) i32 {
        const l = self.lines.items[i];
        const vis = str[l.start..l.vis_end];
        const rel = std.math.clamp(off, l.start, l.vis_end) - l.start;
        return self.indent(str, i) + text.xForOffsetDir(self.fs, .regular, vis, rel, l.dir());
    }

    /// Top-left of the caret, relative to the box.
    pub fn caretPoint(self: *const Layout, str: []const u8, h: Hit) Point {
        const i = self.lineOf(h);
        return .{ .x = self.xOn(str, i, h.off), .y = @as(i32, @intCast(i)) * self.lh };
    }

    /// Caret nearest to `x` on line `i`.
    fn hitOn(self: *const Layout, str: []const u8, i: usize, x: i32) Hit {
        const l = self.lines.items[i];
        const vis = str[l.start..l.vis_end];
        const rel = text.offsetForXDir(self.fs, .regular, vis, x - self.indent(str, i), l.dir());
        const off = l.start + @min(rel, vis.len);
        return .{ .off = off, .upstream = off == l.end and l.soft };
    }

    /// Caret nearest to point (x, y) relative to the box.
    pub fn hit(self: *const Layout, str: []const u8, x: i32, y: i32) Hit {
        const n: i32 = @intCast(self.lines.items.len);
        const i = std.math.clamp(@divFloor(y, @max(1, self.lh)), 0, n - 1);
        return self.hitOn(str, @intCast(i), x);
    }

    pub fn home(self: *const Layout, h: Hit) Hit {
        return .{ .off = self.lines.items[self.lineOf(h)].start };
    }

    pub fn end(self: *const Layout, h: Hit) Hit {
        const l = self.lines.items[self.lineOf(h)];
        if (!l.soft) return .{ .off = l.end };
        // before the hanging spaces, or (a cut word) at the very end
        if (l.vis_end < l.end) return .{ .off = l.vis_end };
        return .{ .off = l.end, .upstream = true };
    }

    /// The caret one visual line up or down, keeping `goal_x`; past the
    /// first or last line it goes to the start or end of the text.
    pub fn vertical(self: *const Layout, str: []const u8, h: Hit, goal_x: i32, down: bool) Hit {
        const i = self.lineOf(h);
        if (!down and i == 0) return .{ .off = 0 };
        if (down and i + 1 >= self.lines.items.len) return .{ .off = str.len };
        return self.hitOn(str, if (down) i + 1 else i - 1, goal_x);
    }

    /// x of caret `h` (the goal kept across Up/Down).
    pub fn caretX(self: *const Layout, str: []const u8, h: Hit) i32 {
        return self.caretPoint(str, h).x;
    }
};

// --- tests ---

fn testLayout(str: []const u8, fs: f64, box_w: i32) !Layout {
    return Layout.init(std.testing.allocator, str, fs, box_w);
}

fn lineTexts(l: *const Layout, str: []const u8, buf: [][]const u8) [][]const u8 {
    for (l.lines.items, 0..) |ln, i| buf[i] = str[ln.start..ln.end];
    return buf[0..l.lines.items.len];
}

test "auto width breaks only at newlines" {
    text.init(std.testing.allocator);
    defer text.deinit();
    const s = "hello world\nsecond";
    var l = try testLayout(s, 20, 0);
    defer l.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), l.lines.items.len);
    try std.testing.expectEqual(autoWidth(20, s), l.w);
    try std.testing.expect(!l.lines.items[0].soft);
}

test "fixed width wraps; caret moves across wrapped lines" {
    const alloc = std.testing.allocator;
    text.init(alloc);
    defer text.deinit();
    const fs = 20.0;
    const s = "alpha beta gamma delta\nzeta";
    // room for about two words per line
    const w = @max(text.width(fs, "alpha beta"), text.width(fs, "gamma delta")) + 2;
    var l = try testLayout(s, fs, w);
    defer l.deinit(alloc);
    var buf: [8][]const u8 = undefined;
    const got = lineTexts(&l, s, &buf);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("alpha beta ", got[0]);
    try std.testing.expectEqualStrings("gamma delta", got[1]);
    try std.testing.expectEqualStrings("zeta", got[2]);
    try std.testing.expect(l.lines.items[0].soft and !l.lines.items[1].soft);
    for (l.lines.items, 0..) |_, i| try std.testing.expect(text.width(fs, l.visible(s, i)) <= w);
    // the offset at the wrap belongs to the next line, unless upstream
    try std.testing.expectEqual(@as(usize, 1), l.lineOf(.{ .off = 11 }));
    try std.testing.expectEqual(@as(usize, 0), l.lineOf(.{ .off = 11, .upstream = true }));
    try std.testing.expectEqual(@as(i32, 0), l.caretPoint(s, .{ .off = 11 }).x);
    try std.testing.expectEqual(l.lh, l.caretPoint(s, .{ .off = 11 }).y);
    // Home/End are per visual line; End stops before the hanging space
    try std.testing.expectEqual(@as(usize, 11), l.home(.{ .off = 14 }).off);
    try std.testing.expectEqual(@as(usize, 10), l.end(.{ .off = 2 }).off);
    try std.testing.expectEqual(@as(usize, 22), l.end(.{ .off = 14 }).off);
    // Down from "al|pha" lands near the same x on "gamma delta"
    const x2 = l.caretX(s, .{ .off = 2 });
    const d = l.vertical(s, .{ .off = 2 }, x2, true);
    try std.testing.expect(d.off >= 11 and d.off <= 14);
    try std.testing.expectEqual(@as(usize, 1), l.lineOf(d));
    // and down again to the next paragraph, then past the end
    const d2 = l.vertical(s, d, x2, true);
    try std.testing.expectEqual(@as(usize, 2), l.lineOf(d2));
    try std.testing.expectEqual(s.len, l.vertical(s, d2, x2, true).off);
    try std.testing.expectEqual(@as(usize, 0), l.vertical(s, .{ .off = 3 }, 0, false).off);
    // clicks: below the last line clamps to it; right of a line ends it
    try std.testing.expectEqual(s.len, l.hit(s, 10000, 10000).off);
    try std.testing.expectEqual(@as(usize, 10), l.hit(s, w + 50, 1).off);
    try std.testing.expectEqual(@as(usize, 23), l.hit(s, -5, 2 * l.lh + 1).off);
}

test "a cut word: End and clicks past it keep the caret upstream" {
    const alloc = std.testing.allocator;
    text.init(alloc);
    defer text.deinit();
    const fs = 20.0;
    const s = "abcdefghijklmnop";
    var l = try testLayout(s, fs, text.width(fs, "abcdef") + 1);
    defer l.deinit(alloc);
    try std.testing.expect(l.lines.items.len >= 2);
    const first = l.lines.items[0];
    try std.testing.expectEqual(first.end, first.vis_end);
    const e = l.end(.{ .off = 1 });
    try std.testing.expect(e.upstream);
    try std.testing.expectEqual(@as(usize, 0), l.lineOf(e));
    const h = l.hit(s, 10000, 1);
    try std.testing.expect(h.upstream);
    try std.testing.expectEqual(first.end, h.off);
    try std.testing.expect(l.caretPoint(s, h).x > 0);
}

test "rtl paragraphs wrap with one direction, right-aligned" {
    const alloc = std.testing.allocator;
    text.init(alloc);
    defer text.deinit();
    const fs = 20.0;
    // Hebrew paragraph with an English word, then an English paragraph
    const s = "\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD} hello \u{5D2}\u{5D3}\u{5D5}\u{5DC}\nplain english";
    const w = text.width(fs, "\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD}") + 4;
    var l = try testLayout(s, fs, w);
    defer l.deinit(alloc);
    const lines = l.lines.items;
    try std.testing.expect(lines.len >= 3);
    // every line of the first paragraph is RTL, including one starting
    // with the English word
    var k: usize = 0;
    while (k < lines.len and lines[k].start < std.mem.indexOfScalar(u8, s, '\n').?) : (k += 1) {
        try std.testing.expect(lines[k].rtl);
        const ind = l.indent(s, k);
        try std.testing.expect(ind >= 0);
        // right-aligned: ends at the box's right edge
        try std.testing.expect(@abs(ind + text.widthDir(fs, .regular, l.visible(s, k), .rtl) - l.w) <= 1);
    }
    try std.testing.expect(!lines[lines.len - 1].rtl);
    try std.testing.expectEqual(@as(i32, 0), l.indent(s, lines.len - 1));
    // the caret at the start of the paragraph is at the right edge
    try std.testing.expect(@abs(l.caretPoint(s, .{ .off = 0 }).x - l.w) <= 1);
    // clicking at the right edge of the first line starts the text
    try std.testing.expectEqual(@as(usize, 0), l.hit(s, l.w - 1, 1).off);
    // round trip on every caret position of the first line
    var off = lines[0].start;
    while (off < lines[0].vis_end) : (off = nextChar(s, off)) {
        const p = l.caretPoint(s, .{ .off = off });
        try std.testing.expectEqual(off, l.hit(s, p.x, p.y + 1).off);
    }
}

fn nextChar(s: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < s.len and s[j] & 0xC0 == 0x80) j += 1;
    return j;
}
