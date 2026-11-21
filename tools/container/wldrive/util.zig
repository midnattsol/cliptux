//! shotlet-wldrive's small helpers: key names and modifier masks, colour
//! blobs, and string and time utilities.

const std = @import("std");

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn trimHex(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
}

pub fn sleepMs(ms: u32) void {
    var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// evdev key codes by name (US physical positions)
pub fn keyCode(name: []const u8) ?u32 {
    if (name.len > 1 and name[0] == '#') return std.fmt.parseInt(u32, name[1..], 10) catch null;
    if (name.len == 1) {
        const c = name[0];
        if (std.mem.indexOfScalar(u8, "qwertyuiop", c)) |i| return @intCast(16 + i);
        if (std.mem.indexOfScalar(u8, "asdfghjkl", c)) |i| return @intCast(30 + i);
        if (std.mem.indexOfScalar(u8, "zxcvbnm", c)) |i| return @intCast(44 + i);
        if (c >= '1' and c <= '9') return @intCast(2 + c - '1');
        if (c == '0') return 11;
    }
    const table = [_]struct { []const u8, u32 }{
        .{ "esc", 1 },        .{ "minus", 12 },     .{ "equal", 13 },      .{ "backspace", 14 },
        .{ "tab", 15 },       .{ "leftbrace", 26 }, .{ "rightbrace", 27 }, .{ "enter", 28 },
        .{ "ctrl", 29 },      .{ "semicolon", 39 }, .{ "apostrophe", 40 }, .{ "grave", 41 },
        .{ "shift", 42 },     .{ "backslash", 43 }, .{ "comma", 51 },      .{ "dot", 52 },
        .{ "slash", 53 },     .{ "rshift", 54 },    .{ "alt", 56 },        .{ "space", 57 },
        .{ "capslock", 58 },  .{ "f1", 59 },        .{ "f2", 60 },         .{ "rctrl", 97 },
        .{ "altgr", 100 },    .{ "home", 102 },     .{ "up", 103 },        .{ "pageup", 104 },
        .{ "left", 105 },     .{ "right", 106 },    .{ "end", 107 },       .{ "down", 108 },
        .{ "pagedown", 109 }, .{ "insert", 110 },   .{ "delete", 111 },    .{ "super", 125 },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
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

/// xkb modifier masks of the us keymap's modifier keys
pub fn modMask(code: u32) u32 {
    return switch (code) {
        42, 54 => 1, // Shift
        29, 97 => 4, // Control
        56 => 8, // Mod1 (Alt)
        125 => 64, // Mod4 (Super)
        100 => 128, // Mod5 (AltGr)
        else => 0,
    };
}

/// Within `t` per channel of `c`.
fn near(p: u32, c: u32, t: u32) bool {
    inline for (.{ 0, 8, 16 }) |sh| {
        const a: i32 = @intCast((p >> sh) & 0xFF);
        const b: i32 = @intCast((c >> sh) & 0xFF);
        if (@abs(a - b) > t) return false;
    }
    return true;
}

/// Paint every pixel outside `region` (x0, y0, x1, y1) with `~rgb`, so a
/// search for `rgb` never matches there.
pub fn maskOutside(px: []u32, w: u32, region: [4]u32, rgb: u32) void {
    for (px, 0..) |*p, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        if (x < region[0] or y < region[1] or x >= region[2] or y >= region[3]) p.* = ~rgb;
    }
}

/// Bounding box (x0, y0, x1, y1) of the first blob, in reading order, at
/// least `min_w` wide, of pixels within `tol` (per channel) of `rgb`.
pub fn findBlob(gpa: std.mem.Allocator, px: []const u32, w: u32, h: u32, rgb: u32, tol: u32, min_w: u32) ![4]u32 {
    var seen = try gpa.alloc(bool, px.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (px, 0..) |p, start| {
        if (seen[start] or !near(p, rgb, tol)) continue;
        try stack.append(gpa, start);
        seen[start] = true;
        var box = [4]u32{ w, h, 0, 0 };
        while (stack.pop()) |i| {
            const x: u32 = @intCast(i % w);
            const y: u32 = @intCast(i / w);
            box = .{ @min(box[0], x), @min(box[1], y), @max(box[2], x), @max(box[3], y) };
            const nbrs = [4]?usize{
                if (x > 0) i - 1 else null,
                if (x + 1 < w) i + 1 else null,
                if (y > 0) i - w else null,
                if (y + 1 < h) i + w else null,
            };
            for (nbrs) |n| if (n) |j| if (!seen[j] and near(px[j], rgb, tol)) {
                seen[j] = true;
                try stack.append(gpa, j);
            };
        }
        if (box[2] - box[0] + 1 >= min_w) return box;
    }
    return error.NotFound;
}
