//! Paired punctuation: mirrored glyphs (L4) and bracket pairs (BD14-BD16,
//! N0).

const std = @import("std");
const classes = @import("classes.zig");
const Class = classes.Class;
const class = classes.class;
const strongDir = classes.strongDir;

/// Mirrored glyph for brackets and other paired punctuation (L4).
pub fn mirror(cp: u21) u21 {
    const pairs = [_][2]u21{
        .{ '(', ')' },       .{ '<', '>' },       .{ '[', ']' },       .{ '{', '}' },
        .{ 0xAB, 0xBB },     .{ 0x2039, 0x203A }, .{ 0x2045, 0x2046 }, .{ 0x207D, 0x207E },
        .{ 0x208D, 0x208E }, .{ 0x2264, 0x2265 }, .{ 0x2208, 0x220B }, .{ 0x2282, 0x2283 },
        .{ 0x2286, 0x2287 }, .{ 0x3008, 0x3009 }, .{ 0x300A, 0x300B }, .{ 0x300C, 0x300D },
        .{ 0x300E, 0x300F }, .{ 0x3010, 0x3011 }, .{ 0xFF08, 0xFF09 }, .{ 0xFF3B, 0xFF3D },
        .{ 0xFF5B, 0xFF5D }, .{ 0x2329, 0x232A }, .{ 0x27E8, 0x27E9 }, .{ 0x2018, 0x2019 },
    };
    for (pairs) |p| {
        if (cp == p[0]) return p[1];
        if (cp == p[1]) return p[0];
    }
    return cp;
}

/// Opening bracket for a closing one (BD14/BD15), or null.
fn closingOf(cp: u21) ?u21 {
    return switch (cp) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        0x2046 => 0x2045,
        0x207E => 0x207D,
        0x208E => 0x208D,
        0x3009 => 0x3008,
        0x300B => 0x300A,
        0x300D => 0x300C,
        0x300F => 0x300E,
        0x3011 => 0x3010,
        0xFF09 => 0xFF08,
        0xFF3D => 0xFF3B,
        0xFF5D => 0xFF5B,
        0x232A => 0x2329,
        0x27E9 => 0x27E8,
        else => null,
    };
}

fn isOpening(cp: u21) bool {
    return switch (cp) {
        '(', '[', '{', 0x2045, 0x207D, 0x208D, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0xFF08, 0xFF3B, 0xFF5B, 0x2329, 0x27E8 => true,
        else => false,
    };
}

const Pair = struct { open: usize, close: usize };

/// N0: paired brackets take the direction of what they enclose.
pub fn resolveBrackets(cps: []const u21, types: []Class, ed: u1, sos: u1) void {
    var pairs: [64]Pair = undefined;
    const found = findPairs(cps, types, &pairs);
    // process in order of opening position
    std.mem.sort(Pair, found, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.open < b.open;
        }
    }.lt);
    for (found) |p| {
        if (pairDirection(types, p, ed, sos)) |dir| setPair(cps, types, p, dir);
    }
}

/// BD16: bracket pairs among the ON characters (at most `pairs.len`;
/// stops at stack overflow), in order of their closing brackets.
fn findPairs(cps: []const u21, types: []const Class, pairs: []Pair) []Pair {
    var n_pairs: usize = 0;
    var stack_cp: [63]u21 = undefined;
    var stack_pos: [63]usize = undefined;
    var sp: usize = 0;
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const cp = cps[i];
        if (types[i] != .ON) continue;
        if (isOpening(cp)) {
            if (sp == stack_cp.len) break; // BD16: stop at overflow
            stack_cp[sp] = cp;
            stack_pos[sp] = i;
            sp += 1;
        } else if (closingOf(cp)) |want| {
            var s = sp;
            while (s > 0) : (s -= 1) {
                if (stack_cp[s - 1] == want) {
                    if (n_pairs < pairs.len) {
                        pairs[n_pairs] = .{ .open = stack_pos[s - 1], .close = i };
                        n_pairs += 1;
                    }
                    sp = s - 1;
                    break;
                }
            }
        }
    }
    return pairs[0..n_pairs];
}

/// N0 b-d: the embedding direction `ed` (0 = L, 1 = R) when the pair
/// encloses a strong type of it; else, with only the opposite direction
/// inside, the direction of the context before the opening bracket; null
/// when it encloses no strong type.
fn pairDirection(types: []const Class, p: Pair, ed: u1, sos: u1) ?u1 {
    var found_e = false;
    var found_o = false;
    for (types[p.open + 1 .. p.close]) |t| {
        if (strongDir(t)) |d| {
            if (d == ed) found_e = true else found_o = true;
        }
    }
    if (found_e) return ed;
    if (!found_o) return null;
    var k = p.open;
    while (k > 0) : (k -= 1) {
        if (strongDir(types[k - 1])) |sd| return sd;
    }
    return sos;
}

/// Give both brackets of `p`, and the NSMs following each, direction `dir`.
fn setPair(cps: []const u21, types: []Class, p: Pair, dir: u1) void {
    const t: Class = if (dir == 0) .L else .R;
    types[p.open] = t;
    types[p.close] = t;
    for ([_]usize{ p.open, p.close }) |b| {
        var k = b + 1;
        while (k < cps.len and class(cps[k]) == .NSM) : (k += 1) types[k] = t;
    }
}
