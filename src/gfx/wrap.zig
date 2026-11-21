//! Line breaking for fixed-width text boxes: a small subset of UAX #14.
//! Break opportunities are after spaces, after hyphens and dashes (not in
//! front of a number), after a zero-width space, and around CJK
//! ideographs and kana. A word wider than the line breaks between
//! characters, never inside a grapheme (a letter and its combining marks,
//! ZWJ sequences, variation selectors). Pure: widths come from a callback.

const std = @import("std");
const utf8 = @import("utf8.zig");
const bidi = @import("bidi.zig");

/// One visual line of a paragraph: bytes [start, end) of it, where `end`
/// includes the spaces it ends with; `vis_end` excludes them (they hang
/// past the edge and are neither drawn nor measured).
pub const Line = struct {
    start: usize,
    end: usize,
    vis_end: usize,
};

fn decode(s: []const u8, i: usize) struct { u21, usize } {
    var it = utf8.Iterator.init(s);
    it.i = i;
    const cp = it.next() orelse return .{ 0, s.len };
    return .{ cp, it.i };
}

/// Start of the character that ends at byte `i`.
fn prevStart(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (s[j] & 0xC0 != 0x80) break;
    }
    return j;
}

fn decodeBefore(s: []const u8, i: usize) u21 {
    return decode(s, prevStart(s, i))[0];
}

pub fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == 0x3000 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A and cp != 0x2007) or cp == 0x205F;
}

/// Characters that attach to the one before: no break in front of them.
fn extends(cp: u21) bool {
    return cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF) or
        (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0020 and cp <= 0xE007F) or
        (cp >= 0x0300 and bidi.class(cp) == .NSM);
}

/// Ideographs, kana and hangul: a line may break before and after each.
fn ideographic(cp: u21) bool {
    return (cp >= 0x2E80 and cp <= 0x2FFF) or (cp >= 0x3040 and cp <= 0x30FF and cp != 0x30FC) or
        (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFF);
}

/// Closing punctuation that must stay on the line of what it closes.
fn noBreakBefore(cp: u21) bool {
    return switch (cp) {
        ')', ']', '}', '!', '?', ',', '.', ':', ';', 0x3001, 0x3002, 0x300D, 0x300F, 0x3011, 0x30FC, 0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0x2019, 0x201D, 0xBB => true,
        else => false,
    };
}

fn hyphen(cp: u21) bool {
    return cp == '-' or cp == 0x2010 or cp == 0x2012 or cp == 0x2013 or cp == 0x2014 or cp == 0x058A or cp == 0x05BE;
}

fn isDigit(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 0x0660 and cp <= 0x0669) or (cp >= 0x06F0 and cp <= 0x06F9);
}

/// Whether a line may break at byte `i` (between the character ending
/// there and the one starting there), ignoring spaces, which the caller
/// handles.
fn canBreakAt(s: []const u8, i: usize) bool {
    if (i == 0 or i >= s.len) return false;
    const before = decodeBefore(s, i);
    const after = decode(s, i)[0];
    if (extends(after) or before == 0x200D or isSpace(after)) return false;
    if (isSpace(before) or before == 0x200B) return true;
    if (noBreakBefore(after) or hyphen(after)) return false;
    if (hyphen(before)) {
        // "well-known" breaks after the hyphen; "-5" and " -x" do not
        if (isDigit(after)) return false;
        const ib = prevStart(s, i);
        if (ib == 0) return false;
        const b2 = decodeBefore(s, ib);
        return !isSpace(b2);
    }
    return ideographic(before) or ideographic(after);
}

/// Next grapheme boundary after byte `i` (a character plus anything that
/// extends it).
pub fn nextGrapheme(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var cp, var j = decode(s, i);
    while (j < s.len) {
        const nx, const k = decode(s, j);
        if (!(extends(nx) or cp == 0x200D)) break;
        cp = nx;
        j = k;
    }
    return j;
}

fn trimSpaces(s: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start) {
        const cp = decodeBefore(s, e);
        if (!isSpace(cp)) break;
        e = prevStart(s, e);
    }
    return e;
}

/// Break paragraph `s` (no newlines) into lines no wider than `max_w`
/// where possible, measuring with `measure(ctx, s[a..b])`. Appends to
/// `out`; an empty paragraph gives one empty line.
pub fn wrap(
    alloc: std.mem.Allocator,
    s: []const u8,
    max_w: f64,
    ctx: anytype,
    comptime measure: fn (@TypeOf(ctx), []const u8) f64,
    out: *std.ArrayList(Line),
) !void {
    if (s.len == 0) return out.append(alloc, .{ .start = 0, .end = 0, .vis_end = 0 });
    var start: usize = 0;
    // end of a word too wide for a line, being cut into pieces
    var long_end: ?usize = null;
    outer: while (start < s.len) {
        if (long_end) |le| {
            if (start < le) {
                const vis_le = trimSpaces(s, start, le);
                const cut = fitGraphemes(s, start, vis_le, max_w, ctx, measure);
                if (cut < vis_le) {
                    try out.append(alloc, .{ .start = start, .end = cut, .vis_end = cut });
                    start = cut;
                    continue;
                }
            }
            long_end = null;
        }
        var last_fit: ?usize = null;
        var i = start;
        while (i < s.len) {
            // the next break opportunity, with the spaces after it
            var e = nextGrapheme(s, i);
            while (e < s.len and !canBreakAt(s, e)) e = nextGrapheme(s, e);
            while (e < s.len and isSpace(decode(s, e)[0])) e = decode(s, e)[1];
            const vis = trimSpaces(s, start, e);
            if (vis == start or measure(ctx, s[start..vis]) <= max_w) {
                last_fit = e;
                i = e;
                continue;
            }
            if (last_fit) |lf| {
                try out.append(alloc, .{ .start = start, .end = lf, .vis_end = trimSpaces(s, start, lf) });
                start = lf;
            } else {
                // one word wider than the line: as many graphemes as fit
                const cut = fitGraphemes(s, start, vis, max_w, ctx, measure);
                try out.append(alloc, .{ .start = start, .end = cut, .vis_end = cut });
                start = cut;
                long_end = e;
            }
            continue :outer;
        }
        try out.append(alloc, .{ .start = start, .end = s.len, .vis_end = trimSpaces(s, start, s.len) });
        break;
    }
}

