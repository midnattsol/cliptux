//! Key names for the editor's scripted input (SHOTLET_EDITOR_SCRIPT):
//! "ctrl+shift+s", "alt+left", "esc", "?", and number lists.

const std = @import("std");
const window = @import("window.zig");
const Point = @import("shapes.zig").Point;

const KEY_TAB = 15;
const KEY_RIGHTBRACE = 27;
const KEY_S = 31;
const KEY_SLASH = 53;
const KEY_F1 = 59;
const KEY_HOME = 102;
const KEY_UP = 103;
const KEY_LEFT = 105;
const KEY_RIGHT = 106;
const KEY_END = 107;
const KEY_DOWN = 108;

/// US-layout key -> character, only to turn script key names into codes.
fn usKeyChar(code: u32, shift: bool) ?u8 {
    const lower = "1234567890";
    const upper = "!@#$%^&*()";
    if (code >= 2 and code <= 11) {
        const i = code - 2;
        return if (shift) upper[i] else lower[i];
    }
    const row1 = "qwertyuiop";
    if (code >= 16 and code <= 25) {
        const c = row1[code - 16];
        return if (shift) c - 32 else c;
    }
    const row2 = "asdfghjkl";
    if (code >= 30 and code <= 38) {
        const c = row2[code - 30];
        return if (shift) c - 32 else c;
    }
    const row3 = "zxcvbnm";
    if (code >= 44 and code <= 50) {
        const c = row3[code - 44];
        return if (shift) c - 32 else c;
    }
    return switch (code) {
        57 => ' ',
        12 => if (shift) @as(u8, '_') else '-',
        13 => if (shift) @as(u8, '+') else '=',
        26 => if (shift) @as(u8, '{') else '[',
        27 => if (shift) @as(u8, '}') else ']',
        39 => if (shift) @as(u8, ':') else ';',
        40 => if (shift) @as(u8, '"') else '\'',
        41 => if (shift) @as(u8, '~') else '`',
        43 => if (shift) @as(u8, '|') else '\\',
        51 => if (shift) @as(u8, '<') else ',',
        52 => if (shift) @as(u8, '>') else '.',
        53 => if (shift) @as(u8, '?') else '/',
        else => null,
    };
}

pub fn parseInts(comptime n: usize, s: []const u8) ![n]i32 {
    var out: [n]i32 = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    for (&out) |*v| v.* = try std.fmt.parseInt(i32, std.mem.trim(u8, it.next() orelse return error.BadScript, " "), 10);
    return out;
}

pub fn parsePoint(s: []const u8) !Point {
    const v = try parseInts(2, s);
    return .{ .x = v[0], .y = v[1] };
}

/// "ctrl+shift+s", "alt+left", "esc", "?" ... for scripted input.
pub fn parseKey(spec: []const u8) !window.Key {
    var k: window.Key = .{ .code = 0, .pressed = true, .ctrl = false, .shift = false };
    var it = std.mem.splitScalar(u8, spec, '+');
    var name: []const u8 = "";
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "ctrl")) k.ctrl = true else if (std.mem.eql(u8, part, "shift")) k.shift = true else if (std.mem.eql(u8, part, "alt")) k.alt = true else name = part;
    }
    const named = [_]struct { []const u8, u32 }{
        .{ "esc", window.KEY_ESC },             .{ "enter", window.KEY_ENTER },   .{ "tab", KEY_TAB },
        .{ "backspace", window.KEY_BACKSPACE }, .{ "delete", window.KEY_DELETE }, .{ "space", window.KEY_SPACE },
        .{ "left", KEY_LEFT },                  .{ "right", KEY_RIGHT },          .{ "up", KEY_UP },
        .{ "down", KEY_DOWN },                  .{ "home", KEY_HOME },            .{ "end", KEY_END },
        .{ "f1", KEY_F1 },                      .{ "]", KEY_RIGHTBRACE },         .{ "?", KEY_SLASH },
    };
    for (named) |n| {
        if (std.mem.eql(u8, name, n[0])) k.code = n[1];
    }
    if (std.mem.eql(u8, name, "?")) k.shift = true;
    if (k.code == 0 and name.len == 1) {
        var code: u32 = 1;
        while (code < 60) : (code += 1) {
            if (usKeyChar(code, false) == name[0]) {
                k.code = code;
                break;
            }
        }
    }
    if (k.code == 0) return error.BadKey;
    if (!k.ctrl) if (usKeyChar(k.code, k.shift)) |c| {
        k.text_buf[0] = c;
        k.text_len = 1;
    };
    return k;
}

test "scripted keys parse" {
    const k = try parseKey("ctrl+shift+s");
    try std.testing.expect(k.ctrl and k.shift);
    try std.testing.expectEqual(@as(u32, KEY_S), k.code);
    const q = try parseKey("?");
    try std.testing.expectEqualStrings("?", q.text());
    try std.testing.expectEqual(@as(u32, KEY_LEFT), (try parseKey("alt+left")).code);
}
