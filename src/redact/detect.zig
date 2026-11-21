//! Finding sensitive data in recognised text, for "Redact sensitive
//! data": e-mail addresses, phone numbers, card numbers (Luhn), IBANs
//! (mod 97), IP addresses, JSON Web Tokens, API keys with a known prefix
//! and other long random-looking tokens. Everything runs locally; nothing
//! is sent anywhere.

const std = @import("std");

pub const Kind = enum { email, phone, card, iban, ip, jwt, api_key, token };

pub const Match = struct { start: usize, end: usize, kind: Kind };

/// Every match in `text`, left to right, without overlaps.
pub fn find(alloc: std.mem.Allocator, text: []const u8) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (i > 0 and isWordChar(text[i - 1]) and isWordChar(text[i])) {
            i += 1;
            continue;
        }
        if (matchAt(text, i)) |m| {
            try out.append(alloc, m);
            i = m.end;
        } else i = skipNumber(text, i);
    }
    return out.toOwnedSlice(alloc);
}

/// Past a number that matched nothing (its later groups are no number
/// of their own: "4111 1111 1111 1112" is not a phone number).
fn skipNumber(text: []const u8, i: usize) usize {
    // an IBAN that failed its check: none of its groups either
    if (i + 4 <= text.len and std.ascii.isUpper(text[i]) and std.ascii.isUpper(text[i + 1]) and std.ascii.isDigit(text[i + 2]) and std.ascii.isDigit(text[i + 3])) {
        var j = i + 4;
        while (j < text.len and (std.ascii.isUpper(text[j]) or std.ascii.isDigit(text[j]) or (text[j] == ' ' and j + 1 < text.len and std.ascii.isAlphanumeric(text[j + 1])))) j += 1;
        return j;
    }
    if (!std.ascii.isDigit(text[i]) and text[i] != '+') return i + 1;
    var j = i + 1;
    while (j < text.len and (std.ascii.isDigit(text[j]) or ((text[j] == ' ' or text[j] == '-') and j + 1 < text.len and std.ascii.isDigit(text[j + 1])))) j += 1;
    return j;
}

/// The first detector that matches at `i`, most specific first.
fn matchAt(text: []const u8, i: usize) ?Match {
    const detectors = .{ jwt, apiKey, email, iban, card, ip, phone, token };
    const kinds = [_]Kind{ .jwt, .api_key, .email, .iban, .card, .ip, .phone, .token };
    inline for (detectors, kinds) |d, k| {
        if (d(text, i)) |end| return .{ .start = i, .end = end, .kind = k };
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '@' or c >= 0x80;
}

/// End of a run of chars in `set` from `i`.
fn run(text: []const u8, i: usize, comptime pred: fn (u8) bool) usize {
    var j = i;
    while (j < text.len and pred(text[j])) j += 1;
    return j;
}

fn tokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// A token ends at a word boundary (not inside a longer word).
fn boundary(text: []const u8, end: usize) bool {
    return end >= text.len or !tokenChar(text[end]);
}

// --- e-mail ---

fn localChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null;
}

fn domainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

fn email(text: []const u8, i: usize) ?usize {
    const at = run(text, i, localChar);
    if (at == i or at >= text.len or text[at] != '@') return null;
    var end = run(text, at + 1, domainChar);
    while (end > at + 1 and (text[end - 1] == '.' or text[end - 1] == '-')) end -= 1;
    const domain = text[at + 1 .. end];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return null;
    const tld = domain[dot + 1 ..];
    if (dot == 0 or tld.len < 2) return null;
    for (tld) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return end;
}

// --- numbers: cards, phones ---

/// Digits with single spaces or dashes between groups, from `i`; returns
/// the end and the digits (up to 24).
fn digitRun(text: []const u8, i: usize, buf: *[24]u8) struct { end: usize, n: usize } {
    var j = i;
    var n: usize = 0;
    var end = i;
    while (j < text.len) {
        const c = text[j];
        if (std.ascii.isDigit(c)) {
            if (n == buf.len) break;
            buf[n] = c;
            n += 1;
            j += 1;
            end = j;
        } else if ((c == ' ' or c == '-') and n > 0 and j + 1 < text.len and std.ascii.isDigit(text[j + 1])) {
            j += 1;
        } else break;
    }
    return .{ .end = end, .n = n };
}

