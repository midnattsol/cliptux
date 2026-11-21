//! Arabic-script joining: Unicode joining types and the contextual
//! joining form of every character as OpenType feature masks.

const std = @import("std");
const u32s = @import("test_util.zig").u32s;

pub const Joining = enum { U, R, D, C, T };

/// Unicode joining type (ArabicShaping.txt) for Arabic, Arabic Supplement
/// and Extended-A, Syriac and NKo; everything else is non-joining.
pub fn joining(cp: u21) Joining {
    return switch (cp) {
        0x0622...0x0625, 0x0627, 0x0629, 0x062F...0x0632, 0x0648, 0x0671...0x0673, 0x0675...0x0677, 0x0688...0x0699, 0x06C0, 0x06C3...0x06CB, 0x06CD, 0x06CF, 0x06D2, 0x06D3, 0x06D5, 0x06EE, 0x06EF => .R,
        0x0620, 0x0626, 0x0628, 0x062A...0x062E, 0x0633...0x063F, 0x0641...0x0647, 0x0649, 0x064A, 0x066E, 0x066F, 0x0678...0x0687, 0x069A...0x06BF, 0x06C1, 0x06C2, 0x06CC, 0x06CE, 0x06D0, 0x06D1, 0x06FA...0x06FC, 0x06FF => .D,
        // Syriac
        0x0710, 0x0715...0x0719, 0x071E, 0x0728, 0x072A, 0x072C, 0x072F, 0x074D => .R,
        0x0712...0x0714, 0x071A...0x071D, 0x071F...0x0727, 0x0729, 0x072B, 0x072D, 0x072E, 0x074E...0x074F => .D,
        // Arabic Supplement
        0x0759...0x075B, 0x076B, 0x076C, 0x0771, 0x0773, 0x0774, 0x0778, 0x0779 => .R,
        0x0750...0x0758, 0x075C...0x076A, 0x076D...0x0770, 0x0772, 0x0775...0x0777, 0x077A...0x077F => .D,
        // NKo
        0x07CA...0x07EA => .D,
        0x07FA => .C,
        // Arabic Extended-A
        0x08AA...0x08AC, 0x08AE, 0x08B1, 0x08B2, 0x08B9 => .R,
        0x08A0...0x08A9, 0x08AF, 0x08B0, 0x08B3, 0x08B4, 0x08B6...0x08B8, 0x08BA...0x08C8 => .D,
        0x0640, 0x200D => .C,
        0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7, 0x06E8, 0x06EA...0x06ED => .T,
        0x070F, 0x0711, 0x0730...0x074A, 0x07EB...0x07F3, 0x07FD, 0x08CA...0x08E1, 0x08E3...0x08FF => .T,
        0x0300...0x036F, 0x200B, 0x2060, 0xFE00...0xFE0F => .T,
        else => .U,
    };
}

const none: u8 = 0;
const isol: u8 = 1;
const fina: u8 = 2;
const medi: u8 = 4;
const init: u8 = 8;
const fin2: u8 = 0x10;
const fin3: u8 = 0x20;
const med2: u8 = 0x40;

/// One transition: the mask for the previous joining character (`none`
/// keeps it), the current one's mask, and the next state.
const E = struct { prev: u8, cur: u8, next: u3 };

