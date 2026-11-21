//! Bidi character classes (UAX #9 table 4) from a compact range table
//! covering the scripts and punctuation that occur in practice, and the
//! predicates over them that the resolution phases share.

const std = @import("std");

pub const Class = enum(u8) { L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON, LRE, RLE, LRO, RLO, PDF, LRI, RLI, FSI, PDI };

const Range = struct { lo: u21, hi: u21, c: Class };

/// Sorted, non-overlapping; anything not listed is L.
const ranges = [_]Range{
    .{ .lo = 0x0000, .hi = 0x0008, .c = .BN },   .{ .lo = 0x0009, .hi = 0x0009, .c = .S },
    .{ .lo = 0x000A, .hi = 0x000A, .c = .B },    .{ .lo = 0x000B, .hi = 0x000B, .c = .S },
    .{ .lo = 0x000C, .hi = 0x000C, .c = .WS },   .{ .lo = 0x000D, .hi = 0x000D, .c = .B },
    .{ .lo = 0x000E, .hi = 0x001B, .c = .BN },   .{ .lo = 0x001C, .hi = 0x001E, .c = .B },
    .{ .lo = 0x001F, .hi = 0x001F, .c = .S },    .{ .lo = 0x0020, .hi = 0x0020, .c = .WS },
    .{ .lo = 0x0021, .hi = 0x0022, .c = .ON },   .{ .lo = 0x0023, .hi = 0x0025, .c = .ET },
    .{ .lo = 0x0026, .hi = 0x002A, .c = .ON },   .{ .lo = 0x002B, .hi = 0x002B, .c = .ES },
    .{ .lo = 0x002C, .hi = 0x002C, .c = .CS },   .{ .lo = 0x002D, .hi = 0x002D, .c = .ES },
    .{ .lo = 0x002E, .hi = 0x002F, .c = .CS },   .{ .lo = 0x0030, .hi = 0x0039, .c = .EN },
    .{ .lo = 0x003A, .hi = 0x003A, .c = .CS },   .{ .lo = 0x003B, .hi = 0x0040, .c = .ON },
    .{ .lo = 0x005B, .hi = 0x0060, .c = .ON },   .{ .lo = 0x007B, .hi = 0x007E, .c = .ON },
    .{ .lo = 0x007F, .hi = 0x0084, .c = .BN },   .{ .lo = 0x0085, .hi = 0x0085, .c = .B },
    .{ .lo = 0x0086, .hi = 0x009F, .c = .BN },   .{ .lo = 0x00A0, .hi = 0x00A0, .c = .CS },
    .{ .lo = 0x00A1, .hi = 0x00A1, .c = .ON },   .{ .lo = 0x00A2, .hi = 0x00A5, .c = .ET },
    .{ .lo = 0x00A6, .hi = 0x00A9, .c = .ON },   .{ .lo = 0x00AB, .hi = 0x00AC, .c = .ON },
    .{ .lo = 0x00AD, .hi = 0x00AD, .c = .BN },   .{ .lo = 0x00AE, .hi = 0x00AF, .c = .ON },
    .{ .lo = 0x00B0, .hi = 0x00B1, .c = .ET },   .{ .lo = 0x00B2, .hi = 0x00B3, .c = .EN },
    .{ .lo = 0x00B4, .hi = 0x00B4, .c = .ON },   .{ .lo = 0x00B6, .hi = 0x00B8, .c = .ON },
    .{ .lo = 0x00B9, .hi = 0x00B9, .c = .EN },   .{ .lo = 0x00BB, .hi = 0x00BF, .c = .ON },
    .{ .lo = 0x00D7, .hi = 0x00D7, .c = .ON },   .{ .lo = 0x00F7, .hi = 0x00F7, .c = .ON },
    .{ .lo = 0x02B9, .hi = 0x02BA, .c = .ON },   .{ .lo = 0x02C2, .hi = 0x02CF, .c = .ON },
    .{ .lo = 0x02D2, .hi = 0x02DF, .c = .ON },   .{ .lo = 0x02E5, .hi = 0x02ED, .c = .ON },
    .{ .lo = 0x02EF, .hi = 0x02FF, .c = .ON },   .{ .lo = 0x0300, .hi = 0x036F, .c = .NSM },
    .{ .lo = 0x0374, .hi = 0x0375, .c = .ON },   .{ .lo = 0x037E, .hi = 0x037E, .c = .ON },
    .{ .lo = 0x0384, .hi = 0x0385, .c = .ON },   .{ .lo = 0x0387, .hi = 0x0387, .c = .ON },
    .{ .lo = 0x0483, .hi = 0x0489, .c = .NSM },  .{ .lo = 0x058A, .hi = 0x058A, .c = .ON },
    .{ .lo = 0x058D, .hi = 0x058E, .c = .ON },   .{ .lo = 0x058F, .hi = 0x058F, .c = .ET },
    .{ .lo = 0x0590, .hi = 0x0590, .c = .R },    .{ .lo = 0x0591, .hi = 0x05BD, .c = .NSM },
    .{ .lo = 0x05BE, .hi = 0x05BE, .c = .R },    .{ .lo = 0x05BF, .hi = 0x05BF, .c = .NSM },
    .{ .lo = 0x05C0, .hi = 0x05C0, .c = .R },    .{ .lo = 0x05C1, .hi = 0x05C2, .c = .NSM },
    .{ .lo = 0x05C3, .hi = 0x05C3, .c = .R },    .{ .lo = 0x05C4, .hi = 0x05C5, .c = .NSM },
    .{ .lo = 0x05C6, .hi = 0x05C6, .c = .R },    .{ .lo = 0x05C7, .hi = 0x05C7, .c = .NSM },
    .{ .lo = 0x05C8, .hi = 0x05FF, .c = .R },    .{ .lo = 0x0600, .hi = 0x0605, .c = .AN },
    .{ .lo = 0x0606, .hi = 0x0607, .c = .ON },   .{ .lo = 0x0608, .hi = 0x0608, .c = .AL },
    .{ .lo = 0x0609, .hi = 0x060A, .c = .ET },   .{ .lo = 0x060B, .hi = 0x060B, .c = .AL },
    .{ .lo = 0x060C, .hi = 0x060C, .c = .CS },   .{ .lo = 0x060D, .hi = 0x060D, .c = .AL },
    .{ .lo = 0x060E, .hi = 0x060F, .c = .ON },   .{ .lo = 0x0610, .hi = 0x061A, .c = .NSM },
    .{ .lo = 0x061B, .hi = 0x064A, .c = .AL },   .{ .lo = 0x064B, .hi = 0x065F, .c = .NSM },
    .{ .lo = 0x0660, .hi = 0x0669, .c = .AN },   .{ .lo = 0x066A, .hi = 0x066A, .c = .ET },
    .{ .lo = 0x066B, .hi = 0x066C, .c = .AN },   .{ .lo = 0x066D, .hi = 0x066F, .c = .AL },
    .{ .lo = 0x0670, .hi = 0x0670, .c = .NSM },  .{ .lo = 0x0671, .hi = 0x06D5, .c = .AL },
    .{ .lo = 0x06D6, .hi = 0x06DC, .c = .NSM },  .{ .lo = 0x06DD, .hi = 0x06DD, .c = .AN },
    .{ .lo = 0x06DE, .hi = 0x06DE, .c = .ON },   .{ .lo = 0x06DF, .hi = 0x06E4, .c = .NSM },
    .{ .lo = 0x06E5, .hi = 0x06E6, .c = .AL },   .{ .lo = 0x06E7, .hi = 0x06E8, .c = .NSM },
    .{ .lo = 0x06E9, .hi = 0x06E9, .c = .ON },   .{ .lo = 0x06EA, .hi = 0x06ED, .c = .NSM },
    .{ .lo = 0x06EE, .hi = 0x06EF, .c = .AL },   .{ .lo = 0x06F0, .hi = 0x06F9, .c = .EN },
    .{ .lo = 0x06FA, .hi = 0x070D, .c = .AL },   .{ .lo = 0x070F, .hi = 0x0710, .c = .AL },
    .{ .lo = 0x0711, .hi = 0x0711, .c = .NSM },  .{ .lo = 0x0712, .hi = 0x072F, .c = .AL },
    .{ .lo = 0x0730, .hi = 0x074A, .c = .NSM },  .{ .lo = 0x074D, .hi = 0x07A5, .c = .AL },
    .{ .lo = 0x07A6, .hi = 0x07B0, .c = .NSM },  .{ .lo = 0x07B1, .hi = 0x07BF, .c = .AL },
    .{ .lo = 0x07C0, .hi = 0x07EA, .c = .R },    .{ .lo = 0x07EB, .hi = 0x07F3, .c = .NSM },
    .{ .lo = 0x07F4, .hi = 0x07F5, .c = .R },    .{ .lo = 0x07F6, .hi = 0x07F9, .c = .ON },
    .{ .lo = 0x07FA, .hi = 0x0815, .c = .R },    .{ .lo = 0x0816, .hi = 0x082D, .c = .NSM },
    .{ .lo = 0x0830, .hi = 0x0858, .c = .R },    .{ .lo = 0x0859, .hi = 0x085B, .c = .NSM },
    .{ .lo = 0x085E, .hi = 0x085F, .c = .R },    .{ .lo = 0x0860, .hi = 0x088F, .c = .AL },
    .{ .lo = 0x0890, .hi = 0x0891, .c = .AN },   .{ .lo = 0x0898, .hi = 0x089F, .c = .NSM },
    .{ .lo = 0x08A0, .hi = 0x08C9, .c = .AL },   .{ .lo = 0x08CA, .hi = 0x08E1, .c = .NSM },
    .{ .lo = 0x08E2, .hi = 0x08E2, .c = .AN },   .{ .lo = 0x08E3, .hi = 0x0902, .c = .NSM },
    .{ .lo = 0x0E3F, .hi = 0x0E3F, .c = .ET },   .{ .lo = 0x1680, .hi = 0x1680, .c = .WS },
    .{ .lo = 0x17DB, .hi = 0x17DB, .c = .ET },   .{ .lo = 0x180E, .hi = 0x180E, .c = .BN },
    .{ .lo = 0x2000, .hi = 0x200A, .c = .WS },   .{ .lo = 0x200B, .hi = 0x200D, .c = .BN },
    .{ .lo = 0x200E, .hi = 0x200E, .c = .L },    .{ .lo = 0x200F, .hi = 0x200F, .c = .R },
    .{ .lo = 0x2010, .hi = 0x2027, .c = .ON },   .{ .lo = 0x2028, .hi = 0x2028, .c = .WS },
    .{ .lo = 0x2029, .hi = 0x2029, .c = .B },    .{ .lo = 0x202A, .hi = 0x202A, .c = .LRE },
    .{ .lo = 0x202B, .hi = 0x202B, .c = .RLE },  .{ .lo = 0x202C, .hi = 0x202C, .c = .PDF },
    .{ .lo = 0x202D, .hi = 0x202D, .c = .LRO },  .{ .lo = 0x202E, .hi = 0x202E, .c = .RLO },
    .{ .lo = 0x202F, .hi = 0x202F, .c = .CS },   .{ .lo = 0x2030, .hi = 0x2034, .c = .ET },
    .{ .lo = 0x2035, .hi = 0x2043, .c = .ON },   .{ .lo = 0x2044, .hi = 0x2044, .c = .CS },
    .{ .lo = 0x2045, .hi = 0x205E, .c = .ON },   .{ .lo = 0x205F, .hi = 0x205F, .c = .WS },
    .{ .lo = 0x2060, .hi = 0x2065, .c = .BN },   .{ .lo = 0x2066, .hi = 0x2066, .c = .LRI },
    .{ .lo = 0x2067, .hi = 0x2067, .c = .RLI },  .{ .lo = 0x2068, .hi = 0x2068, .c = .FSI },
    .{ .lo = 0x2069, .hi = 0x2069, .c = .PDI },  .{ .lo = 0x206A, .hi = 0x206F, .c = .BN },
    .{ .lo = 0x2070, .hi = 0x2070, .c = .EN },   .{ .lo = 0x2074, .hi = 0x2079, .c = .EN },
    .{ .lo = 0x207A, .hi = 0x207B, .c = .ES },   .{ .lo = 0x207C, .hi = 0x207E, .c = .ON },
    .{ .lo = 0x2080, .hi = 0x2089, .c = .EN },   .{ .lo = 0x208A, .hi = 0x208B, .c = .ES },
    .{ .lo = 0x208C, .hi = 0x208E, .c = .ON },   .{ .lo = 0x20A0, .hi = 0x20CF, .c = .ET },
    .{ .lo = 0x20D0, .hi = 0x20F0, .c = .NSM },  .{ .lo = 0x2100, .hi = 0x2101, .c = .ON },
    .{ .lo = 0x2103, .hi = 0x2106, .c = .ON },   .{ .lo = 0x2108, .hi = 0x2109, .c = .ON },
    .{ .lo = 0x2114, .hi = 0x2114, .c = .ON },   .{ .lo = 0x2116, .hi = 0x2118, .c = .ON },
    .{ .lo = 0x211E, .hi = 0x2123, .c = .ON },   .{ .lo = 0x212E, .hi = 0x212E, .c = .ET },
    .{ .lo = 0x2140, .hi = 0x2144, .c = .ON },   .{ .lo = 0x214A, .hi = 0x214D, .c = .ON },
    .{ .lo = 0x2150, .hi = 0x215F, .c = .ON },   .{ .lo = 0x2189, .hi = 0x2211, .c = .ON },
    .{ .lo = 0x2212, .hi = 0x2212, .c = .ES },   .{ .lo = 0x2213, .hi = 0x2213, .c = .ET },
    .{ .lo = 0x2214, .hi = 0x2335, .c = .ON },   .{ .lo = 0x237B, .hi = 0x2394, .c = .ON },
    .{ .lo = 0x2396, .hi = 0x2487, .c = .ON },   .{ .lo = 0x2488, .hi = 0x249B, .c = .EN },
    .{ .lo = 0x24EA, .hi = 0x26AB, .c = .ON },   .{ .lo = 0x26AD, .hi = 0x27FF, .c = .ON },
    .{ .lo = 0x2900, .hi = 0x2B73, .c = .ON },   .{ .lo = 0x2B76, .hi = 0x2BFF, .c = .ON },
    .{ .lo = 0x2E00, .hi = 0x2E7F, .c = .ON },   .{ .lo = 0x2E80, .hi = 0x2FFB, .c = .ON },
    .{ .lo = 0x3000, .hi = 0x3000, .c = .WS },   .{ .lo = 0x3001, .hi = 0x3004, .c = .ON },
    .{ .lo = 0x3008, .hi = 0x3020, .c = .ON },   .{ .lo = 0x3030, .hi = 0x3030, .c = .ON },
    .{ .lo = 0x303D, .hi = 0x303F, .c = .ON },   .{ .lo = 0xA4D0, .hi = 0xA4FF, .c = .L },
    .{ .lo = 0xFB1D, .hi = 0xFB1D, .c = .R },    .{ .lo = 0xFB1E, .hi = 0xFB1E, .c = .NSM },
    .{ .lo = 0xFB1F, .hi = 0xFB28, .c = .R },    .{ .lo = 0xFB29, .hi = 0xFB29, .c = .ES },
    .{ .lo = 0xFB2A, .hi = 0xFB4F, .c = .R },    .{ .lo = 0xFB50, .hi = 0xFD3D, .c = .AL },
    .{ .lo = 0xFD3E, .hi = 0xFD4F, .c = .ON },   .{ .lo = 0xFD50, .hi = 0xFDCF, .c = .AL },
    .{ .lo = 0xFDF0, .hi = 0xFDFC, .c = .AL },   .{ .lo = 0xFDFD, .hi = 0xFDFF, .c = .ON },
    .{ .lo = 0xFE00, .hi = 0xFE0F, .c = .NSM },  .{ .lo = 0xFE10, .hi = 0xFE19, .c = .ON },
    .{ .lo = 0xFE20, .hi = 0xFE2F, .c = .NSM },  .{ .lo = 0xFE30, .hi = 0xFE4F, .c = .ON },
    .{ .lo = 0xFE50, .hi = 0xFE50, .c = .CS },   .{ .lo = 0xFE51, .hi = 0xFE51, .c = .ON },
    .{ .lo = 0xFE52, .hi = 0xFE52, .c = .CS },   .{ .lo = 0xFE54, .hi = 0xFE54, .c = .ON },
    .{ .lo = 0xFE55, .hi = 0xFE55, .c = .CS },   .{ .lo = 0xFE56, .hi = 0xFE5E, .c = .ON },
    .{ .lo = 0xFE5F, .hi = 0xFE5F, .c = .ET },   .{ .lo = 0xFE60, .hi = 0xFE61, .c = .ON },
    .{ .lo = 0xFE62, .hi = 0xFE63, .c = .ES },   .{ .lo = 0xFE64, .hi = 0xFE66, .c = .ON },
    .{ .lo = 0xFE68, .hi = 0xFE68, .c = .ON },   .{ .lo = 0xFE69, .hi = 0xFE6A, .c = .ET },
    .{ .lo = 0xFE6B, .hi = 0xFE6B, .c = .ON },   .{ .lo = 0xFE70, .hi = 0xFEFE, .c = .AL },
    .{ .lo = 0xFEFF, .hi = 0xFEFF, .c = .BN },   .{ .lo = 0xFF01, .hi = 0xFF02, .c = .ON },
    .{ .lo = 0xFF03, .hi = 0xFF05, .c = .ET },   .{ .lo = 0xFF06, .hi = 0xFF0A, .c = .ON },
    .{ .lo = 0xFF0B, .hi = 0xFF0B, .c = .ES },   .{ .lo = 0xFF0C, .hi = 0xFF0C, .c = .CS },
    .{ .lo = 0xFF0D, .hi = 0xFF0D, .c = .ES },   .{ .lo = 0xFF0E, .hi = 0xFF0F, .c = .CS },
    .{ .lo = 0xFF10, .hi = 0xFF19, .c = .EN },   .{ .lo = 0xFF1A, .hi = 0xFF1A, .c = .CS },
    .{ .lo = 0xFF1B, .hi = 0xFF20, .c = .ON },   .{ .lo = 0xFF3B, .hi = 0xFF40, .c = .ON },
    .{ .lo = 0xFF5B, .hi = 0xFF65, .c = .ON },   .{ .lo = 0xFFE0, .hi = 0xFFE1, .c = .ET },
    .{ .lo = 0xFFE2, .hi = 0xFFE4, .c = .ON },   .{ .lo = 0xFFE5, .hi = 0xFFE6, .c = .ET },
    .{ .lo = 0xFFE8, .hi = 0xFFEE, .c = .ON },   .{ .lo = 0xFFF9, .hi = 0xFFFD, .c = .ON },
    .{ .lo = 0x10800, .hi = 0x10FFF, .c = .R },  .{ .lo = 0x1D7CE, .hi = 0x1D7FF, .c = .EN },
    .{ .lo = 0x1E800, .hi = 0x1EDFF, .c = .R },  .{ .lo = 0x1EE00, .hi = 0x1EEFF, .c = .AL },
    .{ .lo = 0x1F000, .hi = 0x1FAFF, .c = .ON },
};

