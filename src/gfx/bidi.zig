//! Right-to-left text support: the core of the Unicode Bidirectional
//! Algorithm (UAX #9) for one line of text, and Arabic contextual shaping
//! through the presentation-form codepoints that common fonts map.
//!
//! Covered: paragraph direction from the first strong character (P2/P3),
//! weak types W1-W7, bracket pairs N0, neutrals N1/N2, implicit levels
//! I1/I2, trailing whitespace L1, reordering L2 and mirroring L4.
//! Explicit embeddings, overrides and isolates (U+202A-202E, 2066-2069)
//! are treated as boundary neutrals and otherwise ignored. Bidi classes
//! come from a compact range table covering the scripts and punctuation
//! that occur in practice, not the full UCD.

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

fn isIsolateInit(c: Class) bool {
    return c == .LRI or c == .RLI or c == .FSI;
}

/// Characters X9 removes (kept here as boundary neutrals, as UAX #9
/// section 5.2 allows).
fn isRemoved(c: Class) bool {
    return switch (c) {
        .LRE, .RLE, .LRO, .RLO, .PDF, .BN => true,
        else => false,
    };
}

/// Mirrored glyph for brackets and other paired punctuation (L4).
pub fn mirror(cp: u21) u21 {
    const pairs = [_][2]u21{
        .{ '(', ')' },       .{ '<', '>' },       .{ '[', ']' },       .{ '{', '}' },
        .{ 0xAB, 0xBB },     .{ 0x2039, 0x203A }, .{ 0x2045, 0x2046 }, .{ 0x207D, 0x207E },
        .{ 0x208D, 0x208E }, .{ 0x2264, 0x2265 }, .{ 0x2208, 0x220B }, .{ 0x2282, 0x2283 },
        .{ 0x2286, 0x2287 }, .{ 0x3008, 0x3009 }, .{ 0x300A, 0x300B }, .{ 0x300C, 0x300D },
        .{ 0x300E, 0x300F }, .{ 0x3010, 0x3011 }, .{ 0xFF08, 0xFF09 }, .{ 0xFF3B, 0xFF3D },
        .{ 0xFF5B, 0xFF5D }, .{ 0x2329, 0x232A }, .{ 0x27E8, 0x27E9 }, .{ 0x2018, 0x2019 },
    };
    for (pairs) |p| {
        if (cp == p[0]) return p[1];
        if (cp == p[1]) return p[0];
    }
    return cp;
}

/// Opening bracket for a closing one (BD14/BD15), or null.
fn closingOf(cp: u21) ?u21 {
    return switch (cp) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        0x2046 => 0x2045,
        0x207E => 0x207D,
        0x208E => 0x208D,
        0x3009 => 0x3008,
        0x300B => 0x300A,
        0x300D => 0x300C,
        0x300F => 0x300E,
        0x3011 => 0x3010,
        0xFF09 => 0xFF08,
        0xFF3D => 0xFF3B,
        0xFF5D => 0xFF5B,
        0x232A => 0x2329,
        0x27E9 => 0x27E8,
        else => null,
    };
}

fn isOpening(cp: u21) bool {
    return switch (cp) {
        '(', '[', '{', 0x2045, 0x207D, 0x208D, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0xFF08, 0xFF3B, 0xFF5B, 0x2329, 0x27E8 => true,
        else => false,
    };
}

pub const Direction = enum { auto, ltr, rtl };

/// Paragraph embedding level from the first strong character (P2/P3),
/// skipping text inside isolates.
pub fn paragraphLevel(cps: []const u21, dir: Direction) u1 {
    switch (dir) {
        .ltr => return 0,
        .rtl => return 1,
        .auto => {},
    }
    return firstStrong(cps) orelse 0;
}

