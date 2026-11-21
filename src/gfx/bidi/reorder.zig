//! Visual reordering of a line (L2), with end-to-end tests of level
//! resolution, reordering and mirroring.

const std = @import("std");
const classes = @import("classes.zig");
const levels_mod = @import("levels.zig");
const explicit = @import("explicit.zig");
const brackets = @import("brackets.zig");
const u32s = @import("test_util.zig").u32s;
const Class = classes.Class;
const Direction = levels_mod.Direction;
const paragraphLevel = levels_mod.paragraphLevel;
const resolveLevels = levels_mod.resolveLevels;
const isExplicit = classes.isExplicit;
const mirror = brackets.mirror;
const max_depth = explicit.max_depth;

/// L2: visual order of the line as indices into the logical text.
pub fn reorder(levels: []const u8, order: []u32) void {
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var max: u8 = 0;
    var min_odd: u8 = 255;
    for (levels) |l| {
        max = @max(max, l);
        if (l % 2 == 1) min_odd = @min(min_odd, l);
    }
    if (min_odd == 255) return;
    var level = max;
    while (level >= min_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < levels.len and levels[order[j]] >= level) j += 1;
            std.mem.reverse(u32, order[i..j]);
            i = j;
        }
        if (level == 0) break;
    }
}

/// Visual order of a UTF-32 test string as a string of the same chars.
fn visual(alloc: std.mem.Allocator, s: []const u21, dir: Direction) ![]u21 {
    const n = s.len;
    const types = try alloc.alloc(Class, n);
    defer alloc.free(types);
    const levels = try alloc.alloc(u8, n);
    defer alloc.free(levels);
    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    resolveLevels(s, paragraphLevel(s, dir), types, levels);
    reorder(levels, order);
    const out = try alloc.alloc(u21, n);
    for (order, out) |o, *c| c.* = if (levels[o] % 2 == 1) mirror(s[o]) else s[o];
    return out;
}

fn expectVisual(comptime logical: []const u8, comptime expected: []const u8, dir: Direction) !void {
    const alloc = std.testing.allocator;
    const l = u32s(logical);
    const lv = try alloc.dupe(u21, &l);
    defer alloc.free(lv);
    const v = try visual(alloc, lv, dir);
    defer alloc.free(v);
    const e = u32s(expected);
    try std.testing.expectEqualSlices(u21, &e, v);
}

test "bidi reordering" {
    // Hebrew alone is reversed
    try expectVisual("שלום", "םולש", .auto);
    // Hebrew in an English sentence: only the Hebrew run flips
    try expectVisual("say שלום now", "say םולש now", .auto);
    // numbers keep their order inside RTL text
    try expectVisual("מחיר 120 שקל", "לקש 120 ריחמ", .auto);
    // English inside an RTL paragraph keeps its own order, run moves
    try expectVisual("שלום world!", "!world םולש", .auto);
    // brackets are mirrored at odd levels and follow their content
    try expectVisual("א(ב)ג", "ג(ב)א", .auto);
    // explicit LTR paragraph with leading RTL
    try expectVisual("אב cd", "בא cd", .ltr);
    // phone number with separators stays together
    try expectVisual("טל 03-555-1234", "03-555-1234 לט", .auto);
}

/// expectVisual ignoring where the (invisible) explicit controls land;
/// `expected` is written without them.
fn expectVisualText(comptime logical: []const u8, comptime expected: []const u8, dir: Direction) !void {
    const alloc = std.testing.allocator;
    const l = u32s(logical);
    const v = try visual(alloc, &l, dir);
    defer alloc.free(v);
    var out: [64]u21 = undefined;
    var n: usize = 0;
    for (v) |c| {
        if (isExplicit(c)) continue;
        out[n] = c;
        n += 1;
    }
    const e = u32s(expected);
    try std.testing.expectEqualSlices(u21, &e, out[0..n]);
}

test "explicit embeddings, overrides and isolates" {
    // RLO..PDF reverses Latin letters
    try expectVisualText("a\u{202E}bc\u{202C}d", "acbd", .ltr);
    // LRO keeps Hebrew in logical order
    try expectVisualText("\u{202D}\u{5D0}\u{5D1}\u{202C}", "\u{5D0}\u{5D1}", .ltr);
    // an LRI keeps "hello!" together: without it the "!" would jump to
    // the left of the word in this right-to-left paragraph
    try expectVisualText("שלום \u{2066}hello!\u{2069} עולם", "םלוע hello! םולש", .auto);
    try expectVisualText("שלום hello! עולם", "םלוע !hello םולש", .auto);
    // FSI takes the direction of its content
    try expectVisualText("a \u{2068}\u{5D0}\u{5D1}\u{2069} c", "a \u{5D1}\u{5D0} c", .auto);
    // RLI around a number and Latin in an LTR paragraph: the isolate
    // reads right to left as a unit
    try expectVisualText("x \u{2067}ab \u{5D0}\u{2069} y", "x \u{5D0} ab y", .auto);
    // the paragraph direction skips isolated text (P2)
    try std.testing.expectEqual(@as(u1, 0), paragraphLevel(&u32s("\u{2067}\u{5D0}\u{2069}abc"), .auto));
    // RLE raises Latin text to level 2: order kept
    try expectVisualText("x\u{202B}ab 12\u{202C}y", "xab 12y", .ltr);
    // unbalanced and absurdly deep controls never crash or overflow
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    const pool = [_]u21{ 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 'a', 0x5D0, 0x627, '1', ' ', '(', ')', 0x64E, 0x200D };
    var cps: [400]u21 = undefined;
    var types: [400]Class = undefined;
    var levels: [400]u8 = undefined;
    var order: [400]u32 = undefined;
    for (0..2000) |_| {
        const n = r.intRangeAtMost(usize, 0, cps.len);
        for (cps[0..n]) |*c| c.* = pool[r.uintLessThan(usize, pool.len)];
        if (r.boolean()) for (cps[0 .. n / 2]) |*c| {
            c.* = 0x202B;
        };
        const para = paragraphLevel(cps[0..n], .auto);
        resolveLevels(cps[0..n], para, types[0..n], levels[0..n]);
        for (levels[0..n]) |l| std.testing.expect(l <= max_depth + 1) catch |e| {
            std.debug.print("level {d} in {any}\n", .{ l, cps[0..n] });
            return e;
        };
        reorder(levels[0..n], order[0..n]);
    }
    _ = alloc;
}
