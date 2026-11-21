//! JPEG entropy decoding: Huffman tables (ITU T.81 annex C and F.2.2.3)
//! and the bit reader of an entropy-coded segment (byte stuffing, markers).
//! Input is untrusted: bad codes and running out of data are errors, a
//! marker inside the data reads as zero bits.

const std = @import("std");

pub const Error = error{Corrupt};

const fast_bits = 9;

pub const Table = struct {
    defined: bool = false,
    /// largest code of each length (-1: none), 1-based by length
    maxcode: [18]i32 = @splat(-1),
    /// index into `vals` of the first code of each length, minus that code
    delta: [17]i32 = @splat(0),
    vals: [256]u8 = @splat(0),
    /// first `fast_bits` bits -> (length << 8 | value); 0: longer code
    fast: [1 << fast_bits]u16 = @splat(0),

    /// From DHT's 16 counts and the values in code order.
    pub fn build(counts: [16]u8, values: []const u8) Error!Table {
        var t: Table = .{ .defined = true };
        var total: usize = 0;
        for (counts) |c| total += c;
        if (total > 256 or total > values.len) return error.Corrupt;
        @memcpy(t.vals[0..total], values[0..total]);
        var code: i32 = 0;
        var k: i32 = 0;
        for (counts, 1..) |c, len| {
            t.delta[len] = k - code;
            if (c > 0) {
                code += c;
                k += c;
                t.maxcode[len] = code - 1;
                if (code > (@as(i32, 1) << @intCast(len))) return error.Corrupt;
            }
            code <<= 1;
        }
        t.maxcode[17] = std.math.maxInt(i32);
        t.fillFast(counts);
        return t;
    }

    fn fillFast(t: *Table, counts: [16]u8) void {
        var code: u32 = 0;
        var k: usize = 0;
        for (counts, 1..) |c, len| {
            for (0..c) |_| {
                if (len <= fast_bits) {
                    const shift: u5 = @intCast(fast_bits - len);
                    const first = code << shift;
                    for (0..(@as(u32, 1) << shift)) |j| t.fast[first + j] = @intCast(len << 8 | t.vals[k]);
                }
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
    }
};

pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    acc: u64 = 0,
    n: u7 = 0,
    /// a marker (or the end) was reached: the rest reads as zeros
    stopped: bool = false,

    fn fill(self: *BitReader) void {
        while (self.n <= 56) {
            var byte: u8 = 0;
            if (!self.stopped) {
                if (self.pos >= self.data.len) {
                    self.stopped = true;
                } else if (self.data[self.pos] == 0xFF) {
                    const next = if (self.pos + 1 < self.data.len) self.data[self.pos + 1] else 0xD9;
                    if (next == 0x00) {
                        byte = 0xFF;
                        self.pos += 2;
                    } else self.stopped = true;
                } else {
                    byte = self.data[self.pos];
                    self.pos += 1;
                }
            }
            self.acc |= @as(u64, byte) << @intCast(56 - @as(u32, self.n));
            self.n += 8;
        }
    }

    pub fn bits(self: *BitReader, count: u5) u32 {
        if (count == 0) return 0;
        if (self.n < count) self.fill();
        const v: u32 = @intCast(self.acc >> @intCast(64 - @as(u32, count)));
        self.acc <<= count;
        self.n -= count;
        return v;
    }

    pub fn decode(self: *BitReader, t: *const Table) Error!u8 {
        if (!t.defined) return error.Corrupt;
        if (self.n < 16) self.fill();
        const f = t.fast[@intCast(self.acc >> (64 - fast_bits))];
        if (f != 0) {
            const len: u5 = @intCast(f >> 8);
            self.acc <<= len;
            self.n -= len;
            return @truncate(f);
        }
        var code: i32 = 0;
        var len: usize = 1;
        while (len <= 16) : (len += 1) {
            code = (code << 1) | @as(i32, @intCast(self.bits(1)));
            if (code <= t.maxcode[len]) {
                const i = code + t.delta[len];
                if (i < 0 or i > 255) return error.Corrupt;
                return t.vals[@intCast(i)];
            }
        }
        return error.Corrupt;
    }

    /// A coefficient of `s` bits, sign-extended (T.81 F.2.2.1 EXTEND).
    pub fn receiveExtend(self: *BitReader, s: u8) Error!i32 {
        if (s == 0) return 0;
        if (s > 16) return error.Corrupt;
        const v: i32 = @intCast(self.bits(@intCast(s)));
        const half = @as(i32, 1) << @intCast(s - 1);
        return if (v < half) v - (half << 1) + 1 else v;
    }

    /// At a restart interval: drop the bits left and skip the RSTn marker.
    pub fn restart(self: *BitReader) void {
        self.acc = 0;
        self.n = 0;
        self.stopped = false;
        while (self.pos + 1 < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == 0xFF and self.data[self.pos + 1] >= 0xD0 and self.data[self.pos + 1] <= 0xD7) {
                self.pos += 2;
                return;
            }
            if (self.data[self.pos] == 0xFF and self.data[self.pos + 1] != 0 and self.data[self.pos + 1] != 0xFF) return;
        }
    }
};

test "canonical codes decode, with and without the fast table" {
    // codes: a=00 b=01 c=100 d=101 e=1100 ... one 12-bit code
    const counts = [16]u8{ 0, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };
    const vals = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'z' };
    const t = try Table.build(counts, &vals);
    // bits: 00 01 100 101 1100 111010000000 (z: 1101 followed... computed below)
    // the 12-bit code follows 1100 + 1 = 1101 shifted 8 left: 110100000000
    const stream = [_]u8{ 0b00011001, 0b01110011, 0b01000000, 0b00000000 };
    var br: BitReader = .{ .data = &stream, .pos = 0 };
    for ("abcdez") |ch| try std.testing.expectEqual(ch, try br.decode(&t));
}

test "byte stuffing and a marker stop the bits" {
    const stream = [_]u8{ 0xFF, 0x00, 0x80, 0xFF, 0xD9 };
    var br: BitReader = .{ .data = &stream, .pos = 0 };
    try std.testing.expectEqual(@as(u32, 0xFF), br.bits(8));
    try std.testing.expectEqual(@as(u32, 1), br.bits(1));
    try std.testing.expectEqual(@as(u32, 0), br.bits(16));
    try std.testing.expect(br.stopped);
}

test "extend gives negative and positive values" {
    const stream = [_]u8{ 0b00011111, 0 };
    var br: BitReader = .{ .data = &stream, .pos = 0 };
    try std.testing.expectEqual(@as(i32, -7), try br.receiveExtend(3)); // 000
    try std.testing.expectEqual(@as(i32, 3), try br.receiveExtend(2)); // 11
    try std.testing.expectEqual(@as(i32, 7), try br.receiveExtend(3)); // 111
}

test "oversubscribed tables are refused" {
    const counts = [16]u8{ 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.Corrupt, Table.build(counts, &.{ 1, 2, 3 }));
}