fn advanceGraphemes(s: []const u8, from: usize, n: usize, limit: usize) usize {
    var e = from;
    var k: usize = 0;
    while (k < n and e < limit) : (k += 1) e = nextGrapheme(s, e);
    return e;
}

/// End of the longest run of whole graphemes from `start` (at least one)
/// that fits in `max_w`, not past `limit`. Grows a window geometrically,
/// then bisects it, so the work is bounded by the line, not the word.
fn fitGraphemes(s: []const u8, start: usize, limit: usize, max_w: f64, ctx: anytype, comptime measure: fn (@TypeOf(ctx), []const u8) f64) usize {
    var lo = nextGrapheme(s, start);
    var count: usize = 8;
    while (lo < limit) {
        const e = advanceGraphemes(s, lo, count, limit);
        if (measure(ctx, s[start..e]) <= max_w) {
            lo = e;
            count *= 2;
            continue;
        }
        // lo fits (or is the one-grapheme minimum), e does not
        var lo_n: usize = 0;
        var hi_n: usize = count;
        while (hi_n - lo_n > 1) {
            const mid = (lo_n + hi_n) / 2;
            const p = advanceGraphemes(s, lo, mid, limit);
            if (measure(ctx, s[start..p]) <= max_w) lo_n = mid else hi_n = mid;
        }
        return advanceGraphemes(s, lo, lo_n, limit);
    }
    return @min(lo, @max(limit, nextGrapheme(s, start)));
}

// --- tests ---

/// Every codepoint is 10 px wide, marks and ZWJ 0.
fn mono(_: void, s: []const u8) f64 {
    var it = utf8.Iterator.init(s);
    var w: f64 = 0;
    while (it.next()) |cp| w += if (extends(cp)) 0 else 10;
    return w;
}

fn expectLines(s: []const u8, max_w: f64, expected: []const []const u8) !void {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(Line) = .empty;
    defer out.deinit(alloc);
    try wrap(alloc, s, max_w, {}, mono, &out);
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(alloc);
    for (out.items) |l| try got.append(alloc, s[l.start..l.end]);
    std.testing.expectEqual(expected.len, got.items.len) catch |e| {
        for (got.items) |g| std.debug.print("line: '{s}'\n", .{g});
        return e;
    };
    for (expected, got.items) |a, b| try std.testing.expectEqualStrings(a, b);
    // lines tile the paragraph
    var at: usize = 0;
    for (out.items) |l| {
        try std.testing.expectEqual(at, l.start);
        try std.testing.expect(l.vis_end >= l.start and l.vis_end <= l.end);
        at = l.end;
    }
    try std.testing.expectEqual(s.len, at);
}

test "wrap at spaces, trailing spaces hang" {
    try expectLines("hello big world", 100, &.{ "hello big ", "world" });
    try expectLines("hello big world", 90, &.{ "hello big ", "world" });
    try expectLines("hello big world", 80, &.{ "hello ", "big ", "world" });
    try expectLines("hello big world", 50, &.{ "hello ", "big ", "world" });
    try expectLines("hello big world", 1000, &.{"hello big world"});
    try expectLines("a  b", 10, &.{ "a  ", "b" });
    try expectLines("", 50, &.{""});
    try expectLines("   ", 10, &.{"   "});
}

test "wrap after hyphens, not before numbers" {
    try expectLines("well-known fact", 60, &.{ "well-", "known ", "fact" });
    try expectLines("x -5 y", 30, &.{ "x ", "-5 ", "y" });
    try expectLines("a--b", 30, &.{ "a--", "b" });
}

test "long words break between graphemes" {
    try expectLines("abcdefghij", 40, &.{ "abcd", "efgh", "ij" });
    // a letter and its combining mark stay together
    try expectLines("ab\u{301}cd", 20, &.{ "ab\u{301}", "cd" });
    // too narrow for even one character: one per line
    try expectLines("abc", 1, &.{ "a", "b", "c" });
    // a family emoji (ZWJ sequence) is one grapheme
    try expectLines("\u{1F468}\u{200D}\u{1F469}x", 15, &.{ "\u{1F468}\u{200D}\u{1F469}", "x" });
    // a huge word is cut quickly and exactly
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, 20000);
    defer alloc.free(big);
    @memset(big, 'x');
    var out: std.ArrayList(Line) = .empty;
    defer out.deinit(alloc);
    try wrap(alloc, big, 105, {}, mono, &out);
    try std.testing.expectEqual(@as(usize, 2000), out.items.len);
    for (out.items) |l| try std.testing.expectEqual(@as(usize, 10), l.end - l.start);
}

test "CJK breaks between ideographs but not before closing punctuation" {
    try expectLines("漢字漢字。", 25, &.{ "漢字", "漢", "字。" });
    try expectLines("ab漢字", 25, &.{ "ab", "漢字" });
}

test "rtl paragraphs wrap in logical order" {
    // שלום עולם גדול: break at the spaces, logical order
    try expectLines("\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD} \u{5D2}\u{5D3}", 90, &.{ "\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD} ", "\u{5D2}\u{5D3}" });
}