/// Joining state machine; columns: U, L, R, D, Alaph, Dalath/Rish.
const table = [7][6]E{
    // 0: previous non-joining
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = isol, .next = 1 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = isol, .next = 1 }, .{ .prev = none, .cur = isol, .next = 6 } },
    // 1: previous R (or an isolated Alaph), not joining forward
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = isol, .next = 1 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = fin2, .next = 5 }, .{ .prev = none, .cur = isol, .next = 6 } },
    // 2: previous D/L, isolated so far, willing to join
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = init, .cur = fina, .next = 1 }, .{ .prev = init, .cur = fina, .next = 3 }, .{ .prev = init, .cur = fina, .next = 4 }, .{ .prev = init, .cur = fina, .next = 6 } },
    // 3: previous D in final form, willing to join
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = medi, .cur = fina, .next = 1 }, .{ .prev = medi, .cur = fina, .next = 3 }, .{ .prev = medi, .cur = fina, .next = 4 }, .{ .prev = medi, .cur = fina, .next = 6 } },
    // 4: previous final Alaph
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = med2, .cur = isol, .next = 2 }, .{ .prev = med2, .cur = isol, .next = 1 }, .{ .prev = med2, .cur = isol, .next = 2 }, .{ .prev = med2, .cur = fin2, .next = 5 }, .{ .prev = med2, .cur = isol, .next = 6 } },
    // 5: previous fin2/fin3 Alaph
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = isol, .cur = isol, .next = 2 }, .{ .prev = isol, .cur = isol, .next = 1 }, .{ .prev = isol, .cur = isol, .next = 2 }, .{ .prev = isol, .cur = fin2, .next = 5 }, .{ .prev = isol, .cur = isol, .next = 6 } },
    // 6: previous Dalath/Rish
    .{ .{ .prev = none, .cur = none, .next = 0 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = isol, .next = 1 }, .{ .prev = none, .cur = isol, .next = 2 }, .{ .prev = none, .cur = fin3, .next = 5 }, .{ .prev = none, .cur = isol, .next = 6 } },
};

/// State machine column of `cp`, or null for transparent characters.
fn column(cp: u21) ?usize {
    return switch (cp) {
        0x0710 => 4,
        0x0715, 0x0716, 0x072A, 0x072F => 5,
        else => switch (joining(cp)) {
            .T => null,
            .U => 0,
            .R => 2,
            .D, .C => 3,
        },
    };
}

/// Contextual joining form of every character (logical order), as OpenType
/// feature masks: 1 isol, 2 fina, 4 medi, 8 init, 0x10 fin2, 0x20 fin3,
/// 0x40 med2 (the last three for Syriac Alaph), 0 none. ZWJ joins, ZWNJ
/// and anything non-joining breaks the chain, marks are transparent.
/// This is the joining state machine shapers use, with Syriac's Alaph and
/// Dalath/Rish groups.
pub fn joiningMasks(cps: []const u21, out: []u8) void {
    @memset(out, 0);
    var state: u3 = 0;
    var prev: ?usize = null;
    for (cps, 0..) |cp, i| {
        const col = column(cp) orelse continue;
        const e = table[state][col];
        if (e.prev != none) if (prev) |p| {
            out[p] = e.prev;
        };
        out[i] = e.cur;
        prev = i;
        state = e.next;
    }
}

test "joining masks: forms, transparent marks, non-joiners" {
    var m: [8]u8 = undefined;
    // بيت
    joiningMasks(&u32s("بيت"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, medi, fina }, m[0..3]);
    // ڈ (right-joining, Urdu) after ٹ: ٹ init, ڈ final; then ے isolated after it
    joiningMasks(&u32s("ٹڈے"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, fina, isol }, m[0..3]);
    // a mark between two letters keeps them joined
    joiningMasks(&u32s("بَت"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, 0, fina }, m[0..3]);
    // ZWNJ breaks, ZWJ joins
    joiningMasks(&u32s("ب\u{200C}ب"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ isol, 0, isol }, m[0..3]);
    joiningMasks(&u32s("ب\u{200D}"), m[0..2]);
    try std.testing.expectEqual(@as(u8, init), m[0]);
    // Syriac Alaph: final after a joining letter, fin2 after a
    // non-joining one, fin3 after Dalath/Rish, med2 when a final Alaph
    // is followed by more letters
    joiningMasks(&u32s("ܫܠܡܐ"), m[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ init, medi, medi, fina }, m[0..4]);
    joiningMasks(&u32s("ܘܐ"), m[0..2]);
    try std.testing.expectEqual(@as(u8, 0x10), m[1]);
    joiningMasks(&u32s("ܕܐ"), m[0..2]);
    try std.testing.expectEqual(@as(u8, 0x20), m[1]);
    joiningMasks(&u32s("ܒܐܒ"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, 0x40, isol }, m[0..3]);
}
