//! Keysym constants and printable key captions.

const std = @import("std");
const xkb = @import("xkb.zig");

pub const XK = struct {
    pub const BackSpace: u32 = 0xff08;
    pub const Tab: u32 = 0xff09;
    pub const ISO_Left_Tab: u32 = 0xfe20;
    pub const Return: u32 = 0xff0d;
    pub const Escape: u32 = 0xff1b;
    pub const Delete: u32 = 0xffff;
    pub const Home: u32 = 0xff50;
    pub const Left: u32 = 0xff51;
    pub const Up: u32 = 0xff52;
    pub const Right: u32 = 0xff53;
    pub const Down: u32 = 0xff54;
    pub const Page_Up: u32 = 0xff55;
    pub const Page_Down: u32 = 0xff56;
    pub const End: u32 = 0xff57;
    pub const Shift_L: u32 = 0xffe1;
    pub const Shift_R: u32 = 0xffe2;
    pub const Control_L: u32 = 0xffe3;
    pub const Control_R: u32 = 0xffe4;
    pub const Caps_Lock: u32 = 0xffe5;
    pub const Alt_L: u32 = 0xffe9;
    pub const Alt_R: u32 = 0xffea;
    pub const Super_L: u32 = 0xffeb;
    pub const Super_R: u32 = 0xffec;
    pub const F1: u32 = 0xffbe;
};

/// Printable label for a keysym: its character (upper-cased when it is a
/// lower-case letter), or its xkb name with dead_ stripped.
pub fn keysymLabel(sym: u32, buf: []u8) ?[]const u8 {
    if (sym == 0 or !xkb.loaded() or buf.len < 8) return null;
    switch (sym) {
        XK.Return => return "Enter",
        XK.Escape => return "Esc",
        XK.BackSpace => return "Backspace",
        XK.Delete => return "Delete",
        ' ' => return "Space",
        else => {},
    }
    var u: [8]u8 = undefined;
    const n = xkb.api.keysym_to_utf8(sym, &u, u.len);
    if (n > 1) {
        const s = u[0..@intCast(n - 1)];
        if (s[0] >= 0x20 and s[0] != 0x7f) {
            const cp = std.unicode.utf8Decode(s) catch return copyOut(buf, s);
            const up = upperLatin(cp);
            const len = std.unicode.utf8Encode(up, buf) catch return copyOut(buf, s);
            return buf[0..len];
        }
    }
    const m = xkb.api.keysym_get_name(sym, buf.ptr, buf.len);
    if (m <= 0) return null;
    var name = buf[0..@intCast(@min(m, @as(c_int, @intCast(buf.len - 1))))];
    if (std.mem.startsWith(u8, name, "dead_")) name = name[5..];
    return name;
}

fn copyOut(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Upper-case ASCII and Latin-1 letters (enough for key captions).
fn upperLatin(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) return cp - 32;
    return cp;
}

/// The character keysym `sym` stands for: Latin-1 and Unicode keysyms,
/// and the legacy ones xkb knows a character for; 0 for function, keypad,
/// modifier and dead keys, which name no character of the layout.
pub fn keysymChar(sym: u32) u21 {
    if ((sym >= 0x20 and sym <= 0x7e) or (sym >= 0xa0 and sym <= 0xff)) return @intCast(sym);
    if (sym >= 0x0100_0100 and sym <= 0x0110_ffff) return @intCast(sym - 0x0100_0000);
    if (sym == 0 or sym >= 0xfd00 or !xkb.loaded()) return 0;
    var u: [8]u8 = undefined;
    const n = xkb.api.keysym_to_utf8(sym, &u, u.len);
    if (n <= 1) return 0;
    const cp = std.unicode.utf8Decode(u[0..@intCast(n - 1)]) catch return 0;
    return if (cp < 0x20 or cp == 0x7f) 0 else cp;
}

test "keysyms that are characters" {
    try std.testing.expectEqual(@as(u21, 'q'), keysymChar('q'));
    try std.testing.expectEqual(@as(u21, 'Q'), keysymChar('Q'));
    try std.testing.expectEqual(@as(u21, ' '), keysymChar(' '));
    try std.testing.expectEqual(@as(u21, 0xf1), keysymChar(0xf1)); // ntilde
    try std.testing.expectEqual(@as(u21, 0x20ac), keysymChar(0x0100_20ac)); // EuroSign
    try std.testing.expectEqual(@as(u21, 0), keysymChar(XK.Return));
    try std.testing.expectEqual(@as(u21, 0), keysymChar(XK.F1));
    try std.testing.expectEqual(@as(u21, 0), keysymChar(0xffb1)); // KP_1
    try std.testing.expectEqual(@as(u21, 0), keysymChar(0xfe51)); // dead_acute
    try std.testing.expectEqual(@as(u21, 0), keysymChar(0));
}
