//! Arabic contextual shaping through the presentation-form codepoints
//! that common fonts map.

const std = @import("std");
const joining_mod = @import("joining.zig");
const u32s = @import("test_util.zig").u32s;
const Joining = joining_mod.Joining;
const joining = joining_mod.joining;

/// Presentation forms: isolated, final, initial, medial (0 = none).
fn forms(cp: u21) ?[4]u21 {
    const two = struct {
        fn f(iso: u21) [4]u21 {
            return .{ iso, iso + 1, 0, 0 };
        }
        fn four(iso: u21) [4]u21 {
            return .{ iso, iso + 1, iso + 2, iso + 3 };
        }
    };
    return switch (cp) {
        0x0621 => .{ 0xFE80, 0, 0, 0 },
        0x0622 => two.f(0xFE81),
        0x0623 => two.f(0xFE83),
        0x0624 => two.f(0xFE85),
        0x0625 => two.f(0xFE87),
        0x0626 => two.four(0xFE89),
        0x0627 => two.f(0xFE8D),
        0x0628 => two.four(0xFE8F),
        0x0629 => two.f(0xFE93),
        0x062A...0x062E => two.four(0xFE95 + (cp - 0x062A) * 4),
        0x062F...0x0632 => two.f(0xFEA9 + (cp - 0x062F) * 2),
        0x0633...0x063A => two.four(0xFEB1 + (cp - 0x0633) * 4),
        0x0641...0x0647 => two.four(0xFED1 + (cp - 0x0641) * 4),
        0x0648 => two.f(0xFEED),
        0x0649 => .{ 0xFEEF, 0xFEF0, 0xFBE8, 0xFBE9 },
        0x064A => two.four(0xFEF1),
        0x0671 => two.f(0xFB50),
        0x0679 => two.four(0xFB66),
        0x067E => two.four(0xFB56),
        0x0686 => two.four(0xFB7A),
        0x0688 => two.f(0xFB88),
        0x0691 => two.f(0xFB8C),
        0x0698 => two.f(0xFB8A),
        0x06A9 => two.four(0xFB8E),
        0x06AF => two.four(0xFB92),
        0x06BA => two.f(0xFB9E),
        0x06BE => two.four(0xFBAA),
        0x06C1 => two.four(0xFBA6),
        0x06CC => two.four(0xFBFC),
        0x06D2 => two.f(0xFBAE),
        else => null,
    };
}

/// Isolated lam-alef ligature for an alef (final form is one above).
fn lamAlef(alef: u21) ?u21 {
    return switch (alef) {
        0x0622 => 0xFEF5,
        0x0623 => 0xFEF7,
        0x0625 => 0xFEF9,
        0x0627 => 0xFEFB,
        else => null,
    };
}

/// Placeholder left where a lam-alef ligature absorbed the alef.
pub const removed: u21 = 0x200B; // zero-width space: draws and measures nothing

/// The next non-transparent character after `i` (its index, if any) and
/// whether a letter of joining type `jt` joins it.
const Next = struct { idx: ?usize, joins: bool };

fn nextJoin(cps: []const u21, i: usize, jt: Joining) Next {
    var nx = i + 1;
    while (nx < cps.len) : (nx += 1) {
        const nj = joining(cps[nx]);
        if (nj == .T) continue;
        return .{ .idx = nx, .joins = jt == .D and (nj == .D or nj == .R or nj == .C) };
    }
    return .{ .idx = null, .joins = false };
}

/// Presentation form of `cp` for its joining context, falling back to a
/// form the letter has; null when it has none.
fn contextualForm(cp: u21, prev_joins: bool, next_joins: bool) ?u21 {
    const f = forms(cp) orelse return null;
    const want: usize = if (prev_joins and next_joins) 3 else if (prev_joins) 1 else if (next_joins) 2 else 0;
    const pick = if (f[want] != 0) f[want] else if (want == 3 and f[1] != 0) f[1] else f[0];
    return if (pick != 0) pick else null;
}

/// Replace Arabic letters (logical order, in place) by their contextual
/// presentation forms. A lam-alef pair becomes the ligature on the lam and
/// `removed` on the alef (callers skip it). Characters outside Arabic are
/// untouched; nothing changes length.
pub fn shapeArabic(cps: []u21) void {
    const n = cps.len;
    // joining type of the last non-transparent character, from the text
    // before shaping (shaped forms are no longer in the joining table)
    var last: Joining = .U;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp = cps[i];
        const jt = joining(cp);
        if (jt == .T) continue;
        const prev_joins = last == .D or last == .C;
        last = jt;
        if (jt != .R and jt != .D) continue;
        const next = nextJoin(cps, i, jt);
        // lam + alef
        if (cp == 0x0644 and next.idx != null and next.idx.? == i + 1) {
            if (lamAlef(cps[i + 1])) |lig| {
                cps[i] = if (prev_joins) lig + 1 else lig;
                cps[i + 1] = removed;
                i += 1;
                last = .R; // the alef ends the ligature and joins nothing after
                continue;
            }
        }
        if (contextualForm(cp, prev_joins, next.joins)) |form| cps[i] = form;
    }
}

/// Undo shaping for a single presentation form (to find a font that has
/// the plain letter when none has the form).
pub fn baseLetter(cp: u21) u21 {
    if (cp < 0xFB50 or cp > 0xFEFC) return cp;
    var c: u21 = 0x0621;
    while (c <= 0x06D2) : (c += 1) {
        if (forms(c)) |f| for (f) |x| {
            if (x == cp) return c;
        };
    }
    return switch (cp) {
        0xFEF5, 0xFEF6, 0xFEF7, 0xFEF8, 0xFEF9, 0xFEFA, 0xFEFB, 0xFEFC => 0x0644,
        else => cp,
    };
}

test "arabic shaping" {
    // سلام: seen initial, lam medial... lam + alef -> ligature, meem isolated
    var s = u32s("سلام");
    shapeArabic(&s);
    try std.testing.expectEqualSlices(u21, &.{ 0xFEB3, 0xFEFC, removed, 0xFEE1 }, &s);
    // بيت: initial, medial, final
    var b = u32s("بيت");
    shapeArabic(&b);
    try std.testing.expectEqualSlices(u21, &.{ 0xFE91, 0xFEF4, 0xFE96 }, &b);
    // a right-joining letter breaks the chain: دب -> dal isolated, beh isolated
    var d = u32s("دب");
    shapeArabic(&d);
    try std.testing.expectEqualSlices(u21, &.{ 0xFEA9, 0xFE8F }, &d);
    // marks are transparent: بَت still joins
    var m = u32s("بَت");
    shapeArabic(&m);
    try std.testing.expectEqualSlices(u21, &.{ 0xFE91, 0x064E, 0xFE96 }, &m);
    try std.testing.expectEqual(@as(u21, 0x0628), baseLetter(0xFE91));
    try std.testing.expectEqual(@as(u21, 'x'), baseLetter('x'));
}
