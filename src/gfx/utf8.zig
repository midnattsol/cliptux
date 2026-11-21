//! Lossy UTF-8 decoding: invalid or truncated sequences decode to U+FFFD
//! (one per maximal invalid subpart, as WHATWG/Unicode recommend) instead
//! of hitting `unreachable`. Use it for any text that is measured or drawn.

const std = @import("std");

pub const replacement: u21 = 0xFFFD;

pub const Iterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn init(s: []const u8) Iterator {
        return .{ .bytes = s };
    }

    pub fn next(self: *Iterator) ?u21 {
        const s = self.bytes;
        if (self.i >= s.len) return null;
        const b0 = s[self.i];
        if (b0 < 0x80) {
            self.i += 1;
            return b0;
        }
        // sequence length and the valid range of the second byte
        var len: usize = 0;
        var lo: u8 = 0x80;
        var hi: u8 = 0xBF;
        var cp: u21 = 0;
        switch (b0) {
            0xC2...0xDF => {
                len = 2;
                cp = b0 & 0x1F;
            },
            0xE0...0xEF => {
                len = 3;
                cp = b0 & 0x0F;
                if (b0 == 0xE0) lo = 0xA0; // no overlongs
                if (b0 == 0xED) hi = 0x9F; // no surrogates
            },
            0xF0...0xF4 => {
                len = 4;
                cp = b0 & 0x07;
                if (b0 == 0xF0) lo = 0x90;
                if (b0 == 0xF4) hi = 0x8F; // <= U+10FFFF
            },
            else => {
                self.i += 1;
                return replacement;
            },
        }
        var k: usize = 1;
        while (k < len) : (k += 1) {
            const pos = self.i + k;
            if (pos >= s.len) break;
            const b = s[pos];
            const l: u8 = if (k == 1) lo else 0x80;
            const h: u8 = if (k == 1) hi else 0xBF;
            if (b < l or b > h) break;
            cp = (cp << 6) | (b & 0x3F);
        }
        if (k < len) {
            self.i += k; // skip the valid prefix of the broken sequence
            return replacement;
        }
        self.i += len;
        return cp;
    }
};

/// Number of codepoints `s` decodes to (lossily).
pub fn count(s: []const u8) usize {
    var it = Iterator.init(s);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// Length of the longest prefix of `s` (at most `max` bytes) that does not
/// end inside a valid multi-byte sequence: use it to cut strings safely.
pub fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // back up over continuation bytes (at most 3)
    var back: usize = 0;
    while (end > 0 and back < 3 and s[end] & 0xC0 == 0x80) : (back += 1) end -= 1;
    return s[0..end];
}

test "lossy decoding" {
    const T = struct {
        fn collect(s: []const u8, out: []u21) []u21 {
            var it = Iterator.init(s);
            var n: usize = 0;
            while (it.next()) |c| : (n += 1) out[n] = c;
            return out[0..n];
        }
    };
    var buf: [32]u21 = undefined;
    try std.testing.expectEqualSlices(u21, &.{ 'a', 0xE9, 0x6F22, 0x1F600 }, T.collect("a\xC3\xA9\xE6\xBC\xA2\xF0\x9F\x98\x80", &buf));
    // truncated 3-byte sequence at the end: one U+FFFD
    try std.testing.expectEqualSlices(u21, &.{ 'x', replacement }, T.collect("x\xE6\xBC", &buf));
    // lone continuation, overlong, surrogate, > U+10FFFF
    try std.testing.expectEqualSlices(u21, &.{ replacement, replacement, replacement }, T.collect("\x80\xC0\xAF", &buf));
    try std.testing.expectEqualSlices(u21, &.{ replacement, replacement, replacement }, T.collect("\xED\xA0\x80", &buf));
    try std.testing.expectEqual(@as(usize, 4), count("\xF4\x90\x80\x80"));
    // every byte string decodes without panicking
    var prng = std.Random.DefaultPrng.init(1);
    var junk: [64]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&junk);
        _ = count(&junk);
    }
    try std.testing.expectEqualStrings("a", truncate("a\xC3\xA9", 2));
    try std.testing.expectEqualStrings("a\xC3\xA9", truncate("a\xC3\xA9b", 3));
}
