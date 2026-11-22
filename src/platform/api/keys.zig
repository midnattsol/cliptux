//! Keys and mouse buttons as the core knows them, whatever the platform:
//! a backend translates its native key codes and buttons into these.
//!
//! A `Code` names a physical key by what it types on a US QWERTY
//! keyboard (`.q` is the key left of W on every layout); what it types
//! in the active layout comes with the event (Key.char, Key.text).

const std = @import("std");

pub const Code = enum(u8) {
    /// no physical key: text an input method committed
    none = 0,
    /// a key with no name here (media keys, vendor keys)
    other,
    // zig fmt: off
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    digit_1, digit_2, digit_3, digit_4, digit_5, digit_6, digit_7, digit_8, digit_9, digit_0,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24,
    // zig fmt: on
    escape,
    enter,
    backspace,
    tab,
    space,
    minus,
    equal,
    bracket_left,
    bracket_right,
    backslash,
    semicolon,
    quote,
    backquote,
    comma,
    period,
    slash,
    /// the extra key next to left Shift on ISO keyboards
    intl_backslash,
    /// the JIS keyboard's \ and ¥ keys
    intl_ro,
    intl_yen,
    caps_lock,
    shift_left,
    shift_right,
    ctrl_left,
    ctrl_right,
    alt_left,
    alt_right,
    super_left,
    super_right,
    menu,
    print,
    scroll_lock,
    pause,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    num_lock,
    // zig fmt: off
    kp_0, kp_1, kp_2, kp_3, kp_4, kp_5, kp_6, kp_7, kp_8, kp_9,
    // zig fmt: on
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_minus,
    kp_plus,
    kp_enter,
    kp_equal,

    /// The letter key typing `c` on a US layout ('a'..'z', either case).
    pub fn letter(c: u8) ?Code {
        const l = std.ascii.toLower(c);
        if (l < 'a' or l > 'z') return null;
        return @fromBackingInt(@backingInt(Code.a) + (l - 'a'));
    }

    /// The digit-row key of `d` ('0'..'9').
    pub fn digit(d: u8) ?Code {
        if (d < '0' or d > '9') return null;
        if (d == '0') return .digit_0;
        return @fromBackingInt(@backingInt(Code.digit_1) + (d - '1'));
    }

    /// Function key `n` (1..24).
    pub fn function(n: u8) ?Code {
        if (n < 1 or n > 24) return null;
        return @fromBackingInt(@backingInt(Code.f1) + (n - 1));
    }

    /// Its letter, upper case, for a letter key.
    pub fn letterChar(c: Code) ?u8 {
        const i = @backingInt(c);
        if (i < @backingInt(Code.a) or i > @backingInt(Code.z)) return null;
        return 'A' + (i - @backingInt(Code.a));
    }

    /// Its digit, for a digit-row key.
    pub fn digitChar(c: Code) ?u8 {
        if (c == .digit_0) return '0';
        const i = @backingInt(c);
        if (i < @backingInt(Code.digit_1) or i > @backingInt(Code.digit_9)) return null;
        return '1' + (i - @backingInt(Code.digit_1));
    }

    /// Its number, for a function key (1..24).
    pub fn functionNumber(c: Code) ?u8 {
        const i = @backingInt(c);
        if (i < @backingInt(Code.f1) or i > @backingInt(Code.f24)) return null;
        return 1 + (i - @backingInt(Code.f1));
    }

    /// A shift, ctrl, alt or super key.
    pub fn isModifier(c: Code) bool {
        return switch (c) {
            .shift_left, .shift_right, .ctrl_left, .ctrl_right, .alt_left, .alt_right, .super_left, .super_right => true,
            else => false,
        };
    }

    /// Either Enter (the main one or the keypad's).
    pub fn isEnter(c: Code) bool {
        return c == .enter or c == .kp_enter;
    }

    /// How people read it, as printed on a US keyboard: "A", "1", "F1",
    /// "Esc", "PgUp", "[" ... ("key?" for none and other).
    pub fn label(c: Code) []const u8 {
        if (named(c)) |n| if (n.label) |l| return l;
        return name(c) orelse "key?";
    }

    /// Its name in shortcuts ("Ctrl+Shift+Z", app/accel.zig): "Z", "1",
    /// "F1", "Esc", "PageUp", "BracketLeft" ...; null for none and other.
    pub fn name(c: Code) ?[]const u8 {
        if (named(c)) |n| return n.name;
        return generatedName(c);
    }

    /// The key a name or label stands for (any case): "z", "PageUp",
    /// "PgUp", "[" ...
    pub fn fromName(s: []const u8) ?Code {
        if (s.len == 1) {
            if (letter(s[0])) |c| return c;
            if (digit(s[0])) |c| return c;
        }
        if (s.len >= 2 and (s[0] == 'F' or s[0] == 'f')) {
            const n = std.fmt.parseInt(u8, s[1..], 10) catch 0;
            if (function(n)) |c| return c;
        }
        for (names) |n| {
            if (std.ascii.eqlIgnoreCase(n.name, s)) return n.code;
            if (n.label) |l| if (std.ascii.eqlIgnoreCase(l, s)) return n.code;
        }
        return null;
    }
};