pub fn luhn(digits: []const u8) bool {
    var sum: u32 = 0;
    for (0..digits.len) |k| {
        var d: u32 = digits[digits.len - 1 - k] - '0';
        if (k % 2 == 1) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
    }
    return digits.len > 0 and sum % 10 == 0;
}

fn card(text: []const u8, i: usize) ?usize {
    if (!std.ascii.isDigit(text[i])) return null;
    var buf: [24]u8 = undefined;
    const r = digitRun(text, i, &buf);
    if (r.n < 13 or r.n > 19 or !boundary(text, r.end) or !luhn(buf[0..r.n])) return null;
    return r.end;
}

fn phone(text: []const u8, i: usize) ?usize {
    var j = i;
    const plus = text[j] == '+';
    if (plus) j += 1;
    var n: usize = 0;
    var end = j;
    var groups: usize = 0;
    while (j < text.len) {
        const c = text[j];
        if (std.ascii.isDigit(c)) {
            const start = j;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            n += j - start;
            groups += 1;
            end = j;
        } else if ((c == ' ' or c == '-' or c == '.' or c == '(' or c == ')') and n + @intFromBool(c == '(') > 0) {
            j += 1;
        } else break;
    }
    if (n < 7 or n > 15 or !boundary(text, end)) return null;
    // without +, a phone number has the usual length and some grouping
    if (!plus and (n < 9 or groups < 2) and !(n >= 10 and groups == 1)) return null;
    if (looksLikeDate(text[i..end])) return null;
    return end;
}

fn looksLikeDate(s: []const u8) bool {
    // 2026-11-21, 21.11.2026
    return s.len == 10 and ((s[4] == '-' and s[7] == '-') or (s[2] == '.' and s[5] == '.'));
}

// --- IBAN ---

fn iban(text: []const u8, i: usize) ?usize {
    if (i + 4 > text.len or !std.ascii.isUpper(text[i]) or !std.ascii.isUpper(text[i + 1]) or
        !std.ascii.isDigit(text[i + 2]) or !std.ascii.isDigit(text[i + 3])) return null;
    var chars: [34]u8 = undefined;
    var n: usize = 0;
    var j = i;
    var end = i;
    while (j < text.len and n < chars.len) {
        const c = text[j];
        if (std.ascii.isDigit(c) or std.ascii.isUpper(c)) {
            chars[n] = c;
            n += 1;
            j += 1;
            end = j;
        } else if (c == ' ' and j + 1 < text.len and std.ascii.isAlphanumeric(text[j + 1])) {
            j += 1;
        } else break;
    }
    if (n < 15 or !boundary(text, end) or !ibanValid(chars[0..n])) return null;
    return end;
}

/// ISO 13616: the country and check digits moved to the end, letters as
/// 10..35, the number mod 97 is 1.
pub fn ibanValid(s: []const u8) bool {
    if (s.len < 15 or s.len > 34) return false;
    var rem: u32 = 0;
    for (0..s.len) |k| {
        const c = s[(k + 4) % s.len];
        if (std.ascii.isDigit(c)) {
            rem = (rem * 10 + (c - '0')) % 97;
        } else if (std.ascii.isUpper(c)) {
            rem = (rem * 100 + (c - 'A' + 10)) % 97;
        } else return false;
    }
    return rem == 1;
}

// --- IP addresses ---

fn ip(text: []const u8, i: usize) ?usize {
    return ipv4(text, i) orelse ipv6(text, i);
}

fn ipv4(text: []const u8, i: usize) ?usize {
    var j = i;
    for (0..4) |k| {
        const s = j;
        while (j < text.len and j - s < 3 and std.ascii.isDigit(text[j])) j += 1;
        if (j == s) return null;
        const v = std.fmt.parseInt(u16, text[s..j], 10) catch return null;
        if (v > 255) return null;
        if (k < 3) {
            if (j >= text.len or text[j] != '.') return null;
            j += 1;
        }
    }
    if (j < text.len and (std.ascii.isDigit(text[j]) or (text[j] == '.' and j + 1 < text.len and std.ascii.isDigit(text[j + 1])))) return null;
    return j;
}