/// Direction of the first strong character outside nested isolates,
/// stopping at an unmatched PDI.
fn firstStrong(cps: []const u21) ?u1 {
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

fn strongDir(c: Class) ?u1 {
    return switch (c) {
        .L => 0,
        .R, .AL, .EN, .AN => 1,
        else => null,
    };
}

fn isNeutral(c: Class) bool {
    return switch (c) {
        .B, .S, .WS, .ON, .BN, .LRI, .RLI, .FSI, .PDI => true,
        else => false,
    };
}

/// Resolve embedding levels for one paragraph or line (`levels.len ==
/// cps.len`); `types` is scratch of the same length. Explicit
/// embeddings, overrides and isolates (X1-X10) are honoured; text
/// without them takes a fast path with one isolating run sequence.
pub fn resolveLevels(cps: []const u21, para: u1, types: []Class, levels: []u8) void {
    for (cps, types) |cp, *t| t.* = class(cp);
    const explicit = for (cps) |cp| {
        if (isExplicit(cp)) break true;
    } else false;
    if (!explicit or !resolveExplicit(cps, para, types, levels)) {
        @memset(levels, para);
        resolveSequence(cps, types, para, para, para);
        for (types, levels) |t, *l| l.* = implicitLevel(para, t);
    }
    lineRules(cps, para, levels);
}

/// I1/I2.
fn implicitLevel(base: u8, t: Class) u8 {
    if (base % 2 == 0) {
        if (t == .R) return base + 1;
        if (t == .AN or t == .EN) return base + 2;
    } else if (t == .L or t == .EN or t == .AN) return base + 1;
    return base;
}

/// W1-W7, N0-N2 on one isolating run sequence (`sos`, `eos`: the
/// directions at its ends; `e`: its embedding direction).
fn resolveSequence(cps: []const u21, types: []Class, sos: u1, eos: u1, e: u1) void {
    resolveWeak(types, sos);
    resolveBrackets(cps, types, e, sos);
    resolveNeutrals(types, sos, eos, e);
}

const max_depth = 125;

/// X1-X10 with explicit codes present. False when scratch runs out (the
/// caller then ignores the codes).
fn resolveExplicit(cps: []const u21, para: u1, types: []Class, levels: []u8) bool {
    const n = cps.len;
    var mem: [16384]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&mem, std.heap.page_allocator);
    const a = bfa.allocator();
    // BD9: isolate initiator -> matching PDI
    const match = a.alloc(u32, n) catch return false;
    defer a.free(match);
    const none = std.math.maxInt(u32);
    @memset(match, none);
    const matched_pdi = a.alloc(bool, n) catch return false;
    defer a.free(matched_pdi);
    @memset(matched_pdi, false);
    {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(a);
        for (types, 0..) |t, i| {
            if (isIsolateInit(t)) {
                stack.append(a, @intCast(i)) catch return false;
            } else if (t == .PDI) {
                if (stack.pop()) |o| {
                    match[o] = @intCast(i);
                    matched_pdi[i] = true;
                }
            }
        }
    }

    // X1-X8
    const Entry = struct { level: u8, override: ?Class, isolate: bool };
    var stack: [max_depth + 2]Entry = undefined;
    var sp: usize = 1;
    stack[0] = .{ .level = para, .override = null, .isolate = false };
    var overflow_isolate: usize = 0;
    var overflow_embed: usize = 0;
    var valid_isolate: usize = 0;
    for (types, 0..) |*t, i| {
        const top = stack[sp - 1];
        switch (t.*) {
            .RLE, .LRE, .RLO, .LRO => {
                levels[i] = top.level;
                const rtl = t.* == .RLE or t.* == .RLO;
                const next: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embed == 0) {
                    stack[sp] = .{ .level = next, .override = if (t.* == .RLO) .R else if (t.* == .LRO) .L else null, .isolate = false };
                    sp += 1;
                } else if (overflow_isolate == 0) overflow_embed += 1;
                t.* = .BN;
            },
            .RLI, .LRI, .FSI => {
                levels[i] = top.level;
                var rtl = t.* == .RLI;
                if (t.* == .FSI) {
                    const end = if (match[i] != none) match[i] else n;
                    rtl = (firstStrong(cps[i + 1 .. end]) orelse 0) == 1;
                }
                if (top.override) |o| t.* = o;
                const next: u8 = if (rtl) (top.level + 1) | 1 else (top.level + 2) & ~@as(u8, 1);
                if (next <= max_depth and overflow_isolate == 0 and overflow_embed == 0) {
                    valid_isolate += 1;
                    stack[sp] = .{ .level = next, .override = null, .isolate = true };
                    sp += 1;
                } else overflow_isolate += 1;
            },
            .PDI => {
                if (overflow_isolate > 0) {
                    overflow_isolate -= 1;
                } else if (valid_isolate > 0) {
                    overflow_embed = 0;
                    while (!stack[sp - 1].isolate) sp -= 1;
                    sp -= 1;
                    valid_isolate -= 1;
                }
                const cur = stack[sp - 1];
                levels[i] = cur.level;
                if (cur.override) |o| t.* = o;
            },
            .PDF => {
                if (overflow_isolate > 0) {} else if (overflow_embed > 0) {
                    overflow_embed -= 1;
                } else if (!top.isolate and sp >= 2) sp -= 1;
                levels[i] = stack[sp - 1].level;
                t.* = .BN;
            },
            .B => levels[i] = para,
            .BN => levels[i] = top.level,
            else => {
                levels[i] = top.level;
                if (top.override) |o| t.* = o;
            },
        }
    }

    // X10: level runs joined across isolates into isolating run sequences
    // (found on the explicit levels; `levels` receives the final ones)
    const xl = a.dupe(u8, levels) catch return false;
    defer a.free(xl);
    const idx = a.alloc(u32, n) catch return false;
    defer a.free(idx);
    const seq_cps = a.alloc(u21, n) catch return false;
    defer a.free(seq_cps);
    const seq_types = a.alloc(Class, n) catch return false;
    defer a.free(seq_types);
    var start: usize = 0;
    while (start < n) {
        var end = start + 1;
        while (end < n and xl[end] == xl[start]) end += 1;
        defer start = end;
        // a run starting with a matched PDI continues an earlier sequence
        if (matched_pdi[start]) continue;
        var m: usize = 0;
        var rs = start;
        var re = end;
        while (true) {
            for (rs..re) |k| {
                idx[m] = @intCast(k);
                m += 1;
            }
            const last = re - 1;
            if (!isIsolateInit(class(cps[last])) or match[last] == none) break;
            rs = match[last];
            re = rs + 1;
            while (re < n and xl[re] == xl[rs]) re += 1;
        }
        const seq = idx[0..m];
        const lv = xl[seq[0]];
        // sos / eos from the neighbouring levels (removed characters skipped)
        var before: u8 = para;
        var k = seq[0];
        while (k > 0) {
            k -= 1;
            if (!isRemoved(class(cps[k]))) {
                before = xl[k];
                break;
            }
        }
        var after: u8 = para;
        const last = seq[m - 1];
        if (!isIsolateInit(class(cps[last]))) {
            var q = last + 1;
            while (q < n) : (q += 1) {
                if (!isRemoved(class(cps[q]))) {
                    after = xl[q];
                    break;
                }
            }
        }
        const sos: u1 = @intCast(@max(lv, before) % 2);
        const eos: u1 = @intCast(@max(lv, after) % 2);
        for (seq, 0..) |q, j| {
            seq_cps[j] = cps[q];
            seq_types[j] = types[q];
        }
        resolveSequence(seq_cps[0..m], seq_types[0..m], sos, eos, @intCast(lv % 2));
        for (seq, 0..) |q, j| {
            types[q] = seq_types[j];
            levels[q] = implicitLevel(lv, seq_types[j]);
        }
    }
    return true;
}

