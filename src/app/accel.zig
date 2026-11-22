//! GNOME accelerator strings ("<Ctrl><Shift>s"): telling when two name
//! the same key.

const std = @import("std");

/// "<Ctrl><Shift>s" and "<Shift><Control>S" are the same key.
pub fn sameAccel(a: []const u8, b: []const u8) bool {
    var na: [128]u8 = undefined;
    var nb: [128]u8 = undefined;
    const x = normalizeAccel(a, &na) orelse return false;
    const y = normalizeAccel(b, &nb) orelse return false;
    return std.mem.eql(u8, x, y);
}

/// Modifier flags, then the key in lower case.
fn normalizeAccel(accel: []const u8, buf: []u8) ?[]const u8 {
    const mods = [_]struct { []const u8, u8 }{
        .{ "shift", 'S' }, .{ "control", 'C' }, .{ "ctrl", 'C' },  .{ "primary", 'C' },
        .{ "ctl", 'C' },   .{ "alt", 'A' },     .{ "mod1", 'A' },  .{ "super", 'W' },
        .{ "mod4", 'W' },  .{ "meta", 'M' },    .{ "hyper", 'H' },
    };
    var flags: [6]bool = @splat(false);
    const order = "SCAWMH";
    var i: usize = 0;
    while (i < accel.len and accel[i] == '<') {
        const end = std.mem.indexOfScalarPos(u8, accel, i, '>') orelse return null;
        const name = accel[i + 1 .. end];
        const f = for (mods) |m| {
            if (std.ascii.eqlIgnoreCase(m[0], name)) break m[1];
        } else return null;
        flags[std.mem.indexOfScalar(u8, order, f).?] = true;
        i = end + 1;
    }
    const key = accel[i..];
    if (key.len == 0 or key.len + 6 > buf.len) return null;
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

/// "<Shift><Super>s" as people read it: "Shift+Super+S".
pub fn display(buf: []u8, accel: []const u8) []const u8 {
    // "<Shift><Super>s" -> "Shift+Super+S"
    var n: usize = 0;
    var i: usize = 0;
    while (i < accel.len) {
        if (accel[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, accel, i, '>') orelse break;
            const name = accel[i + 1 .. end];
            if (n + name.len + 1 > buf.len) break;
            @memcpy(buf[n..][0..name.len], name);
            n += name.len;
            buf[n] = '+';
            n += 1;
            i = end + 1;
        } else {
            const key = accel[i..];
            if (n + key.len > buf.len) break;
            @memcpy(buf[n..][0..key.len], key);
            if (key.len == 1) buf[n] = std.ascii.toUpper(key[0]);
            n += key.len;
            break;
        }
    }
    return buf[0..n];
}

test "accelerators compare as keys" {
    try std.testing.expect(sameAccel("Print", "print"));
    try std.testing.expect(sameAccel("<Ctrl><Shift>s", "<Shift><Control>S"));
    try std.testing.expect(sameAccel("<Primary>p", "<Control>p"));
    try std.testing.expect(!sameAccel("<Shift>Print", "Print"));
    try std.testing.expect(!sameAccel("<Super>s", "<Shift><Super>s"));
    try std.testing.expect(!sameAccel("<Bogus>s", "s"));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Shift+Super+S", display(&b, "<Shift><Super>s"));
    try std.testing.expectEqualStrings("Print", display(&b, "Print"));
}
