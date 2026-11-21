//! cmap: picks the best Unicode subtables (formats 4 and 12) and maps
//! code points to glyph ids.

const bytes = @import("bytes.zig");
const beU16 = bytes.beU16;
const beU32 = bytes.beU32;

/// The chosen subtables; either may be empty, not both.
pub const Subtables = struct {
    cmap4: []const u8 = &.{}, // format-4 subtable
    cmap12: []const u8 = &.{}, // format-12 subtable (preferred: covers > U+FFFF)
};

/// Pick the best-scoring format-4 and format-12 Unicode subtables.
pub fn pick(cmap: []const u8) error{ Truncated, NoUsableCmap }!Subtables {
    const n_sub = try beU16(cmap, 2);
    var out: Subtables = .{};
    var best4: i32 = -1;
    var best12: i32 = -1;
    var s: usize = 0;
    while (s < n_sub) : (s += 1) {
        const rec = 4 + s * 8;
        const platform = beU16(cmap, rec) catch break;
        const encoding = beU16(cmap, rec + 2) catch break;
        const sub_off = beU32(cmap, rec + 4) catch break;
        const format = beU16(cmap, sub_off) catch continue;
        const score = encodingScore(platform, encoding);
        if (score < 0) continue;
        if (format == 4 and score > best4) {
            const sub_len = beU16(cmap, sub_off + 2) catch continue;
            const t = cmap[sub_off..@min(cmap.len, sub_off + sub_len)];
            if (!validCmap4(t)) continue;
            best4 = score;
            out.cmap4 = t;
        } else if (format == 12 and score > best12) {
            const n_groups = beU32(cmap, sub_off + 12) catch continue;
            const t = bytes.sub(cmap, sub_off, 16 + @as(usize, n_groups) * 12) orelse continue;
            best12 = score;
            out.cmap12 = t;
        }
    }
    if (out.cmap4.len == 0 and out.cmap12.len == 0) return error.NoUsableCmap;
    return out;
}

/// Preference for an encoding record; negative means not Unicode.
fn encodingScore(platform: u16, encoding: u16) i32 {
    // unicode: (3,10) full, (3,1) BMP, (0,*); (3,0) symbol fonts
    if (platform == 3 and encoding == 10) return 4;
    if (platform == 3 and encoding == 1) return 3;
    if (platform == 0) return 2;
    if (platform == 3 and encoding == 0) return 1;
    return -1;
}

fn validCmap4(t: []const u8) bool {
    // segment arrays must fit: header(14) + 4*segCountX2 + reservedPad(2)
    const seg_x2: usize = beU16(t, 6) catch return false;
    return seg_x2 % 2 == 0 and t.len >= 16 + seg_x2 * 4;
}

/// Format 12: binary search over sequential map groups.
pub fn lookup12(d: []const u8, cp: u21) u16 {
    const n = (d.len - 16) / 12;
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const g = 16 + mid * 12;
        const start = beU32(d, g) catch return 0;
        const end = beU32(d, g + 4) catch return 0;
        if (cp < start) {
            hi = mid;
        } else if (cp > end) {
            lo = mid + 1;
        } else {
            const gid = @as(u64, beU32(d, g + 8) catch return 0) + (cp - start);
            return if (gid <= 0xFFFF) @intCast(gid) else 0;
        }
    }
    return 0;
}

/// Format 4: segment search over the BMP.
pub fn lookup4(d: []const u8, cp: u21) u16 {
    if (cp > 0xFFFF or d.len == 0) return 0;
    const c: u16 = @intCast(cp);
    const seg_x2: usize = beU16(d, 6) catch return 0;
    const seg = seg_x2 / 2;
    const end_base: usize = 14;
    const start_base = end_base + seg_x2 + 2;
    const delta_base = start_base + seg_x2;
    const range_base = delta_base + seg_x2;
    // first segment whose endCode >= c (endCodes are sorted)
    var lo: usize = 0;
    var hi: usize = seg;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if ((beU16(d, end_base + mid * 2) catch return 0) < c) lo = mid + 1 else hi = mid;
    }
    if (lo >= seg) return 0;
    const i = lo;
    const start_code = beU16(d, start_base + i * 2) catch return 0;
    if (c < start_code) return 0;
    const delta = beU16(d, delta_base + i * 2) catch return 0;
    const range_off = beU16(d, range_base + i * 2) catch return 0;
    if (range_off == 0) return c +% delta;
    const addr = range_base + i * 2 + range_off + 2 * @as(usize, c - start_code);
    const gid = beU16(d, addr) catch return 0;
    if (gid == 0) return 0;
    return gid +% delta;
}