/// W1-W7.
fn resolveWeak(types: []Class, sos: u1) void {
    const n = types.len;
    const e: Class = if (sos == 0) .L else .R;
    // W1: NSM (and BN: formatting codes, ZWJ...) take the type of the
    // previous character (sos at the start; ON after an isolate)
    var prev: Class = e;
    for (types) |*t| {
        if (t.* == .NSM or t.* == .BN) {
            t.* = if (prev == .LRI or prev == .RLI or prev == .FSI or prev == .PDI) .ON else prev;
        } else prev = t.*;
    }
    // W2: EN after AL (looking back to the last strong) -> AN; W3: AL -> R
    var last_strong: Class = e;
    for (types) |*t| {
        switch (t.*) {
            .L, .R, .AL => last_strong = t.*,
            .EN => if (last_strong == .AL) {
                t.* = .AN;
            },
            else => {},
        }
    }
    for (types) |*t| {
        if (t.* == .AL) t.* = .R;
    }
    // W4: single separator between two numbers of the same kind
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        const a = types[i - 1];
        const b = types[i + 1];
        if (types[i] == .ES and a == .EN and b == .EN) types[i] = .EN;
        if (types[i] == .CS and a == b and (a == .EN or a == .AN)) types[i] = a;
    }
    // W5: ET sequences next to EN become EN
    i = 0;
    while (i < n) {
        if (types[i] != .ET) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and types[j] == .ET) j += 1;
        const touches = (i > 0 and types[i - 1] == .EN) or (j < n and types[j] == .EN);
        if (touches) @memset(types[i..j], .EN);
        i = j;
    }
    // W6: remaining separators and terminators -> ON
    for (types) |*t| switch (t.*) {
        .ES, .ET, .CS => t.* = .ON,
        else => {},
    };
    // W7: EN after L (or sos L) -> L
    last_strong = e;
    for (types) |*t| switch (t.*) {
        .L, .R => last_strong = t.*,
        .EN => if (last_strong == .L) {
            t.* = .L;
        },
        else => {},
    };
}

