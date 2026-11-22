//! Built-in US layout, used when libxkbcommon or the compositor keymap
//! is unavailable.

const XK = @import("keysyms.zig").XK;

pub fn isLetter(code: u32) bool {
    return (code >= 16 and code <= 25) or (code >= 30 and code <= 38) or (code >= 44 and code <= 50);
}

pub fn usChar(code: u32, upper: bool) ?u8 {
    const row = struct {
        fn pick(s: []const u8, u: []const u8, i: u32, up: bool) u8 {
            return if (up) u[i] else s[i];
        }
    };
    return switch (code) {
        2...13 => row.pick("1234567890-=", "!@#$%^&*()_+", code - 2, upper),
        16...27 => row.pick("qwertyuiop[]", "QWERTYUIOP{}", code - 16, upper),
        30...41 => row.pick("asdfghjkl;'`", "ASDFGHJKL:\"~", code - 30, upper),
        43...53 => row.pick("\\zxcvbnm,./", "|ZXCVBNM<>?", code - 43, upper),
        57 => ' ',
        else => null,
    };
}

pub fn usSpecialSym(code: u32) u32 {
    return switch (code) {
        1 => XK.Escape,
        14 => XK.BackSpace,
        15 => XK.Tab,
        28, 96 => XK.Return,
        29 => XK.Control_L,
        97 => XK.Control_R,
        42 => XK.Shift_L,
        54 => XK.Shift_R,
        56 => XK.Alt_L,
        100 => XK.Alt_R,
        58 => XK.Caps_Lock,
        59...68 => XK.F1 + (code - 59),
        87 => XK.F1 + 10,
        88 => XK.F1 + 11,
        102 => XK.Home,
        103 => XK.Up,
        104 => XK.Page_Up,
        105 => XK.Left,
        106 => XK.Right,
        107 => XK.End,
        108 => XK.Down,
        109 => XK.Page_Down,
        111 => XK.Delete,
        125 => XK.Super_L,
        126 => XK.Super_R,
        else => 0,
    };
}
