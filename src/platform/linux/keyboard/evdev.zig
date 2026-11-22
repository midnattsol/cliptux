//! evdev key and button codes (linux/input-event-codes.h) to the seam's
//! neutral ones (api/keys.zig), and back.

const std = @import("std");
const keys = @import("../../api/keys.zig");
const Code = keys.Code;
const Button = keys.Button;

/// evdev code -> Code; unnamed slots are `.other`.
const to_code: [256]Code = blk: {
    var t: [256]Code = @splat(.other);
    for (pairs) |p| t[p[0]] = p[1];
    break :blk t;
};

const pairs = [_]struct { u8, Code }{
    .{ 1, .escape },      .{ 2, .digit_1 },       .{ 3, .digit_2 },        .{ 4, .digit_3 },
    .{ 5, .digit_4 },     .{ 6, .digit_5 },       .{ 7, .digit_6 },        .{ 8, .digit_7 },
    .{ 9, .digit_8 },     .{ 10, .digit_9 },      .{ 11, .digit_0 },       .{ 12, .minus },
    .{ 13, .equal },      .{ 14, .backspace },    .{ 15, .tab },           .{ 16, .q },
    .{ 17, .w },          .{ 18, .e },            .{ 19, .r },             .{ 20, .t },
    .{ 21, .y },          .{ 22, .u },            .{ 23, .i },             .{ 24, .o },
    .{ 25, .p },          .{ 26, .bracket_left }, .{ 27, .bracket_right }, .{ 28, .enter },
    .{ 29, .ctrl_left },  .{ 30, .a },            .{ 31, .s },             .{ 32, .d },
    .{ 33, .f },          .{ 34, .g },            .{ 35, .h },             .{ 36, .j },
    .{ 37, .k },          .{ 38, .l },            .{ 39, .semicolon },     .{ 40, .quote },
    .{ 41, .backquote },  .{ 42, .shift_left },   .{ 43, .backslash },     .{ 44, .z },
    .{ 45, .x },          .{ 46, .c },            .{ 47, .v },             .{ 48, .b },
    .{ 49, .n },          .{ 50, .m },            .{ 51, .comma },         .{ 52, .period },
    .{ 53, .slash },      .{ 54, .shift_right },  .{ 55, .kp_multiply },   .{ 56, .alt_left },
    .{ 57, .space },      .{ 58, .caps_lock },    .{ 59, .f1 },            .{ 60, .f2 },
    .{ 61, .f3 },         .{ 62, .f4 },           .{ 63, .f5 },            .{ 64, .f6 },
    .{ 65, .f7 },         .{ 66, .f8 },           .{ 67, .f9 },            .{ 68, .f10 },
    .{ 69, .num_lock },   .{ 70, .scroll_lock },  .{ 71, .kp_7 },          .{ 72, .kp_8 },
    .{ 73, .kp_9 },       .{ 74, .kp_minus },     .{ 75, .kp_4 },          .{ 76, .kp_5 },
    .{ 77, .kp_6 },       .{ 78, .kp_plus },      .{ 79, .kp_1 },          .{ 80, .kp_2 },
    .{ 81, .kp_3 },       .{ 82, .kp_0 },         .{ 83, .kp_decimal },    .{ 86, .intl_backslash },
    .{ 87, .f11 },        .{ 88, .f12 },          .{ 89, .intl_ro },       .{ 96, .kp_enter },
    .{ 97, .ctrl_right }, .{ 98, .kp_divide },    .{ 99, .print },         .{ 100, .alt_right },
    .{ 102, .home },      .{ 103, .up },          .{ 104, .page_up },      .{ 105, .left },
    .{ 106, .right },     .{ 107, .end },         .{ 108, .down },         .{ 109, .page_down },
    .{ 110, .insert },    .{ 111, .delete },      .{ 117, .kp_equal },     .{ 119, .pause },
    .{ 124, .intl_yen },  .{ 125, .super_left },  .{ 126, .super_right },  .{ 127, .menu },
    .{ 183, .f13 },       .{ 184, .f14 },         .{ 185, .f15 },          .{ 186, .f16 },
    .{ 187, .f17 },       .{ 188, .f18 },         .{ 189, .f19 },          .{ 190, .f20 },
    .{ 191, .f21 },       .{ 192, .f22 },         .{ 193, .f23 },          .{ 194, .f24 },
};

/// The key of evdev `code`.
pub fn toCode(code: u32) Code {
    return if (code < to_code.len) to_code[code] else .other;
}

/// The evdev code of a named key; null for none and other.
pub fn fromCode(c: Code) ?u32 {
    for (pairs) |p| if (p[1] == c) return p[0];
    return null;
}

/// The button of evdev BTN_* `code`.
pub fn toButton(code: u32) Button {
    return switch (code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x113 => .back,
        0x114 => .forward,
        else => .other,
    };
}

test "every named key has one evdev code, and back" {
    for (std.meta.tags(Code)) |c| {
        if (c == .none or c == .other) {
            try std.testing.expectEqual(@as(?u32, null), fromCode(c));
            continue;
        }
        const code = fromCode(c) orelse return error.Unmapped;
        try std.testing.expectEqual(c, toCode(code));
    }
    try std.testing.expectEqual(Code.other, toCode(164)); // play/pause
    try std.testing.expectEqual(Code.other, toCode(0x110));
    try std.testing.expectEqual(Button.left, toButton(0x110));
    try std.testing.expectEqual(Button.other, toButton(0x115));
}
