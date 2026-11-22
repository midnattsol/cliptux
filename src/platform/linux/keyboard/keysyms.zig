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