/// Bidi class of `cp`; anything outside the table is L.
pub fn class(cp: u21) Class {
    if (cp >= 'A' and cp <= 'z' and (cp <= 'Z' or cp >= 'a')) return .L;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else return ranges[mid].c;
    }
    return .L;
}

/// Whether `cp` can make text need reordering or shaping (cheap pre-check).
pub fn isRtl(cp: u21) bool {
    if (cp < 0x0590) return false;
    if (isExplicit(cp)) return true;
    const c = class(cp);
    return c == .R or c == .AL or c == .AN;
}

/// Explicit directional embeddings, overrides and isolates.
pub fn isExplicit(cp: u21) bool {
    return (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069);
}

/// LRI, RLI or FSI.
pub fn isIsolateInit(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// Characters X9 removes (kept here as boundary neutrals, as UAX #9
/// section 5.2 allows).
pub fn isRemoved(c: Class) bool {
    return switch (c) {
        .LRE, .RLE, .LRO, .RLO, .PDF, .BN => true,
        else => false,
    };
}

/// Direction of a strong type for N0-N2 (numbers count as R).
pub fn strongDir(c: Class) ?u1 {
    return switch (c) {
        .L => 0,
        .R, .AL, .EN, .AN => 1,
        else => null,
    };
}

/// Neutral and isolate types that N1/N2 resolve.
pub fn isNeutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .BN, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

/// Direction of the first strong character outside nested isolates,
/// stopping at an unmatched PDI.
pub fn firstStrong(cps: []const u21) ?u1 {
    var depth: usize = 0;
    for (cps) |cp| switch (class(cp)) {
        .L => if (depth == 0) return 0,
        .R, .AL => if (depth == 0) return 1,
        .LRI, .RLI, .FSI => depth += 1,
        .PDI => {
            if (depth == 0) return null;
            depth -= 1;
        },
        else => {},
    };
    return null;
}

test "bidi classes" {
    try std.testing.expectEqual(Class.L, class('a'));
    try std.testing.expectEqual(Class.EN, class('7'));
    try std.testing.expectEqual(Class.R, class(0x05D0));
    try std.testing.expectEqual(Class.AL, class(0x0627));
    try std.testing.expectEqual(Class.AN, class(0x0663));
    try std.testing.expectEqual(Class.NSM, class(0x064E));
    try std.testing.expectEqual(Class.WS, class(' '));
    try std.testing.expectEqual(Class.ON, class('!'));
    // the table is sorted and non-overlapping
    for (ranges[1..], ranges[0 .. ranges.len - 1]) |b, a| try std.testing.expect(a.hi < b.lo and a.lo <= a.hi);
}