/// Letters, digits and function keys: names made from the code.
fn generatedName(c: Code) ?[]const u8 {
    const all = comptime blk: {
        var out: [256]?[]const u8 = @splat(null);
        for (std.meta.tags(Code)) |t| {
            const tag = @tagName(t);
            if (tag.len == 1) {
                out[@backingInt(t)] = &[_]u8{std.ascii.toUpper(tag[0])};
            } else if (std.mem.startsWith(u8, tag, "digit_")) {
                out[@backingInt(t)] = tag["digit_".len..];
            } else if (tag[0] == 'f' and std.ascii.isDigit(tag[1])) {
                out[@backingInt(t)] = "F" ++ tag[1..];
            }
        }
        break :blk out;
    };
    return all[@backingInt(c)];
}

const Named = struct {
    code: Code,
    /// the shortcut name
    name: []const u8,
    /// how it is printed on the key, when that differs
    label: ?[]const u8 = null,
};

fn named(c: Code) ?Named {
    for (names) |n| if (n.code == c) return n;
    return null;
}

const names = [_]Named{
    .{ .code = .escape, .name = "Esc" },
    .{ .code = .enter, .name = "Enter" },
    .{ .code = .backspace, .name = "Backspace" },
    .{ .code = .tab, .name = "Tab" },
    .{ .code = .space, .name = "Space" },
    .{ .code = .minus, .name = "Minus", .label = "-" },
    .{ .code = .equal, .name = "Equal", .label = "=" },
    .{ .code = .bracket_left, .name = "BracketLeft", .label = "[" },
    .{ .code = .bracket_right, .name = "BracketRight", .label = "]" },
    .{ .code = .backslash, .name = "Backslash", .label = "\\" },
    .{ .code = .semicolon, .name = "Semicolon", .label = ";" },
    .{ .code = .quote, .name = "Quote", .label = "'" },
    .{ .code = .backquote, .name = "Backquote", .label = "`" },
    .{ .code = .comma, .name = "Comma", .label = "," },
    .{ .code = .period, .name = "Period", .label = "." },
    .{ .code = .slash, .name = "Slash", .label = "/" },
    .{ .code = .intl_backslash, .name = "IntlBackslash" },
    .{ .code = .intl_ro, .name = "IntlRo" },
    .{ .code = .intl_yen, .name = "IntlYen" },
    .{ .code = .caps_lock, .name = "CapsLock", .label = "Caps Lock" },
    .{ .code = .shift_left, .name = "ShiftLeft", .label = "Shift" },
    .{ .code = .shift_right, .name = "ShiftRight", .label = "Shift" },
    .{ .code = .ctrl_left, .name = "CtrlLeft", .label = "Ctrl" },
    .{ .code = .ctrl_right, .name = "CtrlRight", .label = "Ctrl" },
    .{ .code = .alt_left, .name = "AltLeft", .label = "Alt" },
    .{ .code = .alt_right, .name = "AltRight", .label = "Alt" },
    .{ .code = .super_left, .name = "SuperLeft", .label = "Super" },
    .{ .code = .super_right, .name = "SuperRight", .label = "Super" },
    .{ .code = .menu, .name = "Menu" },
    .{ .code = .print, .name = "Print" },
    .{ .code = .scroll_lock, .name = "ScrollLock", .label = "Scroll Lock" },
    .{ .code = .pause, .name = "Pause" },
    .{ .code = .insert, .name = "Insert" },
    .{ .code = .delete, .name = "Delete" },
    .{ .code = .home, .name = "Home" },
    .{ .code = .end, .name = "End" },
    .{ .code = .page_up, .name = "PageUp", .label = "PgUp" },
    .{ .code = .page_down, .name = "PageDown", .label = "PgDn" },
    .{ .code = .up, .name = "Up" },
    .{ .code = .down, .name = "Down" },
    .{ .code = .left, .name = "Left" },
    .{ .code = .right, .name = "Right" },
    .{ .code = .num_lock, .name = "NumLock", .label = "Num Lock" },
    .{ .code = .kp_0, .name = "Keypad0", .label = "Keypad 0" },
    .{ .code = .kp_1, .name = "Keypad1", .label = "Keypad 1" },
    .{ .code = .kp_2, .name = "Keypad2", .label = "Keypad 2" },
    .{ .code = .kp_3, .name = "Keypad3", .label = "Keypad 3" },
    .{ .code = .kp_4, .name = "Keypad4", .label = "Keypad 4" },
    .{ .code = .kp_5, .name = "Keypad5", .label = "Keypad 5" },
    .{ .code = .kp_6, .name = "Keypad6", .label = "Keypad 6" },
    .{ .code = .kp_7, .name = "Keypad7", .label = "Keypad 7" },
    .{ .code = .kp_8, .name = "Keypad8", .label = "Keypad 8" },
    .{ .code = .kp_9, .name = "Keypad9", .label = "Keypad 9" },
    .{ .code = .kp_decimal, .name = "KeypadDecimal", .label = "Keypad ." },
    .{ .code = .kp_divide, .name = "KeypadDivide", .label = "Keypad /" },
    .{ .code = .kp_multiply, .name = "KeypadMultiply", .label = "Keypad *" },
    .{ .code = .kp_minus, .name = "KeypadMinus", .label = "Keypad -" },
    .{ .code = .kp_plus, .name = "KeypadPlus", .label = "Keypad +" },
    .{ .code = .kp_enter, .name = "KeypadEnter", .label = "Keypad Enter" },
    .{ .code = .kp_equal, .name = "KeypadEqual", .label = "Keypad =" },
};

