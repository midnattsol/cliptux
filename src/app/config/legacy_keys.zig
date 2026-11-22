//! The key numbers older config files hold in `bind_<action>` values
//! ("ctrl+shift+44"): Linux evdev codes (linux/input-event-codes.h), as
//! Shotlet stored them before keys were platform-neutral. Frozen: only
//! reading old files needs them.

const std = @import("std");
const KeyCode = @import("../../platform/api/keys.zig").Code;

const numbered = [_]struct { u8, KeyCode }{
    .{ 1, .escape },       .{ 2, .digit_1 },       .{ 3, .digit_2 },         .{ 4, .digit_3 },
    .{ 5, .digit_4 },      .{ 6, .digit_5 },       .{ 7, .digit_6 },         .{ 8, .digit_7 },
    .{ 9, .digit_8 },      .{ 10, .digit_9 },      .{ 11, .digit_0 },        .{ 12, .minus },
    .{ 13, .equal },       .{ 14, .backspace },    .{ 15, .tab },            .{ 16, .q },
    .{ 17, .w },           .{ 18, .e },            .{ 19, .r },              .{ 20, .t },
    .{ 21, .y },           .{ 22, .u },            .{ 23, .i },              .{ 24, .o },
    .{ 25, .p },           .{ 26, .bracket_left }, .{ 27, .bracket_right },  .{ 28, .enter },
    .{ 30, .a },           .{ 31, .s },            .{ 32, .d },              .{ 33, .f },
    .{ 34, .g },           .{ 35, .h },            .{ 36, .j },              .{ 37, .k },
    .{ 38, .l },           .{ 39, .semicolon },    .{ 40, .quote },          .{ 41, .backquote },
    .{ 43, .backslash },   .{ 44, .z },            .{ 45, .x },              .{ 46, .c },
    .{ 47, .v },           .{ 48, .b },            .{ 49, .n },              .{ 50, .m },
    .{ 51, .comma },       .{ 52, .period },       .{ 53, .slash },          .{ 55, .kp_multiply },
    .{ 57, .space },       .{ 59, .f1 },           .{ 60, .f2 },             .{ 61, .f3 },
    .{ 62, .f4 },          .{ 63, .f5 },           .{ 64, .f6 },             .{ 65, .f7 },
    .{ 66, .f8 },          .{ 67, .f9 },           .{ 68, .f10 },            .{ 69, .num_lock },
    .{ 70, .scroll_lock }, .{ 71, .kp_7 },         .{ 72, .kp_8 },           .{ 73, .kp_9 },
    .{ 74, .kp_minus },    .{ 75, .kp_4 },         .{ 76, .kp_5 },           .{ 77, .kp_6 },
    .{ 78, .kp_plus },     .{ 79, .kp_1 },         .{ 80, .kp_2 },           .{ 81, .kp_3 },
    .{ 82, .kp_0 },        .{ 83, .kp_decimal },   .{ 86, .intl_backslash }, .{ 87, .f11 },
    .{ 88, .f12 },         .{ 96, .kp_enter },     .{ 98, .kp_divide },      .{ 99, .print },
    .{ 102, .home },       .{ 103, .up },          .{ 104, .page_up },       .{ 105, .left },
    .{ 106, .right },      .{ 107, .end },         .{ 108, .down },          .{ 109, .page_down },
    .{ 110, .insert },     .{ 111, .delete },      .{ 119, .pause },         .{ 127, .menu },
};

/// The key an old file's number stands for; none when it names none.
pub fn key(n: u32) KeyCode {
    for (numbered) |e| if (e[0] == n) return e[1];
    return .none;
}

/// The number an old file would hold for `code`; null when it had none.
pub fn number(code: KeyCode) ?u32 {
    for (numbered) |n| if (n[1] == code) return n[0];
    return null;
}

test "old key numbers read as the keys they were" {
    try std.testing.expectEqual(KeyCode.z, key(44));
    try std.testing.expectEqual(KeyCode.digit_1, key(2));
    try std.testing.expectEqual(KeyCode.f12, key(88));
    try std.testing.expectEqual(KeyCode.none, key(0));
    try std.testing.expectEqual(KeyCode.none, key(9999));
    try std.testing.expectEqual(@as(?u32, 33), number(.f));
    for (numbered) |n| try std.testing.expectEqual(@as(?u32, n[0]), number(n[1]));
}
