//! Colour values as text (`#RRGGBB`, `rgb(r, g, b)`) and the colour
//! picker's history of recently picked colours.

const std = @import("std");

pub const Format = enum { hex, rgb };

/// `#RRGGBB` (alpha ignored).
pub fn hex(buf: []u8, c: u32) []const u8 {
    return std.fmt.bufPrint(buf, "#{X:0>6}", .{c & 0xFFFFFF}) catch "#000000";
}

/// `rgb(r, g, b)`, as CSS writes it.
pub fn rgb(buf: []u8, c: u32) []const u8 {
    return std.fmt.bufPrint(buf, "rgb({d}, {d}, {d})", .{ (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF }) catch "rgb(0, 0, 0)";
}

pub fn format(buf: []u8, c: u32, f: Format) []const u8 {
    return switch (f) {
        .hex => hex(buf, c),
        .rgb => rgb(buf, c),
    };
}

/// `#RGB`, `#RRGGBB` or `RRGGBB` back to an opaque colour.
pub fn parseHex(s_in: []const u8) ?u32 {
    const s = if (s_in.len > 0 and s_in[0] == '#') s_in[1..] else s_in;
    switch (s.len) {
        6 => return 0xFF000000 | (std.fmt.parseInt(u32, s, 16) catch return null),
        3 => {
            const v = std.fmt.parseInt(u32, s, 16) catch return null;
            const r = (v >> 8) & 0xF;
            const g = (v >> 4) & 0xF;
            const b = v & 0xF;
            return 0xFF000000 | (r * 17) << 16 | (g * 17) << 8 | (b * 17);
        },
        else => return null,
    }
}

/// The last few picked colours, newest first, each once.
pub const History = struct {
    pub const cap = 6;
    items: [cap]u32 = undefined,
    len: u8 = 0,

    pub fn add(self: *History, c_in: u32) void {
        const c = c_in | 0xFF000000;
        var n: usize = self.len;
        // already there: move it to the front
        for (self.items[0..self.len], 0..) |x, i| {
            if (x == c) {
                n = i;
                break;
            }
        } else if (self.len < cap) {
            self.len += 1;
        } else n = cap - 1;
        std.mem.copyBackwards(u32, self.items[1 .. n + 1], self.items[0..n]);
        self.items[0] = c;
    }

    pub fn slice(self: *const History) []const u32 {
        return self.items[0..self.len];
    }
};

test "colour text formats" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("#FF453A", hex(&buf, 0xFFFF453A));
    try std.testing.expectEqualStrings("#00000A", hex(&buf, 0x0000000A));
    try std.testing.expectEqualStrings("rgb(255, 69, 58)", rgb(&buf, 0xFFFF453A));
    try std.testing.expectEqualStrings("rgb(0, 0, 0)", format(&buf, 0xFF000000, .rgb));
    try std.testing.expectEqual(@as(?u32, 0xFFFF453A), parseHex("#ff453a"));
    try std.testing.expectEqual(@as(?u32, 0xFFFFAA00), parseHex("fa0"));
    try std.testing.expectEqual(@as(?u32, null), parseHex("#12345"));
    try std.testing.expectEqual(@as(?u32, null), parseHex("#zzzzzz"));
    // round trip
    for ([_]u32{ 0xFF000000, 0xFFFFFFFF, 0xFF15AABF }) |c| try std.testing.expectEqual(@as(?u32, c), parseHex(hex(&buf, c)));
}

test "history keeps the newest first, each colour once, a few of them" {
    var h: History = .{};
    h.add(1);
    h.add(2);
    h.add(3);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF000003, 0xFF000002, 0xFF000001 }, h.slice());
    h.add(1);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF000001, 0xFF000003, 0xFF000002 }, h.slice());
    for (10..20) |c| h.add(@intCast(c));
    try std.testing.expectEqual(@as(usize, History.cap), h.slice().len);
    try std.testing.expectEqual(@as(u32, 0xFF000013), h.slice()[0]);
    try std.testing.expectEqual(@as(u32, 0xFF00000E), h.slice()[5]);
    // an existing colour at the end moves to the front without loss
    h.add(0xE);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF00000E, 0xFF000013, 0xFF000012, 0xFF000011, 0xFF000010, 0xFF00000F }, h.slice());
}