/// N1/N2: runs of neutrals take the surrounding direction when both
/// sides agree (numbers count as R), else the embedding direction.
fn resolveNeutrals(types: []Class, sos: u1, eos: u1, e_dir: u1) void {
    const n = types.len;
    const e: Class = if (e_dir == 0) .L else .R;
    var i: usize = 0;
    while (i < n) {
        if (!isNeutral(types[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and isNeutral(types[j])) j += 1;
        const before: u1 = if (i == 0) sos else strongDir(types[i - 1]) orelse sos;
        const after: u1 = if (j == n) eos else strongDir(types[j]) orelse eos;
        const d: Class = if (before == after) (if (before == 0) .L else .R) else e;
        @memset(types[i..j], d);
        i = j;
    }
}

/// L1: separators, and whitespace and isolate controls at the end of the
/// line (or before a separator), go back to the paragraph level.
fn lineRules(cps: []const u21, para: u1, levels: []u8) void {
    const trailing = struct {
        fn f(c: Class) bool {
            return switch (c) {
                .WS, .S, .B, .BN, .LRI, .RLI, .FSI, .PDI, .LRE, .RLE, .LRO, .RLO, .PDF => true,
                else => false,
            };
        }
    }.f;
    var k = cps.len;
    while (k > 0 and trailing(class(cps[k - 1]))) : (k -= 1) levels[k - 1] = para;
    for (cps, 0..) |cp, i| {
        const c = class(cp);
        if (c != .S and c != .B) continue;
        levels[i] = para;
        var j = i;
        while (j > 0 and trailing(class(cps[j - 1])) and class(cps[j - 1]) != .S and class(cps[j - 1]) != .B) : (j -= 1) levels[j - 1] = para;
    }
}

/// L1 for one line of a paragraph whose levels were resolved as a whole
/// (`cps` and `levels` are the line's): its trailing whitespace returns
/// to the paragraph level.
pub fn lineLevels(cps: []const u21, para: u1, levels: []u8) void {
    lineRules(cps, para, levels);
}

const Pair = struct { open: usize, close: usize };

/// N0: paired brackets take the direction of what they enclose.
fn resolveBrackets(cps: []const u21, types: []Class, ed: u1, sos: u1) void {
    var pairs: [64]Pair = undefined;
    var n_pairs: usize = 0;
    var stack_cp: [63]u21 = undefined;
    var stack_pos: [63]usize = undefined;
    var sp: usize = 0;
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        const cp = cps[i];
        if (types[i] != .ON) continue;
        if (isOpening(cp)) {
            if (sp == stack_cp.len) break; // BD16: stop at overflow
            stack_cp[sp] = cp;
            stack_pos[sp] = i;
            sp += 1;
        } else if (closingOf(cp)) |want| {
            var s = sp;
            while (s > 0) : (s -= 1) {
                if (stack_cp[s - 1] == want) {
                    if (n_pairs < pairs.len) {
                        pairs[n_pairs] = .{ .open = stack_pos[s - 1], .close = i };
                        n_pairs += 1;
                    }
                    sp = s - 1;
                    break;
                }
            }
        }
    }
    applyPairs(cps, types, pairs[0..n_pairs], ed, sos);
}

/// Second half of N0 for the bracket pairs found (`ed`: embedding
/// direction, 0 = L, 1 = R).
fn applyPairs(cps: []const u21, types: []Class, pairs: []Pair, ed: u1, sos: u1) void {
    // process in order of opening position
    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.open < b.open;
        }
    }.lt);
    for (pairs) |p| {
        var found_e = false;
        var found_o = false;
        for (types[p.open + 1 .. p.close]) |t| {
            if (strongDir(t)) |d| {
                if (d == ed) found_e = true else found_o = true;
            }
        }
        var d: ?u1 = null;
        if (found_e) {
            d = ed;
        } else if (found_o) {
            // context before the opening bracket
            var ctx: u1 = sos;
            var k = p.open;
            while (k > 0) : (k -= 1) {
                if (strongDir(types[k - 1])) |sd| {
                    ctx = sd;
                    break;
                }
            }
            d = if (ctx != ed) ctx else ed;
        }
        if (d) |dir| {
            const t: Class = if (dir == 0) .L else .R;
            types[p.open] = t;
            types[p.close] = t;
            // NSMs after a bracket follow it
            for ([_]usize{ p.open, p.close }) |b| {
                var k = b + 1;
                while (k < cps.len and class(cps[k]) == .NSM) : (k += 1) types[k] = t;
            }
        }
    }
}

