//! Embedding levels of a paragraph or line: paragraph direction (P2/P3),
//! the resolution entry point, and the line rule L1.

const classes = @import("classes.zig");
const explicit = @import("explicit.zig");
const sequence = @import("sequence.zig");
const Class = classes.Class;
const class = classes.class;

pub const Direction = enum { auto, ltr, rtl };

/// Paragraph embedding level from the first strong character (P2/P3),
/// skipping text inside isolates.
pub fn paragraphLevel(cps: []const u21, dir: Direction) u1 {
    switch (dir) {
        .ltr => return 0,
        .rtl => return 1,
        .auto => {},
    }
    return classes.firstStrong(cps) orelse 0;
}

/// Resolve embedding levels for one paragraph or line (`levels.len ==
/// cps.len`); `types` is scratch of the same length. Explicit
/// embeddings, overrides and isolates (X1-X10) are honoured; text
/// without them takes a fast path with one isolating run sequence.
pub fn resolveLevels(cps: []const u21, para: u1, types: []Class, levels: []u8) void {
    for (cps, types) |cp, *t| t.* = class(cp);
    const has_explicit = for (cps) |cp| {
        if (classes.isExplicit(cp)) break true;
    } else false;
    if (!has_explicit or !explicit.resolveExplicit(cps, para, types, levels)) {
        @memset(levels, para);
        sequence.resolveSequence(cps, types, para, para, para);
        for (types, levels) |t, *l| l.* = sequence.implicitLevel(para, t);
    }
    lineRules(cps, para, levels);
}

/// L1 for one line of a paragraph whose levels were resolved as a whole
/// (`cps` and `levels` are the line's): its trailing whitespace returns
/// to the paragraph level.
pub fn lineLevels(cps: []const u21, para: u1, levels: []u8) void {
    lineRules(cps, para, levels);
}

/// Classes L1 resets when they trail the line or a separator.
fn isTrailing(c: Class) bool {
    return switch (c) {
        .WS, .S, .B, .BN, .LRI, .RLI, .FSI, .PDI, .LRE, .RLE, .LRO, .RLO, .PDF => true,
        else => false,
    };
}

/// L1: separators, and whitespace and isolate controls at the end of the
/// line (or before a separator), go back to the paragraph level.
fn lineRules(cps: []const u21, para: u1, levels: []u8) void {
    var k = cps.len;
    while (k > 0 and isTrailing(class(cps[k - 1]))) : (k -= 1) levels[k - 1] = para;
    for (cps, 0..) |cp, i| {
        const c = class(cp);
        if (c != .S and c != .B) continue;
        levels[i] = para;
        var j = i;
        while (j > 0 and isTrailing(class(cps[j - 1])) and class(cps[j - 1]) != .S and class(cps[j - 1]) != .B) : (j -= 1) levels[j - 1] = para;
    }
}
