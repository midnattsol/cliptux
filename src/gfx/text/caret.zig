//! Caret and selection geometry: byte offset <-> pixel x on a laid-out
//! line, and where a byte range is drawn. Works in visual order, so
//! right-to-left and mixed text map correctly.

const std = @import("std");
const ttf = @import("../ttf.zig");
const utf8 = @import("../utf8.zig");
const bidi = @import("../bidi.zig");
const render = @import("../render.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const shape = @import("shape.zig");

const Canvas = render.Canvas;
const Style = state_mod.Style;
const Item = layout.Item;
const bitmapScale = state_mod.bitmapScale;

/// The run of items around `k` drawing the same characters (a cluster:
/// a ligature, a letter and its marks, a multi-glyph substitution), as
/// [first, last] item indices and its left and right edges.
fn clusterAt(items: []const Item, k: usize) struct { usize, usize, f64, f64 } {
    var lo = k;
    var hi = k;
    const same = struct {
        fn f(p: Item, q: Item) bool {
            return p.start == q.start and p.end == q.end;
        }
    }.f;
    while (lo > 0 and same(items[lo - 1], items[k])) lo -= 1;
    while (hi + 1 < items.len and same(items[hi + 1], items[k])) hi += 1;
    var x0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    for (items[lo .. hi + 1]) |it| {
        if (it.adv <= 0) continue;
        x0 = @min(x0, it.x);
        x1 = @max(x1, it.x + it.adv);
    }
    if (x0 > x1) {
        x0 = items[k].x;
        x1 = x0;
    }
    return .{ lo, hi, x0, x1 };
}

/// Caret stops inside a cluster's characters: byte offsets in (start, end)
/// that do not split a letter from its marks; at most `out.len`.
fn innerStops(s: []const u8, start: usize, end: usize, out: []usize) usize {
    var n: usize = 0;
    var it = utf8.Iterator.init(s[0..end]);
    it.i = start;
    _ = it.next();
    while (it.i < end) {
        const at = it.i;
        const cp = it.next() orelse break;
        if (shape.isMark(cp)) continue;
        if (n == out.len) break;
        out[n] = at;
        n += 1;
    }
    return n;
}

/// Byte offset in `s` of the caret position closest to `x` pixels from
/// the left edge of the drawn text. Works in visual order, so clicks on
/// right-to-left text land on the right logical character.
pub fn offsetForX(size_px: f64, style: Style, s: []const u8, x: i32) usize {
    return offsetForXDir(size_px, style, s, x, .auto);
}

pub fn offsetForXDir(size_px: f64, style: Style, s: []const u8, x: i32, dir: bidi.Direction) usize {
    return offsetForXRange(size_px, style, s, 0, s.len, x, dir);
}

/// offsetForX on the line made of bytes [la, lb) of paragraph `s`; the
/// result is an offset in `s`, within [la, lb].
pub fn offsetForXRange(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, x: i32, dir: bidi.Direction) usize {
    const lo = @min(la, s.len);
    const hi = @min(@max(lb, lo), s.len);
    return std.math.clamp(offsetForXInner(size_px, style, s, lo, hi, x, dir), lo, hi);
}

fn offsetForXInner(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, x: i32, dir: bidi.Direction) usize {
    const st = if (state_mod.state) |*p| p else return la + bitmapOffsetForX(size_px, s[la..lb], x);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return la;
    const items = layout.layoutRange(st, size_px, style, s, dir, la, lb) orelse return la;
    if (items.len == 0) return la;
    const fx: f64 = @floatFromInt(x);
    // before the first / past the last glyph: the visual line ends
    const first = items[0];
    if (fx <= first.x) return if (first.rtl) first.end else first.start;
    var last_vis: ?Item = null;
    for (items, 0..) |item, k| {
        if (item.adv <= 0) continue;
        last_vis = item;
        if (fx < item.x + item.adv) return offsetInCluster(s, items, k, fx);
    }
    const last = last_vis orelse items[items.len - 1];
    return if (last.rtl) last.start else last.end;
}

/// Offset for pixel `fx` inside the cluster of item `k`; a cluster of
/// several characters (ligature) is split evenly between its stops.
fn offsetInCluster(s: []const u8, items: []const Item, k: usize, fx: f64) usize {
    const item = items[k];
    _, _, const c0, const c1 = clusterAt(items, k);
    var stops: [32]usize = undefined;
    const ns = innerStops(s, item.start, item.end, &stops);
    const w = @max(1e-9, c1 - c0);
    var t = std.math.clamp((fx - c0) / w, 0.0, 1.0);
    if (item.rtl) t = 1 - t;
    const idx: usize = @intFromFloat(@round(t * @as(f64, @floatFromInt(ns + 1))));
    if (idx == 0) return item.start;
    if (idx > ns) return item.end;
    return stops[idx - 1];
}

/// Pixel x (from the left edge of the drawn text) of the caret placed
/// before the character at byte offset `offset` (or after the last one
/// when `offset == s.len`), in visual order.
pub fn xForOffset(size_px: f64, style: Style, s: []const u8, offset: usize) i32 {
    return xForOffsetDir(size_px, style, s, offset, .auto);
}

pub fn xForOffsetDir(size_px: f64, style: Style, s: []const u8, offset: usize, dir: bidi.Direction) i32 {
    return xForOffsetRange(size_px, style, s, 0, s.len, offset, dir);
}

/// xForOffset on the line made of bytes [la, lb) of paragraph `s`
/// (`offset` in `s`, clamped to the line).
pub fn xForOffsetRange(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, offset_in: usize, dir: bidi.Direction) i32 {
    const lo = @min(la, s.len);
    const hi = @min(@max(lb, lo), s.len);
    const offset = std.math.clamp(offset_in, lo, hi);
    const st = if (state_mod.state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s[lo..offset]);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout.layoutRange(st, size_px, style, s, dir, lo, hi) orelse return 0;
    if (items.len == 0) return 0;
    const x = if (offset >= hi)
        trailingCaretX(items, hi, dir, st.scratch.width)
    else
        caretXBefore(s, items, offset);
    return @intFromFloat(@round(x));
}

/// Caret x at the trailing edge of the logically last character of a
/// line ending at byte `hi`.
fn trailingCaretX(items: []const Item, hi: usize, dir: bidi.Direction, line_width: f64) f64 {
    var found: ?usize = null;
    for (items, 0..) |item, k| {
        if (item.end >= hi and (found == null or item.adv > 0)) found = k;
    }
    if (found) |k| {
        _, _, const c0, const c1 = clusterAt(items, k);
        return if (items[k].rtl) c0 else c1;
    }
    return if (dir == .rtl) 0 else line_width;
}

/// Caret x before the character at byte `offset` of the line.
fn caretXBefore(s: []const u8, items: []const Item, offset: usize) f64 {
    var found: ?usize = null;
    for (items, 0..) |item, k| {
        if (offset >= item.start and offset < item.end) {
            if (found == null) found = k;
            if (item.adv > 0) {
                found = k;
                break;
            }
        }
    }
    const k = found orelse return 0;
    const item = items[k];
    _, _, const c0, const c1 = clusterAt(items, k);
    const t = if (offset > item.start) stopFraction(s, item, offset) else 0;
    return if (item.rtl) c1 - t * (c1 - c0) else c0 + t * (c1 - c0);
}

/// Inside a ligature: how far into the cluster the caret stop at
/// `offset` lies, as a fraction of its width.
fn stopFraction(s: []const u8, item: Item, offset: usize) f64 {
    var stops: [32]usize = undefined;
    const ns = innerStops(s, item.start, item.end, &stops);
    const idx = for (stops[0..ns], 0..) |p, q| {
        if (p >= offset) break q + 1;
    } else ns;
    return @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(ns + 1));
}

