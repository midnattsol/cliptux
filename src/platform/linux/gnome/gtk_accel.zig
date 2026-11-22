//! GTK's accelerator notation ("<Ctrl><Shift>s", "<Super>Print"), how
//! GNOME keeps shortcuts: to and from Shotlet's neutral one
//! (app/accel.zig), and telling when two name the same key.

const std = @import("std");
const accel = @import("../../../app/accel.zig");
const KeyCode = @import("../../api/keys.zig").Code;
const Accel = accel.Accel;

/// keysym names GTK writes for the keys that are no letter, digit or
/// function key
const key_names = [_]struct { KeyCode, []const u8 }{
    .{ .escape, "Escape" },         .{ .enter, "Return" },             .{ .backspace, "BackSpace" },
    .{ .tab, "Tab" },               .{ .space, "space" },              .{ .minus, "minus" },
    .{ .equal, "equal" },           .{ .bracket_left, "bracketleft" }, .{ .bracket_right, "bracketright" },
    .{ .backslash, "backslash" },   .{ .semicolon, "semicolon" },      .{ .quote, "apostrophe" },
    .{ .backquote, "grave" },       .{ .comma, "comma" },              .{ .period, "period" },
    .{ .slash, "slash" },           .{ .caps_lock, "Caps_Lock" },      .{ .menu, "Menu" },
    .{ .print, "Print" },           .{ .scroll_lock, "Scroll_Lock" },  .{ .pause, "Pause" },
    .{ .insert, "Insert" },         .{ .delete, "Delete" },            .{ .home, "Home" },
    .{ .end, "End" },               .{ .page_up, "Page_Up" },          .{ .page_down, "Page_Down" },
    .{ .up, "Up" },                 .{ .down, "Down" },                .{ .left, "Left" },
    .{ .right, "Right" },           .{ .num_lock, "Num_Lock" },        .{ .kp_0, "KP_0" },
    .{ .kp_1, "KP_1" },             .{ .kp_2, "KP_2" },                .{ .kp_3, "KP_3" },
    .{ .kp_4, "KP_4" },             .{ .kp_5, "KP_5" },                .{ .kp_6, "KP_6" },
    .{ .kp_7, "KP_7" },             .{ .kp_8, "KP_8" },                .{ .kp_9, "KP_9" },
    .{ .kp_decimal, "KP_Decimal" }, .{ .kp_divide, "KP_Divide" },      .{ .kp_multiply, "KP_Multiply" },
    .{ .kp_minus, "KP_Subtract" },  .{ .kp_plus, "KP_Add" },           .{ .kp_enter, "KP_Enter" },
    .{ .kp_equal, "KP_Equal" },
};

/// GTK's modifier names: which modifier each is, as a bit of Mods
/// (Ctrl, Shift, Alt, Super), then Meta and Hyper, which it has not
const mod_names = [_]struct { []const u8, u3 }{
    .{ "control", 0 }, .{ "ctrl", 0 }, .{ "primary", 0 }, .{ "ctl", 0 },
    .{ "shift", 1 },   .{ "alt", 2 },  .{ "mod1", 2 },    .{ "super", 3 },
    .{ "mod4", 3 },    .{ "meta", 4 }, .{ "hyper", 5 },
};

fn modIndex(name: []const u8) ?u3 {
    for (mod_names) |m| if (std.ascii.eqlIgnoreCase(m[0], name)) return m[1];
    return null;
}

/// "<Ctrl><Shift>Print"; null when the key has no GTK name here.
pub fn fromNeutral(a: Accel, buf: []u8) ?[]const u8 {
    var lower: [1]u8 = undefined;
    const key = gtkKeyName(a.key, &lower) orelse return null;
    var w: std.Io.Writer = .fixed(buf);
    const tags = [_][]const u8{ "<Ctrl>", "<Shift>", "<Alt>", "<Super>" };
    for (tags, 0..) |t, i| if (a.mods.has(i)) w.writeAll(t) catch return null;
    w.writeAll(key) catch return null;
    return w.buffered();
}

fn gtkKeyName(c: KeyCode, lower: *[1]u8) ?[]const u8 {
    if (c.letterChar()) |l| {
        lower[0] = std.ascii.toLower(l);
        return lower;
    }
    if (c.digitChar() != null or c.functionNumber() != null) return c.name();
    for (key_names) |k| if (k[0] == c) return k[1];
    return null;
}

/// The neutral shortcut of a GTK accelerator; null when it is none, or
/// names a modifier or key the neutral notation has no name for.
pub fn toNeutral(gtk: []const u8) ?Accel {
    var bits: u4 = 0;
    var i: usize = 0;
    while (i < gtk.len and gtk[i] == '<') {
        const end = std.mem.indexOfScalarPos(u8, gtk, i, '>') orelse return null;
        const m = modIndex(gtk[i + 1 .. end]) orelse return null;
        if (m > 3) return null;
        bits |= @as(u4, 1) << @intCast(m);
        i = end + 1;
    }
    const key = keyOf(gtk[i..]) orelse return null;
    return .{ .mods = @bitCast(bits), .key = key };
}