/// L2: visual order of the line as indices into the logical text.
pub fn reorder(levels: []const u8, order: []u32) void {
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var max: u8 = 0;
    var min_odd: u8 = 255;
    for (levels) |l| {
        max = @max(max, l);
        if (l % 2 == 1) min_odd = @min(min_odd, l);
    }
    if (min_odd == 255) return;
    var level = max;
    while (level >= min_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < levels.len and levels[order[j]] >= level) j += 1;
            std.mem.reverse(u32, order[i..j]);
            i = j;
        }
        if (level == 0) break;
    }
}

// --- Arabic shaping ---

const Joining = enum { U, R, D, C, T };

/// Unicode joining type (ArabicShaping.txt) for Arabic, Arabic Supplement
/// and Extended-A, Syriac and NKo; everything else is non-joining.
fn joining(cp: u21) Joining {
    return switch (cp) {
        0x0622...0x0625, 0x0627, 0x0629, 0x062F...0x0632, 0x0648, 0x0671...0x0673, 0x0675...0x0677, 0x0688...0x0699, 0x06C0, 0x06C3...0x06CB, 0x06CD, 0x06CF, 0x06D2, 0x06D3, 0x06D5, 0x06EE, 0x06EF => .R,
        0x0620, 0x0626, 0x0628, 0x062A...0x062E, 0x0633...0x063F, 0x0641...0x0647, 0x0649, 0x064A, 0x066E, 0x066F, 0x0678...0x0687, 0x069A...0x06BF, 0x06C1, 0x06C2, 0x06CC, 0x06CE, 0x06D0, 0x06D1, 0x06FA...0x06FC, 0x06FF => .D,
        // Syriac
        0x0710, 0x0715...0x0719, 0x071E, 0x0728, 0x072A, 0x072C, 0x072F, 0x074D => .R,
        0x0712...0x0714, 0x071A...0x071D, 0x071F...0x0727, 0x0729, 0x072B, 0x072D, 0x072E, 0x074E...0x074F => .D,
        // Arabic Supplement
        0x0759...0x075B, 0x076B, 0x076C, 0x0771, 0x0773, 0x0774, 0x0778, 0x0779 => .R,
        0x0750...0x0758, 0x075C...0x076A, 0x076D...0x0770, 0x0772, 0x0775...0x0777, 0x077A...0x077F => .D,
        // NKo
        0x07CA...0x07EA => .D,
        0x07FA => .C,
        // Arabic Extended-A
        0x08AA...0x08AC, 0x08AE, 0x08B1, 0x08B2, 0x08B9 => .R,
        0x08A0...0x08A9, 0x08AF, 0x08B0, 0x08B3, 0x08B4, 0x08B6...0x08B8, 0x08BA...0x08C8 => .D,
        0x0640, 0x200D => .C,
        0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7, 0x06E8, 0x06EA...0x06ED => .T,
        0x070F, 0x0711, 0x0730...0x074A, 0x07EB...0x07F3, 0x07FD, 0x08CA...0x08E1, 0x08E3...0x08FF => .T,
        0x0300...0x036F, 0x200B, 0x2060, 0xFE00...0xFE0F => .T,
        else => .U,
    };
}

