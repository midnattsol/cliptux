//! Key names for shotlet-drive's `key` and `hold` commands.

const std = @import("std");

/// evdev key codes by name (US physical positions; the compositor's keymap
/// decides what they type)
pub fn keyCode(name: []const u8) ?u32 {
    if (name.len > 1 and name[0] == '#') return std.fmt.parseInt(u32, name[1..], 10) catch null;
    if (name.len == 1) {
        const c = name[0];
        const letters = "qwertyuiop"; // 16..25
        const row2 = "asdfghjkl"; // 30..38
        const row3 = "zxcvbnm"; // 44..50
        if (std.mem.indexOfScalar(u8, letters, c)) |i| return @intCast(16 + i);
        if (std.mem.indexOfScalar(u8, row2, c)) |i| return @intCast(30 + i);
        if (std.mem.indexOfScalar(u8, row3, c)) |i| return @intCast(44 + i);
        if (c >= '1' and c <= '9') return @intCast(2 + c - '1');
        if (c == '0') return 11;
    }
    const table = [_]struct { []const u8, u32 }{
        .{ "esc", 1 },       .{ "minus", 12 },     .{ "equal", 13 },      .{ "backspace", 14 },
        .{ "tab", 15 },      .{ "leftbrace", 26 }, .{ "rightbrace", 27 }, .{ "enter", 28 },
        .{ "ctrl", 29 },     .{ "semicolon", 39 }, .{ "apostrophe", 40 }, .{ "grave", 41 },
        .{ "shift", 42 },    .{ "backslash", 43 }, .{ "comma", 51 },      .{ "dot", 52 },
        .{ "slash", 53 },    .{ "rshift", 54 },    .{ "alt", 56 },        .{ "space", 57 },
        .{ "capslock", 58 }, .{ "f1", 59 },        .{ "f2", 60 },         .{ "102nd", 86 },
        .{ "rctrl", 97 },    .{ "altgr", 100 },    .{ "home", 102 },      .{ "up", 103 },
        .{ "pageup", 104 },  .{ "left", 105 },     .{ "right", 106 },     .{ "end", 107 },
        .{ "down", 108 },    .{ "pagedown", 109 }, .{ "insert", 110 },    .{ "delete", 111 },
        .{ "super", 125 },   .{ "print", 99 },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

/// Parse "ctrl+shift+s" into `codes`; the number of keys.
pub fn parseCombo(combo: []const u8, codes: *[8]u32) !usize {
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, combo, '+');
    while (parts.next()) |p| {
        if (n == codes.len) return error.TooManyKeys;
        codes[n] = keyCode(p) orelse return error.UnknownKey;
        n += 1;
    }
    return n;
}