/// Where the characters in byte range [a, b) of line `s` are drawn: up to
/// `out.len` horizontal spans [x0, x1) from the line's left edge, in
/// visual order, adjacent glyphs merged. Mixed-direction text gives
/// several spans. A ligature partly inside the range counts as inside.
pub fn rangeSpans(size_px: f64, style: Style, s: []const u8, a: usize, b: usize, dir: bidi.Direction, out: [][2]i32) usize {
    return rangeSpansLine(size_px, style, s, 0, s.len, a, b, dir, out);
}

/// rangeSpans for the line made of bytes [la, lb) of paragraph `s`.
pub fn rangeSpansLine(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, a: usize, b: usize, dir: bidi.Direction, out: [][2]i32) usize {
    if (a >= b or out.len == 0) return 0;
    const lo = @min(la, s.len);
    const hi = @min(@max(lb, lo), s.len);
    const st = if (state_mod.state) |*p| p else {
        const sc = bitmapScale(size_px);
        out[0] = .{ Canvas.textWidth(sc, s[lo..std.math.clamp(a, lo, hi)]), Canvas.textWidth(sc, s[lo..std.math.clamp(b, lo, hi)]) };
        return 1;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout.layoutRange(st, size_px, style, s, dir, lo, hi) orelse return 0;
    return mergeSpans(items, a, b, out);
}

/// Spans of the items overlapping bytes [a, b), adjacent ones merged.
fn mergeSpans(items: []const Item, a: usize, b: usize, out: [][2]i32) usize {
    var n: usize = 0;
    var cur: ?[2]f64 = null;
    for (items) |it| {
        if (it.adv <= 0) continue;
        const inside = it.start < b and it.end > a;
        if (inside) {
            if (cur) |*c| {
                if (@abs(it.x - c[1]) < 0.5) {
                    c[1] = it.x + it.adv;
                    continue;
                }
            }
        }
        if (cur) |c| {
            if (n == out.len) return n;
            out[n] = roundSpan(c);
            n += 1;
            cur = null;
        }
        if (inside) cur = .{ it.x, it.x + it.adv };
    }
    if (cur) |c| if (n < out.len) {
        out[n] = roundSpan(c);
        n += 1;
    };
    return n;
}

fn roundSpan(c: [2]f64) [2]i32 {
    return .{ @intFromFloat(@round(c[0])), @intFromFloat(@round(c[1])) };
}

fn bitmapOffsetForX(size_px: f64, s: []const u8, x: i32) usize {
    const cell = Canvas.textWidth(bitmapScale(size_px), "x");
    var it = utf8.Iterator.init(s);
    var pos: i32 = 0;
    var prev: usize = 0;
    while (it.next()) |_| {
        if (x < pos + @divTrunc(cell, 2)) return prev;
        pos += cell;
        prev = it.i;
    }
    return s.len;
}

test "bidi layout: visual order, carets and shaping" {
    const width = @import("measure.zig").width;
    const draw = @import("draw.zig").draw;
    const alloc = std.testing.allocator;
    state_mod.init(alloc);
    defer state_mod.deinit();
    const st = if (state_mod.state) |*p| p else return;
    // Hebrew is drawn right to left
    const heb = "\u{5E9}\u{5DC}\u{5D5}\u{5DD}"; // shalom
    const items = layout.layout(st, 16, .regular, heb, .auto).?;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqual(@as(u21, 0x5DD), items[0].cp);
    try std.testing.expect(items[0].rtl);
    const w = width(16, heb);
    // caret before the first logical letter is at the right edge
    try std.testing.expect(@abs(xForOffset(16, .regular, heb, 0) - w) <= 1);
    try std.testing.expectEqual(@as(i32, 0), xForOffset(16, .regular, heb, heb.len));
    // clicking near the right edge puts the caret at the start
    try std.testing.expectEqual(@as(usize, 0), offsetForX(16, .regular, heb, w - 1));
    try std.testing.expectEqual(heb.len, offsetForX(16, .regular, heb, 0));
    // round trip for every boundary
    var off: usize = 0;
    while (off <= heb.len) : (off += 2) {
        try std.testing.expectEqual(off, offsetForX(16, .regular, heb, xForOffset(16, .regular, heb, off)));
    }
    // LTR stays as before
    try std.testing.expectEqual(@as(usize, 0), offsetForX(16, .regular, "abc", -5));
    try std.testing.expectEqual(@as(usize, 3), offsetForX(16, .regular, "abc", 1000));
    try std.testing.expectEqual(@as(i32, 0), xForOffset(16, .regular, "abc", 0));
    try std.testing.expect(@abs(width(16, "abc") - xForOffset(16, .regular, "abc", 3)) <= 1);
    // Arabic is shaped: salaam -> 3 visible glyphs (lam-alef ligature)
    const ar = "\u{633}\u{644}\u{627}\u{645}";
    const ai = layout.layout(st, 16, .regular, ar, .auto).?;
    var visible: usize = 0;
    for (ai) |it| {
        if (it.slot != state_mod.no_font) visible += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), visible);
    try std.testing.expectEqual(@as(u32, 6), ai[0].start); // meem, leftmost
    // a range across both directions highlights each part where it is
    // "bc א" in "abc אבג def": the Hebrew letter is drawn apart from "bc "
    const mixed = "abc \u{5D0}\u{5D1}\u{5D2} def";
    var spans: [4][2]i32 = undefined;
    const ns = rangeSpans(16, .regular, mixed, 1, 6, .ltr, &spans);
    try std.testing.expectEqual(@as(usize, 2), ns);
    var covered: i32 = 0;
    for (spans[0..ns]) |sp| covered += sp[1] - sp[0];
    try std.testing.expect(@abs(covered - width(16, "bc ") - width(16, "\u{5D0}")) <= 2);
    // mixed text with numbers and invalid bytes never crashes
    var px: [64 * 32]u32 = @splat(0);
    var c = Canvas.init(&px, 64, 32);
    draw(&c, 0, 0, 14, 0xFFFFFFFF, "abc \u{5D0}\u{5D1} 123 (\u{627}\u{644}) \xFF\xC3");
    _ = offsetForX(14, .bold, "\u{5D0}1(2)\u{5D1}", 7);
    _ = xForOffset(14, .mono, "\u{5D0}1(2)\u{5D1}", 3);
}