/// Contextual joining form of every character (logical order), as OpenType
/// feature masks: 1 isol, 2 fina, 4 medi, 8 init, 0 none. ZWJ joins,
/// ZWNJ and anything non-joining breaks the chain, marks are transparent.
pub fn joiningMasks(cps: []const u21, out: []u8) void {
    const joins_prev: u8 = 0x10;
    const joins_next: u8 = 0x20;
    @memset(out, 0);
    var prev: ?usize = null;
    var prev_jt: Joining = .U;
    for (cps, 0..) |cp, i| {
        const jt = joining(cp);
        if (jt == .T) continue;
        if (prev) |p| {
            if ((prev_jt == .D or prev_jt == .C) and (jt == .D or jt == .R or jt == .C)) {
                out[p] |= joins_next;
                out[i] |= joins_prev;
            }
        }
        prev = i;
        prev_jt = jt;
    }
    for (cps, out) |cp, *m| {
        const p = m.* & joins_prev != 0;
        const n = m.* & joins_next != 0;
        m.* = switch (joining(cp)) {
            .D => if (p and n) 4 else if (p) 2 else if (n) 8 else 1,
            .R => if (p) 2 else 1,
            else => 0,
        };
    }
}

/// Presentation forms: isolated, final, initial, medial (0 = none).
fn forms(cp: u21) ?[4]u21 {
    const two = struct {
        fn f(iso: u21) [4]u21 {
            return .{ iso, iso + 1, 0, 0 };
        }
        fn four(iso: u21) [4]u21 {
            return .{ iso, iso + 1, iso + 2, iso + 3 };
        }
    };
    return switch (cp) {
        0x0621 => .{ 0xFE80, 0, 0, 0 },
        0x0622 => two.f(0xFE81),
        0x0623 => two.f(0xFE83),
        0x0624 => two.f(0xFE85),
        0x0625 => two.f(0xFE87),
        0x0626 => two.four(0xFE89),
        0x0627 => two.f(0xFE8D),
        0x0628 => two.four(0xFE8F),
        0x0629 => two.f(0xFE93),
        0x062A...0x062E => two.four(0xFE95 + (cp - 0x062A) * 4),
        0x062F...0x0632 => two.f(0xFEA9 + (cp - 0x062F) * 2),
        0x0633...0x063A => two.four(0xFEB1 + (cp - 0x0633) * 4),
        0x0641...0x0647 => two.four(0xFED1 + (cp - 0x0641) * 4),
        0x0648 => two.f(0xFEED),
        0x0649 => .{ 0xFEEF, 0xFEF0, 0xFBE8, 0xFBE9 },
        0x064A => two.four(0xFEF1),
        0x0671 => two.f(0xFB50),
        0x0679 => two.four(0xFB66),
        0x067E => two.four(0xFB56),
        0x0686 => two.four(0xFB7A),
        0x0688 => two.f(0xFB88),
        0x0691 => two.f(0xFB8C),
        0x0698 => two.f(0xFB8A),
        0x06A9 => two.four(0xFB8E),
        0x06AF => two.four(0xFB92),
        0x06BA => two.f(0xFB9E),
        0x06BE => two.four(0xFBAA),
        0x06C1 => two.four(0xFBA6),
        0x06CC => two.four(0xFBFC),
        0x06D2 => two.f(0xFBAE),
        else => null,
    };
}

fn lamAlef(alef: u21) ?u21 {
    return switch (alef) {
        0x0622 => 0xFEF5,
        0x0623 => 0xFEF7,
        0x0625 => 0xFEF9,
        0x0627 => 0xFEFB,
        else => null,
    };
}

/// Replace Arabic letters (logical order, in place) by their contextual
/// presentation forms. A lam-alef pair becomes the ligature on the lam and
/// `removed` on the alef (callers skip it). Characters outside Arabic are
/// untouched; nothing changes length.
pub const removed: u21 = 0x200B; // zero-width space: draws and measures nothing

pub fn shapeArabic(cps: []u21) void {
    const n = cps.len;
    // joining type of the last non-transparent character, from the text
    // before shaping (shaped forms are no longer in the joining table)
    var last: Joining = .U;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp = cps[i];
        const jt = joining(cp);
        if (jt == .T) continue;
        const prev_joins = last == .D or last == .C;
        last = jt;
        if (jt != .R and jt != .D) continue;
        var next_joins = false;
        var next_idx: ?usize = null;
        var nx = i + 1;
        while (nx < n) : (nx += 1) {
            const nj = joining(cps[nx]);
            if (nj == .T) continue;
            next_joins = jt == .D and (nj == .D or nj == .R or nj == .C);
            next_idx = nx;
            break;
        }
        // lam + alef
        if (cp == 0x0644 and next_idx != null and next_idx.? == i + 1) {
            if (lamAlef(cps[i + 1])) |lig| {
                cps[i] = if (prev_joins) lig + 1 else lig;
                cps[i + 1] = removed;
                i += 1;
                last = .R; // the alef ends the ligature and joins nothing after
                continue;
            }
        }
        const f = forms(cp) orelse continue;
        const want: usize = if (prev_joins and next_joins) 3 else if (prev_joins) 1 else if (next_joins) 2 else 0;
        // fall back to a form the letter has
        const pick = if (f[want] != 0) f[want] else if (want == 3 and f[1] != 0) f[1] else f[0];
        if (pick != 0) cps[i] = pick;
    }
}

