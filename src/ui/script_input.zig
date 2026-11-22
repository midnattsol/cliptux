//! The editor's scripted input (SHOTLET_EDITOR_SCRIPT, for tests): key
//! names like "ctrl+shift+s" and "x,y" points.

const std = @import("std");
const window = @import("../platform/api.zig").window;
const Point = @import("shapes.zig").Point;

const KeyCode = window.KeyCode;

/// US-layout key -> character, only to turn script key names into codes.
fn usKeyChar(code: KeyCode, shift: bool) ?u8 {
    if (code.letterChar()) |c| return if (shift) c else std.ascii.toLower(c);
    if (code.digitChar()) |d| return if (shift) ")!@#$%^&*("[d - '0'] else d;
    const lower_upper: [2]u8 = switch (code) {
        .space => .{ ' ', ' ' },
        .minus => "-_".*,
        .equal => "=+".*,
        .bracket_left => "[{".*,
        .bracket_right => "]}".*,
        .semicolon => ";:".*,
        .quote => "'\"".*,
        .backquote => "`~".*,
        .backslash => "\\|".*,
        .comma => ",<".*,
        .period => ".>".*,
        .slash => "/?".*,
        else => return null,
    };
    return lower_upper[@intFromBool(shift)];
}

/// The key typing `c` unshifted on a US layout.
fn usKeyOf(c: u8) ?KeyCode {
    for (std.meta.tags(KeyCode)) |code| if (usKeyChar(code, false) == c) return code;
    return null;
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
    var k: window.Key = .{ .code = .none, .pressed = true, .ctrl = false, .shift = false };
    var it = std.mem.splitScalar(u8, spec, '+');
    var name: []const u8 = "";
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "ctrl")) k.ctrl = true else if (std.mem.eql(u8, part, "shift")) k.shift = true else if (std.mem.eql(u8, part, "alt")) k.alt = true else name = part;
    }
    const named = [_]struct { []const u8, KeyCode }{
        .{ "esc", .escape },          .{ "enter", .enter },     .{ "tab", .tab },
        .{ "backspace", .backspace }, .{ "delete", .delete },   .{ "space", .space },
        .{ "left", .left },           .{ "right", .right },     .{ "up", .up },
        .{ "down", .down },           .{ "home", .home },       .{ "end", .end },
        .{ "f1", .f1 },               .{ "]", .bracket_right }, .{ "?", .slash },
    };
    for (named) |n| {
        if (std.mem.eql(u8, name, n[0])) k.code = n[1];
    }
    if (std.mem.eql(u8, name, "?")) k.shift = true;
    if (k.code == .none and name.len == 1) k.code = usKeyOf(name[0]) orelse .none;
    if (k.code == .none) return error.BadKey;
    if (!k.ctrl) if (usKeyChar(k.code, k.shift)) |c| {
        k.text_buf[0] = c;
        k.text_len = 1;
    };
    return k;
}

test "scripted keys parse" {
    const k = try parseKey("ctrl+shift+s");
    try std.testing.expect(k.ctrl and k.shift);
    try std.testing.expectEqual(KeyCode.s, k.code);
    const q = try parseKey("?");
    try std.testing.expectEqualStrings("?", q.text());
    try std.testing.expectEqual(KeyCode.left, (try parseKey("alt+left")).code);
    try std.testing.expectEqual(KeyCode.digit_1, (try parseKey("1")).code);
    try std.testing.expectEqualStrings("!", (try parseKey("shift+1")).text());
    try std.testing.expectEqualStrings("\\", (try parseKey("\\")).text());
}