/// Mouse buttons.
pub const Button = enum(u8) {
    left,
    right,
    middle,
    /// the side buttons (browser back and forward)
    back,
    forward,
    /// any other button
    other,
};

test "every key but none and other has a name that reads back" {
    for (std.meta.tags(Code)) |c| {
        if (c == .none or c == .other) {
            try std.testing.expectEqual(@as(?[]const u8, null), c.name());
            try std.testing.expectEqualStrings("key?", c.label());
            continue;
        }
        const n = c.name().?;
        try std.testing.expectEqual(c, Code.fromName(n).?);
        try std.testing.expect(std.mem.indexOfScalar(u8, n, '+') == null);
    }
}

test "names and labels" {
    const t = std.testing;
    try t.expectEqualStrings("Q", Code.q.label());
    try t.expectEqualStrings("1", Code.digit_1.label());
    try t.expectEqualStrings("0", Code.digit_0.name().?);
    try t.expectEqualStrings("F12", Code.f12.label());
    try t.expectEqualStrings("PgUp", Code.page_up.label());
    try t.expectEqualStrings("PageUp", Code.page_up.name().?);
    try t.expectEqualStrings("-", Code.minus.label());
    try t.expectEqual(Code.page_up, Code.fromName("pgup").?);
    try t.expectEqual(Code.f24, Code.fromName("f24").?);
    try t.expectEqual(Code.bracket_right, Code.fromName("]").?);
    try t.expectEqual(@as(?Code, null), Code.fromName("F25"));
    try t.expectEqual(@as(?Code, null), Code.fromName("banana"));
    try t.expectEqual(@as(?u8, 'W'), Code.w.letterChar());
    try t.expectEqual(@as(?u8, '0'), Code.digit_0.digitChar());
    try t.expectEqual(@as(?u8, 7), Code.f7.functionNumber());
    try t.expect(Code.shift_right.isModifier() and !Code.a.isModifier() and !Code.caps_lock.isModifier());
}
