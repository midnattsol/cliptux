//! Searching recognised text: every word of a query, ignoring case and
//! the accents of Latin letters (the history panel's search field).

const std = @import("std");

/// Search for every word of `query` in `hay`, ignoring case and the
/// accents of Latin letters: "cancion" finds "Canción", "ESPAÑA" finds
/// "españa" (recognised text often gets accents wrong anyway).
pub fn matches(hay: []const u8, query: []const u8) bool {
    var hbuf: [8192]u8 = undefined;
    var qbuf: [256]u8 = undefined;
    const h = fold(&hbuf, hay);
    var words = std.mem.tokenizeAny(u8, fold(&qbuf, query), " \t");
    while (words.next()) |w| {
        if (std.mem.indexOf(u8, h, w) == null) return false;
    }
    return true;
}

/// Lowercase ASCII with Latin-1 and Latin Extended-A letters reduced to
/// their base letter; other text is copied as is. Cut at `buf`'s size.
fn fold(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (len > 1 and i + len <= s.len) {
            if (std.unicode.utf8Decode(s[i..][0..len])) |cp| {
                if (baseLetter(cp)) |b| {
                    buf[n] = b;
                    n += 1;
                    i += len;
                    continue;
                }
            } else |_| {}
            if (n + len > buf.len) break;
            @memcpy(buf[n..][0..len], s[i..][0..len]);
            n += len;
            i += len;
            continue;
        }
        buf[n] = std.ascii.toLower(s[i]);
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

/// The unaccented lowercase letter of an accented Latin one.
fn baseLetter(cp: u21) ?u8 {
    // U+00C0..U+00FF, by code point (0 where there is no plain letter)
    const latin1 = "aaaaaaaceeeeiiii" ++ "dnooooo\x00ouuuuyts" ++ "aaaaaaaceeeeiiii" ++ "dnooooo\x00ouuuuyty";
    if (cp >= 0xC0 and cp <= 0xFF) {
        const b = latin1[cp - 0xC0];
        return if (b == 0) null else b;
    }
    // U+0100..U+017F come in upper/lower pairs, mostly
    const ext_a = "aaaaaaccccccccdddd" ++ "eeeeeeeeeegggggggghhhh" ++ "iiiiiiiiiijjjjkkk" ++ "llllllllllnnnnnnnnn" ++ "oooooooorrrrrrssssssss" ++ "ttttttuuuuuuuuuuuuwwyyyzzzzzzs";
    if (cp >= 0x100 and cp <= 0x17F) return ext_a[cp - 0x100];
    return null;
}

test "search matches every word, ignoring case and accents" {
    try std.testing.expect(matches("Hello World\nfoo", "world HELLO"));
    try std.testing.expect(!matches("Hello World", "world bar"));
    try std.testing.expect(matches("anything", ""));
    try std.testing.expect(matches("Canción del año en España", "cancion ESPAÑA ano"));
    try std.testing.expect(matches("CANCIÓN", "canción"));
    try std.testing.expect(matches("Łódź, Žluťoučký", "lodz zlutoucky"));
    try std.testing.expect(!matches("Canción", "cantion"));
    // other scripts are compared as they are
    try std.testing.expect(matches("日本語のテキスト", "テキスト"));
}