fn ipv6(text: []const u8, i: usize) ?usize {
    var j = i;
    var colons: usize = 0;
    var hex: usize = 0;
    while (j < text.len and (std.ascii.isHex(text[j]) or text[j] == ':')) : (j += 1) {
        if (text[j] == ':') colons += 1 else hex += 1;
    }
    if (colons < 3 or hex < 4 or !boundary(text, j)) return null;
    // groups of at most four hex digits
    var it = std.mem.splitScalar(u8, text[i..j], ':');
    while (it.next()) |g| if (g.len > 4) return null;
    return j;
}

// --- tokens ---

fn jwt(text: []const u8, i: usize) ?usize {
    if (!std.mem.startsWith(u8, text[i..], "eyJ")) return null;
    var j = i;
    var dots: usize = 0;
    while (j < text.len and (tokenChar(text[j]) or text[j] == '.')) : (j += 1) {
        if (text[j] == '.') dots += 1;
    }
    if (dots != 2 or j - i < 24) return null;
    return j;
}

const prefixes = [_][]const u8{
    "sk-",    "sk_live_", "sk_test_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
    "glpat-", "xoxb-",    "xoxp-",    "xoxa-",    "xapp-",    "AKIA", "ASIA", "AIza", "npm_", "hf_",  "SG.",
    "shpat_", "dop_v1_",  "sq0atp-",  "pypi-",
};

fn apiKey(text: []const u8, i: usize) ?usize {
    for (prefixes) |p| {
        if (!std.mem.startsWith(u8, text[i..], p)) continue;
        var j = i + p.len;
        while (j < text.len and (tokenChar(text[j]) or text[j] == '.')) j += 1;
        while (j > i and text[j - 1] == '.') j -= 1;
        if (j - (i + p.len) >= 12) return j;
    }
    return null;
}

/// Shannon entropy in bits per character.
pub fn entropy(s: []const u8) f64 {
    var counts: [256]u32 = @splat(0);
    for (s) |c| counts[c] += 1;
    var h: f64 = 0;
    const n: f64 = @floatFromInt(s.len);
    for (counts) |c| {
        if (c == 0) continue;
        const p = @as(f64, @floatFromInt(c)) / n;
        h -= p * std.math.log2(p);
    }
    return h;
}

fn token(text: []const u8, i: usize) ?usize {
    var end = run(text, i, tokenB64);
    // base64 padding
    while (end < text.len and end - i >= 24 and text[end] == '=') end += 1;
    const s = text[i..end];
    if (s.len < 24 or !boundary(text, end)) return null;
    var digits: usize = 0;
    var upper: usize = 0;
    var lower: usize = 0;
    for (s) |c| {
        if (std.ascii.isDigit(c)) digits += 1;
        if (std.ascii.isUpper(c)) upper += 1;
        if (std.ascii.isLower(c)) lower += 1;
    }
    // random: several kinds of characters, close to uniformly spread
    const kinds = @as(u8, @intFromBool(digits > 1)) + @intFromBool(upper > 1) + @intFromBool(lower > 1);
    if (kinds < 2 or digits < 2) return null;
    if (entropy(s) < 3.8 or classChanges(s) * 10 < s.len * 3) return null;
    return end;
}

/// How often the kind of character (digit, upper, lower, other) changes
/// from one to the next: often in random strings, seldom in words and
/// camelCase names.
fn classChanges(s: []const u8) usize {
    var n: usize = 0;
    for (s[1..], s[0 .. s.len - 1]) |c, p| {
        if (class(c) != class(p)) n += 1;
    }
    return n;
}

fn class(c: u8) u2 {
    if (std.ascii.isDigit(c)) return 0;
    if (std.ascii.isUpper(c)) return 1;
    if (std.ascii.isLower(c)) return 2;
    return 3;
}

fn tokenB64(c: u8) bool {
    return tokenChar(c) or c == '+' or c == '/';
}

test {
    _ = @import("detect_test.zig");
}