/// Undo shaping for a single presentation form (to find a font that has
/// the plain letter when none has the form).
pub fn baseLetter(cp: u21) u21 {
    if (cp < 0xFB50 or cp > 0xFEFC) return cp;
    var c: u21 = 0x0621;
    while (c <= 0x06D2) : (c += 1) {
        if (forms(c)) |f| for (f) |x| {
            if (x == cp) return c;
        };
    }
    return switch (cp) {
        0xFEF5, 0xFEF6, 0xFEF7, 0xFEF8, 0xFEF9, 0xFEFA, 0xFEFB, 0xFEFC => 0x0644,
        else => cp,
    };
}

test "joining masks: forms, transparent marks, non-joiners" {
    const isol = 1;
    const fina = 2;
    const medi = 4;
    const init = 8;
    var m: [8]u8 = undefined;
    // بيت
    joiningMasks(&u32s("بيت"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, medi, fina }, m[0..3]);
    // ڈ (right-joining, Urdu) after ٹ: ٹ init, ڈ final; then ے isolated after it
    joiningMasks(&u32s("ٹڈے"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, fina, isol }, m[0..3]);
    // a mark between two letters keeps them joined
    joiningMasks(&u32s("بَت"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ init, 0, fina }, m[0..3]);
    // ZWNJ breaks, ZWJ joins
    joiningMasks(&u32s("ب\u{200C}ب"), m[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ isol, 0, isol }, m[0..3]);
    joiningMasks(&u32s("ب\u{200D}"), m[0..2]);
    try std.testing.expectEqual(@as(u8, init), m[0]);
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

/// Visual order of a UTF-32 test string as a string of the same chars.
fn visual(alloc: std.mem.Allocator, s: []const u21, dir: Direction) ![]u21 {
    const n = s.len;
    const types = try alloc.alloc(Class, n);
    defer alloc.free(types);
    const levels = try alloc.alloc(u8, n);
    defer alloc.free(levels);
    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    resolveLevels(s, paragraphLevel(s, dir), types, levels);
    reorder(levels, order);
    const out = try alloc.alloc(u21, n);
    for (order, out) |o, *c| c.* = if (levels[o] % 2 == 1) mirror(s[o]) else s[o];
    return out;
}

fn u32s(comptime s: []const u8) [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 {
    @setEvalBranchQuota(100_000);
    var out: [std.unicode.utf8CountCodepoints(s) catch unreachable]u21 = undefined;
    var it = std.unicode.Utf8View.initComptime(s).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) out[i] = cp;
    return out;
}

fn expectVisual(comptime logical: []const u8, comptime expected: []const u8, dir: Direction) !void {
    const alloc = std.testing.allocator;
    const l = u32s(logical);
    const lv = try alloc.dupe(u21, &l);
    defer alloc.free(lv);
    const v = try visual(alloc, lv, dir);
    defer alloc.free(v);
    const e = u32s(expected);
    try std.testing.expectEqualSlices(u21, &e, v);
}

test "bidi reordering" {
    // Hebrew alone is reversed
    try expectVisual("שלום", "םולש", .auto);
    // Hebrew in an English sentence: only the Hebrew run flips
    try expectVisual("say שלום now", "say םולש now", .auto);
    // numbers keep their order inside RTL text
    try expectVisual("מחיר 120 שקל", "לקש 120 ריחמ", .auto);
    // English inside an RTL paragraph keeps its own order, run moves
    try expectVisual("שלום world!", "!world םולש", .auto);
    // brackets are mirrored at odd levels and follow their content
    try expectVisual("א(ב)ג", "ג(ב)א", .auto);
    // explicit LTR paragraph with leading RTL
    try expectVisual("אב cd", "בא cd", .ltr);
    // phone number with separators stays together
    try expectVisual("טל 03-555-1234", "03-555-1234 לט", .auto);
}

/// expectVisual ignoring where the (invisible) explicit controls land;
/// `expected` is written without them.
fn expectVisualText(comptime logical: []const u8, comptime expected: []const u8, dir: Direction) !void {
    const alloc = std.testing.allocator;
    const l = u32s(logical);
    const v = try visual(alloc, &l, dir);
    defer alloc.free(v);
    var out: [64]u21 = undefined;
    var n: usize = 0;
    for (v) |c| {
        if (isExplicit(c)) continue;
        out[n] = c;
        n += 1;
    }
    const e = u32s(expected);
    try std.testing.expectEqualSlices(u21, &e, out[0..n]);
}

test "explicit embeddings, overrides and isolates" {
    // RLO..PDF reverses Latin letters
    try expectVisualText("a\u{202E}bc\u{202C}d", "acbd", .ltr);
    // LRO keeps Hebrew in logical order
    try expectVisualText("\u{202D}\u{5D0}\u{5D1}\u{202C}", "\u{5D0}\u{5D1}", .ltr);
    // an LRI keeps "hello!" together: without it the "!" would jump to
    // the left of the word in this right-to-left paragraph
    try expectVisualText("שלום \u{2066}hello!\u{2069} עולם", "םלוע hello! םולש", .auto);
    try expectVisualText("שלום hello! עולם", "םלוע !hello םולש", .auto);
    // FSI takes the direction of its content
    try expectVisualText("a \u{2068}\u{5D0}\u{5D1}\u{2069} c", "a \u{5D1}\u{5D0} c", .auto);
    // RLI around a number and Latin in an LTR paragraph: the isolate
    // reads right to left as a unit
    try expectVisualText("x \u{2067}ab \u{5D0}\u{2069} y", "x \u{5D0} ab y", .auto);
    // the paragraph direction skips isolated text (P2)
    try std.testing.expectEqual(@as(u1, 0), paragraphLevel(&u32s("\u{2067}\u{5D0}\u{2069}abc"), .auto));
    // RLE raises Latin text to level 2: order kept
    try expectVisualText("x\u{202B}ab 12\u{202C}y", "xab 12y", .ltr);
    // unbalanced and absurdly deep controls never crash or overflow
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    const pool = [_]u21{ 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 'a', 0x5D0, 0x627, '1', ' ', '(', ')', 0x64E, 0x200D };
    var cps: [400]u21 = undefined;
    var types: [400]Class = undefined;
    var levels: [400]u8 = undefined;
    var order: [400]u32 = undefined;
    for (0..2000) |_| {
        const n = r.intRangeAtMost(usize, 0, cps.len);
        for (cps[0..n]) |*c| c.* = pool[r.uintLessThan(usize, pool.len)];
        if (r.boolean()) for (cps[0 .. n / 2]) |*c| {
            c.* = 0x202B;
        };
        const para = paragraphLevel(cps[0..n], .auto);
        resolveLevels(cps[0..n], para, types[0..n], levels[0..n]);
        for (levels[0..n]) |l| std.testing.expect(l <= max_depth + 1) catch |e| {
            std.debug.print("level {d} in {any}\n", .{ l, cps[0..n] });
            return e;
        };
        reorder(levels[0..n], order[0..n]);
    }
    _ = alloc;
}

test "arabic shaping" {
    // سلام: seen initial, lam medial... lam + alef -> ligature, meem isolated
    var s = u32s("سلام");
    shapeArabic(&s);
    try std.testing.expectEqualSlices(u21, &.{ 0xFEB3, 0xFEFC, removed, 0xFEE1 }, &s);
    // بيت: initial, medial, final
    var b = u32s("بيت");
    shapeArabic(&b);
    try std.testing.expectEqualSlices(u21, &.{ 0xFE91, 0xFEF4, 0xFE96 }, &b);
    // a right-joining letter breaks the chain: دب -> dal isolated, beh isolated
    var d = u32s("دب");
    shapeArabic(&d);
    try std.testing.expectEqualSlices(u21, &.{ 0xFEA9, 0xFE8F }, &d);
    // marks are transparent: بَت still joins
    var m = u32s("بَت");
    shapeArabic(&m);
    try std.testing.expectEqualSlices(u21, &.{ 0xFE91, 0x064E, 0xFE96 }, &m);
    try std.testing.expectEqual(@as(u21, 0x0628), baseLetter(0xFE91));
    try std.testing.expectEqual(@as(u21, 'x'), baseLetter('x'));
}
