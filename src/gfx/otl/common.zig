//! Tables shared by GSUB and GPOS: bounds-checked reads, coverage and
//! class definitions, GDEF, and the script / feature lists.

const std = @import("std");
const types = @import("types.zig");
const Script = types.Script;

// --- safe big-endian reads: 0 when out of range ---

pub fn rd16(d: []const u8, off: usize) u16 {
    if (off > d.len or d.len - off < 2) return 0;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

pub fn rdi16(d: []const u8, off: usize) i16 {
    return @bitCast(rd16(d, off));
}

pub fn rd32(d: []const u8, off: usize) u32 {
    if (off > d.len or d.len - off < 4) return 0;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

/// The table at `base[off..]`, empty when `off` is 0 (null) or outside.
pub fn at(base: []const u8, off: usize) []const u8 {
    if (off == 0 or off >= base.len) return &.{};
    return base[off..];
}

/// Number of `size`-byte records starting at `off` that really fit.
pub fn fit(d: []const u8, off: usize, n: usize, size: usize) usize {
    if (off >= d.len) return 0;
    return @min(n, (d.len - off) / size);
}

// --- coverage and class definitions ---

/// Coverage index of `gid`, or null.
pub fn coverage(t: []const u8, gid: u16) ?u16 {
    switch (rd16(t, 0)) {
        1 => {
            const n = fit(t, 4, rd16(t, 2), 2);
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = rd16(t, 4 + mid * 2);
                if (gid < g) hi = mid else if (gid > g) lo = mid + 1 else return @intCast(mid);
            }
        },
        2 => {
            const n = fit(t, 4, rd16(t, 2), 6);
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const r = 4 + mid * 6;
                const start = rd16(t, r);
                const end = rd16(t, r + 2);
                if (gid < start) hi = mid else if (gid > end) lo = mid + 1 else {
                    return rd16(t, r + 4) +% (gid - start);
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn classOf(t: []const u8, gid: u16) u16 {
    switch (rd16(t, 0)) {
        1 => {
            const start = rd16(t, 2);
            const n = fit(t, 6, rd16(t, 4), 2);
            if (gid >= start and gid - start < n) return rd16(t, 6 + @as(usize, gid - start) * 2);
        },
        2 => {
            const n = fit(t, 4, rd16(t, 2), 6);
            var lo: usize = 0;
            var hi: usize = n;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const r = 4 + mid * 6;
                if (gid < rd16(t, r)) hi = mid else if (gid > rd16(t, r + 2)) lo = mid + 1 else return rd16(t, r + 4);
            }
        },
        else => {},
    }
    return 0;
}

// --- GDEF ---

pub const Gdef = struct {
    glyph_class: []const u8 = &.{},
    mark_attach: []const u8 = &.{},
    mark_sets: []const u8 = &.{},

    pub fn init(t: []const u8) Gdef {
        if (rd16(t, 0) != 1) return .{};
        var g: Gdef = .{
            .glyph_class = at(t, rd16(t, 4)),
            .mark_attach = at(t, rd16(t, 10)),
        };
        if (rd16(t, 2) >= 2) g.mark_sets = at(t, rd16(t, 12));
        return g;
    }

    pub fn inMarkSet(self: Gdef, set: u16, gid: u16) bool {
        const t = self.mark_sets;
        if (rd16(t, 0) != 1 or set >= rd16(t, 2)) return false;
        return coverage(at(t, rd32(t, 4 + @as(usize, set) * 4)), gid) != null;
    }
};

/// Glyph class of `g`: GDEF when the font has one, otherwise synthesized
/// from the source character (as shapers do).
pub fn glyphClass(gdef: Gdef, gid: u16, umark: bool) u8 {
    if (gdef.glyph_class.len > 0) {
        const c = classOf(gdef.glyph_class, gid);
        return if (c >= 1 and c <= 4) @intCast(c) else 0;
    }
    return if (umark) types.class_mark else types.class_base;
}

// --- scripts and features ---

/// Whether `table` (GSUB or GPOS) has lookups for `script`.
pub fn hasScript(table: []const u8, script: Script) bool {
    return findScript(table, script).len > 0;
}

fn findScript(table: []const u8, script: Script) []const u8 {
    if (rd16(table, 0) != 1) return &.{};
    const list = at(table, rd16(table, 4));
    const n = fit(list, 2, rd16(list, 0), 6);
    const want = script.tag();
    var dflt: []const u8 = &.{};
    for (0..n) |i| {
        const r = 2 + i * 6;
        const t = list[r..][0..4];
        if (std.mem.eql(u8, t, &want)) return at(list, rd16(list, r + 4));
        if (std.mem.eql(u8, t, "DFLT")) dflt = at(list, rd16(list, r + 4));
    }
    // Hebrew needs nothing script-specific; the default script will do.
    // Joining scripts without their own script record have no forms.
    return if (script.joins()) &.{} else dflt;
}

pub const max_lookups = 256;

/// Indices of the lookups of `features` (for `script`), sorted, deduped.
pub fn collectLookups(table: []const u8, script: Script, features: []const *const [4]u8, out: *[max_lookups]u16) []u16 {
    const scr = findScript(table, script);
    if (scr.len == 0) return out[0..0];
    const ls = at(scr, rd16(scr, 0)); // default LangSys
    if (ls.len == 0) return out[0..0];
    const flist = at(table, rd16(table, 6));
    const n_feat = rd16(flist, 0);
    var n: usize = 0;
    const req = rd16(ls, 2);
    const cnt = fit(ls, 6, rd16(ls, 4), 2);
    var k: usize = 0;
    while (k <= cnt) : (k += 1) {
        const fi: u16 = if (k == cnt) req else rd16(ls, 6 + k * 2);
        if (fi >= n_feat or 2 + @as(usize, fi) * 6 + 6 > flist.len) continue;
        const rec = 2 + @as(usize, fi) * 6;
        if (!isWanted(flist[rec..][0..4], features)) continue;
        const feat = at(flist, rd16(flist, rec + 4));
        const nl = fit(feat, 4, rd16(feat, 2), 2);
        for (0..nl) |j| {
            if (n == out.len) break;
            out[n] = rd16(feat, 4 + j * 2);
            n += 1;
        }
    }
    return sortUnique(out[0..n]);
}

fn isWanted(tag: *const [4]u8, features: []const *const [4]u8) bool {
    for (features) |f| {
        if (std.mem.eql(u8, tag, f)) return true;
    }
    return false;
}

/// Sort `s` in place and drop repeats; the deduped prefix.
fn sortUnique(s: []u16) []u16 {
    std.mem.sort(u16, s, {}, std.sort.asc(u16));
    var m: usize = 0;
    for (s, 0..) |v, i| {
        if (i > 0 and v == s[i - 1]) continue;
        s[m] = v;
        m += 1;
    }
    return s[0..m];
}
