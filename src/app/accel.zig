//! Shortcuts in Shotlet's own notation, whatever the desktop: modifiers,
//! then the key, joined by '+' ("Print", "Ctrl+Print", "Shift+Super+S",
//! "Super+4"). Modifiers come in the order Ctrl, Shift, Alt, Super; keys
//! are named as api/keys.zig names them (KeyCode.name), any case.
//!
//! In a global shortcut a letter or digit stands for the key typing it in
//! the active layout, as desktops match them; other keys are the key
//! itself. A backend converts to its desktop's notation (GNOME: GTK's
//! "<Shift><Super>s", linux/gnome/gtk_accel.zig).

const std = @import("std");
const KeyCode = @import("../platform/api/keys.zig").Code;

pub const Mods = packed struct(u4) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,

    /// in bit order
    pub const names = [_][]const u8{ "Ctrl", "Shift", "Alt", "Super" };

    pub fn has(m: Mods, i: usize) bool {
        return @as(u4, @bitCast(m)) & (@as(u4, 1) << @intCast(i)) != 0;
    }
};

pub const Accel = struct {
    mods: Mods = .{},
    key: KeyCode,

    /// "Ctrl+Shift+Print"; null when `buf` is too small or the key has no
    /// name.
    pub fn format(self: Accel, buf: []u8) ?[]const u8 {
        const key = self.key.name() orelse return null;
        var w: std.Io.Writer = .fixed(buf);
        for (Mods.names, 0..) |n, i| if (self.mods.has(i)) w.print("{s}+", .{n}) catch return null;
        w.writeAll(key) catch return null;
        return w.buffered();
    }

    pub fn eql(a: Accel, b: Accel) bool {
        return a.key == b.key and a.mods == b.mods;
    }
};

/// "Shift+Super+S", "ctrl+print" ...; null when it is not one (an unknown
/// modifier or key, a modifier twice, no key).
pub fn parse(text: []const u8) ?Accel {
    var bits: u4 = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " "), '+');
    var part = it.first();
    while (it.next()) |next| : (part = next) {
        const bit = modBit(part) orelse return null;
        if (bits & bit != 0) return null;
        bits |= bit;
    }
    const key = KeyCode.fromName(part) orelse return null;
    if (key.isModifier()) return null;
    return .{ .mods = @bitCast(bits), .key = key };
}

fn modBit(name: []const u8) ?u4 {
    const aliases = [_]struct { []const u8, u2 }{
        .{ "ctrl", 0 }, .{ "control", 0 }, .{ "shift", 1 }, .{ "alt", 2 }, .{ "super", 3 },
    };
    for (aliases) |a| if (std.ascii.eqlIgnoreCase(a[0], name)) return @as(u4, 1) << a[1];
    return null;
}

test "shortcuts read and print in the neutral notation" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const a = parse("Shift+Super+S").?;
    try t.expect(a.mods.shift and a.mods.super and !a.mods.ctrl and a.key == .s);
    try t.expectEqualStrings("Shift+Super+S", a.format(&buf).?);
    // any case and order in, canonical order out
    try t.expectEqualStrings("Ctrl+Shift+Print", parse("shift+CONTROL+print").?.format(&buf).?);
    try t.expectEqualStrings("Super+4", parse("Super+4").?.format(&buf).?);
    try t.expectEqualStrings("Print", parse("Print").?.format(&buf).?);
    try t.expectEqualStrings("Alt+PageUp", parse("alt+pgup").?.format(&buf).?);
    try t.expect(parse("Ctrl+Print").?.eql(.{ .mods = .{ .ctrl = true }, .key = .print }));
    try t.expect(!parse("Ctrl+Print").?.eql(.{ .key = .print }));
}

test "what is not a shortcut" {
    const t = std.testing;
    for ([_][]const u8{ "", "+", "Ctrl+", "Ctrl+Ctrl+S", "Hyper+S", "Ctrl+Banana", "Shift", "Ctrl+ShiftLeft", "Super+S+" }) |s|
        try t.expectEqual(@as(?Accel, null), parse(s));
    var small: [4]u8 = undefined;
    try t.expectEqual(@as(?[]const u8, null), parse("Ctrl+Print").?.format(&small));
    try t.expectEqual(@as(?[]const u8, null), (Accel{ .key = .other }).format(&small));
}