fn keyOf(name: []const u8) ?KeyCode {
    if (name.len == 1) return KeyCode.letter(name[0]) orelse KeyCode.digit(name[0]);
    for (key_names) |k| if (std.ascii.eqlIgnoreCase(k[1], name)) return k[0];
    const c = KeyCode.fromName(name) orelse return null;
    return if (c.functionNumber() != null) c else null;
}

/// A GTK accelerator as people read it: the neutral notation, or the
/// accelerator itself when that has no neutral name.
pub fn display(buf: []u8, gtk: []const u8) []const u8 {
    const a = toNeutral(gtk) orelse return gtk;
    return a.format(buf) orelse gtk;
}

/// A shortcut given on the command line as GTK writes it: the neutral
/// notation converted (null when GTK has no name for its key), anything
/// else (GTK's own notation) as it is.
pub fn fromUser(text: []const u8, buf: []u8) ?[]const u8 {
    const a = accel.parse(text) orelse return text;
    return fromNeutral(a, buf);
}

/// "<Ctrl><Shift>s" and "<Shift><Control>S" are the same key.
pub fn same(a: []const u8, b: []const u8) bool {
    var na: [128]u8 = undefined;
    var nb: [128]u8 = undefined;
    const x = normalize(a, &na) orelse return false;
    const y = normalize(b, &nb) orelse return false;
    return std.mem.eql(u8, x, y);
}

/// Modifier flags (mod_names' order), then the key in lower case.
fn normalize(gtk: []const u8, buf: []u8) ?[]const u8 {
    const order = "CSAWMH";
    var flags: [order.len]bool = @splat(false);
    var i: usize = 0;
    while (i < gtk.len and gtk[i] == '<') {
        const end = std.mem.indexOfScalarPos(u8, gtk, i, '>') orelse return null;
        flags[modIndex(gtk[i + 1 .. end]) orelse return null] = true;
        i = end + 1;
    }
    const key = gtk[i..];
    if (key.len == 0 or key.len + order.len + 1 > buf.len) return null;
    var n: usize = 0;
    for (flags, 0..) |on, k| if (on) {
        buf[n] = order[k];
        n += 1;
    };
    buf[n] = '+';
    n += 1;
    for (key) |c| {
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

test "GTK accelerators compare as keys" {
    const t = std.testing;
    try t.expect(same("Print", "print"));
    try t.expect(same("<Ctrl><Shift>s", "<Shift><Control>S"));
    try t.expect(same("<Primary>p", "<Control>p"));
    try t.expect(!same("<Shift>Print", "Print"));
    try t.expect(!same("<Super>s", "<Shift><Super>s"));
    try t.expect(!same("<Meta>s", "<Hyper>s"));
    try t.expect(!same("<Bogus>s", "s"));
}

test "GTK accelerators to the neutral notation and back" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    try t.expectEqualStrings("Shift+Super+S", display(&buf, "<Shift><Super>s"));
    try t.expectEqualStrings("Shift+Super+S", display(&buf, "<Super><Shift>S"));
    try t.expectEqualStrings("Ctrl+Print", display(&buf, "<Primary>Print"));
    try t.expectEqualStrings("Alt+PageUp", display(&buf, "<Mod1>Page_Up"));
    try t.expectEqualStrings("Super+F11", display(&buf, "<Super>F11"));
    // what has no neutral name shows as GNOME writes it
    try t.expectEqualStrings("<Hyper>s", display(&buf, "<Hyper>s"));
    try t.expectEqualStrings("XF86Tools", display(&buf, "XF86Tools"));
    for ([_][]const u8{ "Print", "<Ctrl>Print", "<Ctrl><Shift>f", "<Ctrl><Alt>w", "<Shift><Super>t", "<Super>space", "<Ctrl>KP_Add", "<Alt>4" }) |g| {
        const a = toNeutral(g).?;
        try t.expectEqualStrings(g, fromNeutral(a, &buf).?);
        try t.expect(a.eql(accel.parse(a.format(&buf2).?).?));
    }
    try t.expectEqual(@as(?[]const u8, null), fromNeutral(.{ .key = .intl_ro }, &buf));
}

test "the command line takes either notation" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("<Shift><Super>s", fromUser("Shift+Super+S", &buf).?);
    try t.expectEqualStrings("<Super>4", fromUser("super+4", &buf).?);
    try t.expectEqualStrings("<Primary>p", fromUser("<Primary>p", &buf).?);
    // a bare keysym name GTK knows and we do not: passed on
    try t.expectEqualStrings("XF86Tools", fromUser("XF86Tools", &buf).?);
}
