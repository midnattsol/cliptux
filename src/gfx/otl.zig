//! OpenType Layout: glyph substitution (GSUB) and positioning (GPOS) from
//! the font's own tables, enough to shape Arabic, Syriac, NKo and Hebrew
//! the way the font designer intended: joining forms (isol/init/medi/fina),
//! required and contextual ligatures (lam-alef...), contextual alternates,
//! kerning and mark attachment (harakat, niqqud).
//!
//! GSUB lookup types 1-7 (reverse chaining, type 8, is skipped) and GPOS
//! types 1, 2, 4, 5, 6, 7, 8 and 9 (cursive attachment, type 3, is
//! skipped). Lookup flags honoured: ignore base glyphs / ligatures /
//! marks, mark attachment class and mark filtering sets (GDEF).
//!
//! Fonts are untrusted: every read is bounds-checked (out-of-range reads
//! yield 0, which every table treats as "nothing here"), nested lookups
//! are depth-limited and each shaping call has an operation budget, so a
//! hostile font can produce wrong glyphs but never a crash or a hang.

const std = @import("std");

/// The raw layout tables of one face (empty when absent).
pub const Tables = struct {
    gsub: []const u8 = &.{},
    gpos: []const u8 = &.{},
    gdef: []const u8 = &.{},
};

/// Joining-form feature masks; `global` is set on every glyph.
pub const mask_isol: u8 = 1;
pub const mask_fina: u8 = 2;
pub const mask_medi: u8 = 4;
pub const mask_init: u8 = 8;
/// Syriac Alaph forms
pub const mask_fin2: u8 = 0x10;
pub const mask_fin3: u8 = 0x20;
pub const mask_med2: u8 = 0x40;
pub const mask_global: u8 = 0x80;

pub const Script = enum {
    arab,
    syrc,
    nko,
    hebr,

    fn tag(self: Script) [4]u8 {
        return switch (self) {
            .arab => "arab".*,
            .syrc => "syrc".*,
            .nko => "nko ".*,
            .hebr => "hebr".*,
        };
    }

    fn joins(self: Script) bool {
        return self != .hebr;
    }
};

pub const class_base: u8 = 1;
pub const class_lig: u8 = 2;
pub const class_mark: u8 = 3;

pub const Glyph = struct {
    gid: u16,
    /// source characters covered: [cl0, cl1)
    cl0: u32,
    cl1: u32,
    mask: u8 = mask_global,
    /// GDEF glyph class (or synthesized: base / mark)
    class: u8 = class_base,
    /// the source character is a combining mark (for fonts without GDEF)
    umark: bool = false,
    /// default-ignorable (ZWJ, ZWNJ...): skipped by matching, not drawn
    ignorable: bool = false,
    lig_id: u8 = 0,
    /// 1-based ligature component a mark belongs to; 0 = none
    lig_comp: u8 = 0,
    lig_n: u8 = 0,
    /// positioning, in font units
    adv: i32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    /// index (in the same buffer) of the glyph this one hangs off
    /// (mark attachment); dx/dy are then relative to that glyph's origin
    attach: i32 = -1,
    /// cursive attachment: the glyph whose baseline this one follows; dy
    /// is relative to it until the chains are resolved
    cursive: i32 = -1,
};

// --- safe big-endian reads: 0 when out of range ---

fn rd16(d: []const u8, off: usize) u16 {
    if (off > d.len or d.len - off < 2) return 0;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn rdi16(d: []const u8, off: usize) i16 {
    return @bitCast(rd16(d, off));
}

fn rd32(d: []const u8, off: usize) u32 {
    if (off > d.len or d.len - off < 4) return 0;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

/// The table at `base[off..]`, empty when `off` is 0 (null) or outside.
fn at(base: []const u8, off: usize) []const u8 {
    if (off == 0 or off >= base.len) return &.{};
    return base[off..];
}

/// Number of `size`-byte records starting at `off` that really fit.
fn fit(d: []const u8, off: usize, n: usize, size: usize) usize {
    if (off >= d.len) return 0;
    return @min(n, (d.len - off) / size);
}

// --- common tables ---

/// Coverage index of `gid`, or null.
fn coverage(t: []const u8, gid: u16) ?u16 {
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

fn classOf(t: []const u8, gid: u16) u16 {
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

const Gdef = struct {
    glyph_class: []const u8 = &.{},
    mark_attach: []const u8 = &.{},
    mark_sets: []const u8 = &.{},

    fn init(t: []const u8) Gdef {
        if (rd16(t, 0) != 1) return .{};
        var g: Gdef = .{
            .glyph_class = at(t, rd16(t, 4)),
            .mark_attach = at(t, rd16(t, 10)),
        };
        if (rd16(t, 2) >= 2) g.mark_sets = at(t, rd16(t, 12));
        return g;
    }

    fn inMarkSet(self: Gdef, set: u16, gid: u16) bool {
        const t = self.mark_sets;
        if (rd16(t, 0) != 1 or set >= rd16(t, 2)) return false;
        return coverage(at(t, rd32(t, 4 + @as(usize, set) * 4)), gid) != null;
    }
};

/// Glyph class of `g`: GDEF when the font has one, otherwise synthesized
/// from the source character (as shapers do).
fn glyphClass(gdef: Gdef, gid: u16, umark: bool) u8 {
    if (gdef.glyph_class.len > 0) {
        const c = classOf(gdef.glyph_class, gid);
        return if (c >= 1 and c <= 4) @intCast(c) else 0;
    }
    return if (umark) class_mark else class_base;
}

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

const max_lookups = 256;

/// Indices of the lookups of `features` (for `script`), sorted, deduped.
fn collectLookups(table: []const u8, script: Script, features: []const *const [4]u8, out: *[max_lookups]u16) []u16 {
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
        const tag = flist[rec..][0..4];
        const wanted = for (features) |f| {
            if (std.mem.eql(u8, tag, f)) break true;
        } else false;
        if (!wanted) continue;
        const feat = at(flist, rd16(flist, rec + 4));
        const nl = fit(feat, 4, rd16(feat, 2), 2);
        for (0..nl) |j| {
            if (n == out.len) break;
            out[n] = rd16(feat, 4 + j * 2);
            n += 1;
        }
    }
    const s = out[0..n];
    std.mem.sort(u16, s, {}, std.sort.asc(u16));
    var m: usize = 0;
    for (s, 0..) |v, i| {
        if (i > 0 and v == s[i - 1]) continue;
        s[m] = v;
        m += 1;
    }
    return s[0..m];
}

// --- lookup application ---

const max_depth = 6;
const max_growth = 4096;

const Lookup = struct {
    kind: u16,
    flag: u16,
    mark_set: u16,
    data: []const u8,
    n_sub: usize,

    fn sub(self: Lookup, i: usize) []const u8 {
        return at(self.data, rd16(self.data, 6 + i * 2));
    }
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(Glyph),
    gdef: Gdef,
    /// GSUB or GPOS table
    table: []const u8,
    is_gsub: bool,
    rtl: bool,
    /// feature mask the current stage applies to
    mask: u8 = mask_global,
    budget: u32,
    lig_counter: u8 = 0,
    limit: usize,

    fn glyphs(self: *Ctx) []Glyph {
        return self.buf.items;
    }

    fn lookup(self: *Ctx, index: u16) ?Lookup {
        const list = at(self.table, rd16(self.table, 8));
        if (index >= rd16(list, 0)) return null;
        const d = at(list, rd16(list, 2 + @as(usize, index) * 2));
        if (d.len < 6) return null;
        const n_sub = fit(d, 6, rd16(d, 4), 2);
        const flag = rd16(d, 2);
        return .{
            .kind = rd16(d, 0),
            .flag = flag,
            .mark_set = if (flag & 0x10 != 0) rd16(d, 6 + n_sub * 2) else 0,
            .data = d,
            .n_sub = n_sub,
        };
    }

    /// Whether glyph `g` is invisible to a lookup with these flags.
    fn skips(self: *Ctx, lk: Lookup, g: Glyph) bool {
        if (g.ignorable) return true;
        switch (g.class) {
            class_base => return lk.flag & 0x02 != 0,
            class_lig => return lk.flag & 0x04 != 0,
            class_mark => {
                if (lk.flag & 0x08 != 0) return true;
                if (lk.flag & 0x10 != 0) return !self.gdef.inMarkSet(lk.mark_set, g.gid);
                const want = lk.flag >> 8;
                if (want != 0) return classOf(self.gdef.mark_attach, g.gid) != want;
                return false;
            },
            else => return false,
        }
    }

    fn next(self: *Ctx, lk: Lookup, i: usize) ?usize {
        var j = i + 1;
        const g = self.glyphs();
        while (j < g.len) : (j += 1) {
            if (!self.skips(lk, g[j])) return j;
        }
        return null;
    }

    fn prev(self: *Ctx, lk: Lookup, i: usize) ?usize {
        var j = i;
        const g = self.glyphs();
        while (j > 0) {
            j -= 1;
            if (!self.skips(lk, g[j])) return j;
        }
        return null;
    }

    fn spend(self: *Ctx) bool {
        if (self.budget == 0) return false;
        self.budget -= 1;
        return true;
    }

    /// Lookup type, looking through an extension lookup.
    fn kindOf(self: *Ctx, lk: Lookup) u16 {
        const ext: u16 = if (self.is_gsub) 7 else 9;
        if (lk.kind != ext or lk.n_sub == 0) return lk.kind;
        return rd16(lk.sub(0), 2);
    }

    /// Run one lookup over the whole buffer.
    fn applyLookup(self: *Ctx, index: u16) !void {
        const lk = self.lookup(index) orelse return;
        if (self.is_gsub and self.kindOf(lk) == 8) {
            // reverse chaining: last glyph first, so substitutions feed
            // the context of the glyphs before them
            var k = self.glyphs().len;
            while (k > 0) {
                k -= 1;
                if (!self.spend()) return;
                const g = self.glyphs()[k];
                if (g.mask & self.mask == 0 or self.skips(lk, g)) continue;
                _ = try self.applyAt(lk, k, 0);
            }
            return;
        }
        var i: usize = 0;
        while (i < self.glyphs().len) {
            if (!self.spend()) return;
            const g = self.glyphs()[i];
            if (g.mask & self.mask == 0 or self.skips(lk, g)) {
                i += 1;
                continue;
            }
            i = (try self.applyAt(lk, i, 0)) orelse i + 1;
        }
    }

    /// Apply the first matching subtable of `lk` at `i`; the index to
    /// continue from when something applied.
    fn applyAt(self: *Ctx, lk: Lookup, i: usize, depth: u8) error{OutOfMemory}!?usize {
        if (depth > max_depth) return null;
        for (0..lk.n_sub) |s| {
            var kind = lk.kind;
            var st = lk.sub(s);
            const ext: u16 = if (self.is_gsub) 7 else 9;
            if (kind == ext) {
                if (rd16(st, 0) != 1) continue;
                kind = rd16(st, 2);
                if (kind == ext) continue;
                st = at(st, rd32(st, 4));
            }
            if (st.len == 0) continue;
            const r = if (self.is_gsub) try self.applySubst(lk, kind, st, i, depth) else try self.applyPos(lk, kind, st, i, depth);
            if (r) |n| return n;
        }
        return null;
    }

    fn setGid(self: *Ctx, i: usize, gid: u16) void {
        const g = &self.glyphs()[i];
        g.gid = gid;
        g.class = glyphClass(self.gdef, gid, g.umark);
    }

    // --- GSUB ---

    fn applySubst(self: *Ctx, lk: Lookup, kind: u16, st: []const u8, i: usize, depth: u8) !?usize {
        const gid = self.glyphs()[i].gid;
        switch (kind) {
            1 => {
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                switch (rd16(st, 0)) {
                    1 => self.setGid(i, gid +% rd16(st, 4)),
                    2 => {
                        if (ci >= rd16(st, 4)) return null;
                        self.setGid(i, rd16(st, 6 + @as(usize, ci) * 2));
                    },
                    else => return null,
                }
                return i + 1;
            },
            2, 3 => {
                if (rd16(st, 0) != 1) return null;
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                if (ci >= rd16(st, 4)) return null;
                const seq = at(st, rd16(st, 6 + @as(usize, ci) * 2));
                const n = fit(seq, 2, rd16(seq, 0), 2);
                if (n == 0) {
                    if (kind == 3) return null;
                    // deletion: the neighbour takes over its characters
                    const g = self.glyphs();
                    if (g.len == 1) return null;
                    if (i > 0) g[i - 1].cl1 = @max(g[i - 1].cl1, g[i].cl1) else g[1].cl0 = @min(g[1].cl0, g[0].cl0);
                    _ = self.buf.orderedRemove(i);
                    return i;
                }
                if (kind == 3) {
                    // alternates: take the first
                    self.setGid(i, rd16(seq, 2));
                    return i + 1;
                }
                if (self.glyphs().len + n - 1 > self.limit) return null;
                const tmpl = self.glyphs()[i];
                self.setGid(i, rd16(seq, 2));
                for (1..n) |k| {
                    var g = tmpl;
                    g.gid = rd16(seq, 2 + k * 2);
                    g.class = glyphClass(self.gdef, g.gid, g.umark);
                    try self.buf.insert(self.alloc, i + k, g);
                }
                return i + n;
            },
            4 => {
                if (rd16(st, 0) != 1) return null;
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                if (ci >= rd16(st, 4)) return null;
                const set = at(st, rd16(st, 6 + @as(usize, ci) * 2));
                const nl = fit(set, 2, rd16(set, 0), 2);
                for (0..nl) |l| {
                    const lig = at(set, rd16(set, 2 + l * 2));
                    const comps = rd16(lig, 2);
                    if (comps == 0 or comps > 16) continue;
                    var pos: [16]usize = undefined;
                    pos[0] = i;
                    var ok = true;
                    for (1..comps) |k| {
                        const j = self.next(lk, pos[k - 1]) orelse {
                            ok = false;
                            break;
                        };
                        if (self.glyphs()[j].gid != rd16(lig, 4 + (k - 1) * 2)) {
                            ok = false;
                            break;
                        }
                        pos[k] = j;
                    }
                    if (!ok) continue;
                    self.ligate(pos[0..comps], rd16(lig, 0));
                    return i + 1;
                }
                return null;
            },
            5, 6 => return self.applyContext(lk, kind == 6, st, i, depth),
            8 => {
                // reverse chaining contextual single substitution
                if (rd16(st, 0) != 1) return null;
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                const nb = rd16(st, 4);
                const oa = 6 + @as(usize, nb) * 2;
                const na = rd16(st, oa);
                const os = oa + 2 + @as(usize, na) * 2;
                if (nb > 256 or na > 256 or ci >= rd16(st, os)) return null;
                const g = self.glyphs();
                var j = i;
                for (0..nb) |k| {
                    j = self.prev(lk, j) orelse return null;
                    if (coverage(at(st, rd16(st, 6 + k * 2)), g[j].gid) == null) return null;
                }
                j = i;
                for (0..na) |k| {
                    j = self.next(lk, j) orelse return null;
                    if (coverage(at(st, rd16(st, oa + 2 + k * 2)), g[j].gid) == null) return null;
                }
                self.setGid(i, rd16(st, os + 2 + @as(usize, ci) * 2));
                return i + 1;
            },
            else => return null,
        }
    }

    /// Replace the glyphs at `pos` (ascending) by ligature `lig` at pos[0].
    /// Marks skipped in between stay, labelled with the component they
    /// follow, so mark-to-ligature positioning finds it.
    fn ligate(self: *Ctx, pos: []const usize, lig: u16) void {
        const g = self.glyphs();
        const first = pos[0];
        const last = pos[pos.len - 1];
        var c0 = g[first].cl0;
        var c1 = g[first].cl1;
        for (g[first .. last + 1]) |x| {
            c0 = @min(c0, x.cl0);
            c1 = @max(c1, x.cl1);
        }
        self.lig_counter +%= 1;
        if (self.lig_counter == 0) self.lig_counter = 1;
        const id = self.lig_counter;
        // Marks between the components get the ligature's id and the
        // component they belong to, counting components of components
        // that were ligatures themselves (as shapers do).
        var so_far: u32 = 0;
        var last_n: u32 = 1;
        var last_id: u8 = 0;
        var k: usize = 0;
        var j = first;
        while (j <= last) : (j += 1) {
            if (k < pos.len and j == pos[k]) {
                last_id = g[j].lig_id;
                last_n = if (g[j].lig_id != 0 and g[j].lig_comp == 0 and g[j].lig_n > 0) g[j].lig_n else 1;
                so_far += last_n;
                k += 1;
            } else {
                var this: u32 = g[j].lig_comp;
                if (this == 0) this = last_n;
                g[j].lig_id = id;
                g[j].lig_comp = @intCast(@min(255, so_far - last_n + @min(this, last_n)));
            }
            g[j].cl0 = c0;
            g[j].cl1 = c1;
        }
        // marks after it that belonged to its last component (when that
        // was a ligature) follow along
        var m = last + 1;
        while (m < g.len and last_id != 0 and g[m].lig_id == last_id and g[m].lig_comp != 0) : (m += 1) {
            g[m].lig_id = id;
            g[m].lig_comp = @intCast(@min(255, so_far - last_n + @min(@as(u32, g[m].lig_comp), last_n)));
        }
        g[first].lig_id = id;
        g[first].lig_comp = 0;
        g[first].lig_n = @intCast(@min(255, so_far));
        self.setGid(first, lig);
        if (g[first].class == class_base and self.gdef.glyph_class.len == 0) g[first].class = class_lig;
        // remove the consumed components, last first
        var r = pos.len;
        while (r > 1) {
            r -= 1;
            _ = self.buf.orderedRemove(pos[r]);
        }
    }

    // --- GPOS ---

    fn applyPos(self: *Ctx, lk: Lookup, kind: u16, st: []const u8, i: usize, depth: u8) !?usize {
        const g = self.glyphs();
        const gid = g[i].gid;
        switch (kind) {
            1 => {
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                const vf = rd16(st, 4);
                switch (rd16(st, 0)) {
                    1 => self.value(i, st, 6, vf),
                    2 => {
                        if (ci >= rd16(st, 6)) return null;
                        self.value(i, st, 8 + @as(usize, ci) * valueSize(vf), vf);
                    },
                    else => return null,
                }
                return i + 1;
            },
            2 => {
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                const j = self.next(lk, i) orelse return null;
                const g2 = g[j].gid;
                const vf1 = rd16(st, 4);
                const vf2 = rd16(st, 6);
                const s1 = valueSize(vf1);
                const s2 = valueSize(vf2);
                switch (rd16(st, 0)) {
                    1 => {
                        if (ci >= rd16(st, 8)) return null;
                        const set = at(st, rd16(st, 10 + @as(usize, ci) * 2));
                        const rec = 2 + s1 + s2;
                        const n = fit(set, 2, rd16(set, 0), rec);
                        var lo: usize = 0;
                        var hi: usize = n;
                        while (lo < hi) {
                            const mid = (lo + hi) / 2;
                            const r = 2 + mid * rec;
                            const sg = rd16(set, r);
                            if (g2 < sg) hi = mid else if (g2 > sg) lo = mid + 1 else {
                                self.value(i, set, r + 2, vf1);
                                self.value(j, set, r + 2 + s1, vf2);
                                return if (vf2 != 0) j + 1 else j;
                            }
                        }
                        return null;
                    },
                    2 => {
                        const c1 = classOf(at(st, rd16(st, 8)), gid);
                        const c2 = classOf(at(st, rd16(st, 10)), g2);
                        const n1 = rd16(st, 12);
                        const n2 = rd16(st, 14);
                        if (c1 >= n1 or c2 >= n2) return null;
                        const r = 16 + (@as(usize, c1) * n2 + c2) * (s1 + s2);
                        if (r + s1 + s2 > st.len) return null;
                        self.value(i, st, r, vf1);
                        self.value(j, st, r + s1, vf2);
                        return if (vf2 != 0) j + 1 else j;
                    },
                    else => return null,
                }
            },
            4, 5, 6 => {
                if (rd16(st, 0) != 1 or g[i].class != class_mark) return null;
                const mi = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                const n_class = rd16(st, 6);
                const marks = at(st, rd16(st, 8));
                const bases = at(st, rd16(st, 10));
                if (mi >= rd16(marks, 0)) return null;
                const mclass = rd16(marks, 2 + @as(usize, mi) * 4);
                if (mclass >= n_class) return null;
                const manchor = anchor(at(marks, rd16(marks, 2 + @as(usize, mi) * 4 + 2))) orelse return null;
                // the glyph it sits on: previous non-mark (base, ligature),
                // or for mark-to-mark the previous glyph, which must be a mark
                var j: usize = i;
                if (kind == 6) {
                    // the previous mark, looking past what the mark
                    // filters skip but not past bases or ligatures
                    var flk = lk;
                    flk.flag &= ~@as(u16, 0x0E);
                    j = self.prev(flk, i) orelse return null;
                    if (g[j].class != class_mark) return null;
                    if (!sameBase(g[i], g[j])) return null;
                } else {
                    while (j > 0) {
                        j -= 1;
                        if (!g[j].ignorable and g[j].class != class_mark) break;
                    } else return null;
                    if (g[j].class == class_mark or g[j].ignorable) return null;
                }
                const bi = coverage(at(st, rd16(st, 4)), g[j].gid) orelse return null;
                if (bi >= rd16(bases, 0)) return null;
                var aoff: usize = 0;
                var arr = bases;
                if (kind == 5) {
                    const la = at(bases, rd16(bases, 2 + @as(usize, bi) * 2));
                    const n_comp = rd16(la, 0);
                    if (n_comp == 0) return null;
                    var comp: usize = n_comp - 1;
                    if (g[i].lig_id != 0 and g[i].lig_id == g[j].lig_id and g[i].lig_comp > 0)
                        comp = @min(@as(usize, g[i].lig_comp), n_comp) - 1;
                    arr = la;
                    aoff = rd16(la, 2 + (comp * n_class + mclass) * 2);
                } else {
                    aoff = rd16(bases, 2 + (@as(usize, bi) * n_class + mclass) * 2);
                }
                const banchor = anchor(at(arr, aoff)) orelse return null;
                const m = &g[i];
                m.attach = @intCast(j);
                m.dx = banchor[0] - manchor[0];
                m.dy = banchor[1] - manchor[1];
                m.adv = 0;
                return i + 1;
            },
            3 => {
                // cursive: this glyph's entry joins the previous one's exit
                if (rd16(st, 0) != 1) return null;
                const n = rd16(st, 4);
                const cj = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                if (cj >= n) return null;
                const entry = anchor(at(st, rd16(st, 6 + @as(usize, cj) * 4))) orelse return null;
                const p = self.prev(lk, i) orelse return null;
                const cp = coverage(at(st, rd16(st, 2)), g[p].gid) orelse return null;
                if (cp >= n) return null;
                const exit = anchor(at(st, rd16(st, 6 + @as(usize, cp) * 4 + 2))) orelse return null;
                self.cursive(lk, p, i, exit, entry);
                return i + 1;
            },
            7, 8 => return self.applyContext(lk, kind == 8, st, i, depth),
            else => return null,
        }
    }

    /// Join glyph `a`'s exit anchor to the next glyph `b`'s entry: the
    /// advances meet at the anchors, and the child (`a` with the
    /// right-to-left flag, else `b`) follows its parent's baseline.
    fn cursive(self: *Ctx, lk: Lookup, a: usize, b: usize, exit: [2]i32, entry: [2]i32) void {
        const g = self.glyphs();
        if (self.rtl) {
            const d = exit[0] +% g[a].dx;
            g[a].adv -%= d;
            g[a].dx -%= d;
            g[b].adv = entry[0] +% g[b].dx;
        } else {
            g[a].adv = exit[0] +% g[a].dx;
            const d = entry[0] +% g[b].dx;
            g[b].adv -%= d;
            g[b].dx -%= d;
        }
        var child = a;
        var parent = b;
        var dy = entry[1] -% exit[1];
        if (lk.flag & 0x01 == 0) {
            child = b;
            parent = a;
            dy = -%dy;
        }
        // a parent attached to its new child lets go; any longer loop
        // through the child is refused
        if (g[parent].cursive == @as(i32, @intCast(child))) {
            g[parent].cursive = -1;
            g[parent].dy = 0;
        }
        var c: i32 = @intCast(parent);
        var steps: usize = 0;
        while (c >= 0 and steps <= g.len) : (steps += 1) {
            if (c == @as(i32, @intCast(child))) return;
            c = g[@intCast(c)].cursive;
        }
        g[child].cursive = @intCast(parent);
        g[child].dy = dy;
    }

    /// Add a ValueRecord to glyph `i`. Right to left, a wider advance
    /// opens the gap on the glyph's left (towards the next logical glyph).
    fn value(self: *Ctx, i: usize, d: []const u8, off: usize, vf: u16) void {
        var o = off;
        const g = &self.glyphs()[i];
        if (vf & 0x1 != 0) {
            g.dx +%= rdi16(d, o);
            o += 2;
        }
        if (vf & 0x2 != 0) {
            g.dy +%= rdi16(d, o);
            o += 2;
        }
        if (vf & 0x4 != 0) {
            const a = rdi16(d, o);
            g.adv +%= a;
            if (self.rtl) g.dx +%= a;
        }
    }

    // --- (chained) context, shared by GSUB 5/6 and GPOS 7/8 ---

    const Seq = struct {
        kind: enum { glyphs, classes, coverages },
        /// u16 items (glyph ids, classes or coverage offsets)
        d: []const u8,
        off: usize,
        n: usize,
        /// class definition, or the subtable coverages are relative to
        base: []const u8,

        fn matches(self: Seq, k: usize, gid: u16) bool {
            const v = rd16(self.d, self.off + k * 2);
            return switch (self.kind) {
                .glyphs => v == gid,
                .classes => classOf(self.base, gid) == v,
                .coverages => coverage(at(self.base, v), gid) != null,
            };
        }
    };

    const Rule = struct {
        back: Seq,
        /// input glyphs after the first (or all, for coverages)
        input: Seq,
        input_has_first: bool,
        ahead: Seq,
        records: []const u8,
        records_off: usize,
        n_records: usize,
    };

    fn applyContext(self: *Ctx, lk: Lookup, chain: bool, st: []const u8, i: usize, depth: u8) !?usize {
        const gid = self.glyphs()[i].gid;
        const fmt = rd16(st, 0);
        const empty: Seq = .{ .kind = .glyphs, .d = &.{}, .off = 0, .n = 0, .base = &.{} };
        switch (fmt) {
            1, 2 => {
                const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
                var set_idx: usize = ci;
                var cd_back: []const u8 = &.{};
                var cd_in: []const u8 = &.{};
                var cd_ahead: []const u8 = &.{};
                var sets_off: usize = 4;
                if (fmt == 2) {
                    if (chain) {
                        cd_back = at(st, rd16(st, 4));
                        cd_in = at(st, rd16(st, 6));
                        cd_ahead = at(st, rd16(st, 8));
                        sets_off = 10;
                    } else {
                        cd_in = at(st, rd16(st, 4));
                        sets_off = 6;
                    }
                    set_idx = classOf(cd_in, gid);
                }
                if (set_idx >= rd16(st, sets_off)) return null;
                const set = at(st, rd16(st, sets_off + 2 + set_idx * 2));
                const nr = fit(set, 2, rd16(set, 0), 2);
                const kind: @TypeOf(empty.kind) = if (fmt == 1) .glyphs else .classes;
                for (0..nr) |r| {
                    const rule = at(set, rd16(set, 2 + r * 2));
                    var rl: Rule = undefined;
                    if (chain) {
                        var o: usize = 0;
                        const nb = rd16(rule, o);
                        rl.back = .{ .kind = kind, .d = rule, .off = o + 2, .n = nb, .base = cd_back };
                        o += 2 + @as(usize, nb) * 2;
                        const ni = rd16(rule, o);
                        if (ni == 0) continue;
                        rl.input = .{ .kind = kind, .d = rule, .off = o + 2, .n = ni - 1, .base = cd_in };
                        o += 2 + (@as(usize, ni) - 1) * 2;
                        const na = rd16(rule, o);
                        rl.ahead = .{ .kind = kind, .d = rule, .off = o + 2, .n = na, .base = cd_ahead };
                        o += 2 + @as(usize, na) * 2;
                        rl.n_records = rd16(rule, o);
                        rl.records = rule;
                        rl.records_off = o + 2;
                    } else {
                        const ni = rd16(rule, 0);
                        if (ni == 0) continue;
                        rl.back = empty;
                        rl.ahead = empty;
                        rl.input = .{ .kind = kind, .d = rule, .off = 4, .n = ni - 1, .base = cd_in };
                        rl.n_records = rd16(rule, 2);
                        rl.records = rule;
                        rl.records_off = 4 + (@as(usize, ni) - 1) * 2;
                    }
                    rl.input_has_first = false;
                    if (try self.applyRule(lk, rl, i, depth)) |n| return n;
                }
                return null;
            },
            3 => {
                var rl: Rule = undefined;
                rl.input_has_first = true;
                if (chain) {
                    var o: usize = 2;
                    const nb = rd16(st, o);
                    rl.back = .{ .kind = .coverages, .d = st, .off = o + 2, .n = nb, .base = st };
                    o += 2 + @as(usize, nb) * 2;
                    const ni = rd16(st, o);
                    if (ni == 0) return null;
                    rl.input = .{ .kind = .coverages, .d = st, .off = o + 2, .n = ni, .base = st };
                    o += 2 + @as(usize, ni) * 2;
                    const na = rd16(st, o);
                    rl.ahead = .{ .kind = .coverages, .d = st, .off = o + 2, .n = na, .base = st };
                    o += 2 + @as(usize, na) * 2;
                    rl.n_records = rd16(st, o);
                    rl.records = st;
                    rl.records_off = o + 2;
                } else {
                    const ni = rd16(st, 2);
                    if (ni == 0) return null;
                    rl.back = empty;
                    rl.ahead = empty;
                    rl.input = .{ .kind = .coverages, .d = st, .off = 6, .n = ni, .base = st };
                    rl.n_records = rd16(st, 4);
                    rl.records = st;
                    rl.records_off = 6 + @as(usize, ni) * 2;
                }
                if (!rl.input.matches(0, gid)) return null;
                return self.applyRule(lk, rl, i, depth);
            },
            else => return null,
        }
    }

    fn applyRule(self: *Ctx, lk: Lookup, rl: Rule, i: usize, depth: u8) !?usize {
        if (!self.spend()) return null;
        const max_in = 64;
        const n_in = if (rl.input_has_first) rl.input.n else rl.input.n + 1;
        if (n_in > max_in or rl.back.n > 256 or rl.ahead.n > 256) return null;
        var pos: [max_in]usize = undefined;
        pos[0] = i;
        const g = self.glyphs();
        for (1..n_in) |k| {
            const j = self.next(lk, pos[k - 1]) orelse return null;
            const item = if (rl.input_has_first) k else k - 1;
            if (!rl.input.matches(item, g[j].gid)) return null;
            pos[k] = j;
        }
        var j = i;
        for (0..rl.back.n) |k| {
            j = self.prev(lk, j) orelse return null;
            if (!rl.back.matches(k, g[j].gid)) return null;
        }
        j = pos[n_in - 1];
        for (0..rl.ahead.n) |k| {
            j = self.next(lk, j) orelse return null;
            if (!rl.ahead.matches(k, g[j].gid)) return null;
        }
        // matched: run the nested lookups at their positions
        var end = pos[n_in - 1] + 1;
        const nrec = fit(rl.records, rl.records_off, rl.n_records, 4);
        for (0..nrec) |r| {
            const seq_i = rd16(rl.records, rl.records_off + r * 4);
            const li = rd16(rl.records, rl.records_off + r * 4 + 2);
            if (seq_i >= n_in) continue;
            const p = pos[seq_i];
            if (p >= self.glyphs().len) continue;
            const nested = self.lookup(li) orelse continue;
            if (self.skips(nested, self.glyphs()[p])) continue;
            const before = self.glyphs().len;
            _ = try self.applyAt(nested, p, depth + 1);
            const after = self.glyphs().len;
            if (after == before) continue;
            // the buffer grew or shrank: shift the later positions
            const delta = @as(isize, @intCast(after)) - @as(isize, @intCast(before));
            for (pos[seq_i + 1 .. n_in]) |*q| q.* = @intCast(@max(@as(isize, @intCast(p)) + 1, @as(isize, @intCast(q.*)) + delta));
            end = @intCast(@max(@as(isize, @intCast(p)) + 1, @as(isize, @intCast(end)) + delta));
        }
        return @min(end, self.glyphs().len);
    }
};

/// Whether two marks sit on the same base or ligature component, so one
/// may stack on the other (mark-to-mark).
fn sameBase(m1: Glyph, m2: Glyph) bool {
    if (m1.lig_id == m2.lig_id) return m1.lig_id == 0 or m1.lig_comp == m2.lig_comp;
    // different ids: fine when one of the marks is itself a ligature
    return (m1.lig_id > 0 and m1.lig_comp == 0) or (m2.lig_id > 0 and m2.lig_comp == 0);
}

/// Turn cursive dy offsets (relative to the parent) into absolute ones:
/// each glyph follows its parent's resolved baseline.
fn resolveCursive(g: []Glyph) void {
    var any = false;
    for (g) |x| any = any or x.cursive >= 0;
    if (!any) return;
    // chains run either way; sweep until every glyph sits on a resolved
    // parent (a bounded number of times: chains are short in practice)
    var resolved: [256]bool = undefined;
    if (g.len > resolved.len) {
        // long buffers: one pass each way is enough for real fonts
        var k = g.len;
        while (k > 0) {
            k -= 1;
            if (g[k].cursive > @as(i32, @intCast(k))) g[k].dy +%= g[@intCast(g[k].cursive)].dy;
        }
        for (g, 0..) |*x, i| {
            if (x.cursive >= 0 and x.cursive < @as(i32, @intCast(i))) x.dy +%= g[@intCast(x.cursive)].dy;
        }
        return;
    }
    const r = resolved[0..g.len];
    for (g, r) |x, *v| v.* = x.cursive < 0;
    var sweep: usize = 0;
    while (sweep < g.len + 1) : (sweep += 1) {
        var changed = false;
        for (g, 0..) |*x, i| {
            if (r[i]) continue;
            const p: usize = @intCast(x.cursive);
            if (p >= g.len) {
                r[i] = true;
                continue;
            }
            if (!r[p]) continue;
            x.dy +%= g[p].dy;
            r[i] = true;
            changed = true;
        }
        if (!changed) break;
    }
}

fn valueSize(vf: u16) usize {
    return @as(usize, @popCount(vf & 0xFF)) * 2;
}

fn anchor(t: []const u8) ?[2]i32 {
    const f = rd16(t, 0);
    if (f < 1 or f > 3 or t.len < 6) return null;
    return .{ rdi16(t, 2), rdi16(t, 4) };
}

const Stage = struct { features: []const *const [4]u8, mask: u8 = mask_global };

fn runStages(ctx: *Ctx, script: Script, stages: []const Stage) !void {
    for (stages) |stage| {
        var buf: [max_lookups]u16 = undefined;
        const lookups = collectLookups(ctx.table, script, stage.features, &buf);
        ctx.mask = stage.mask;
        for (lookups) |li| try ctx.applyLookup(li);
    }
}

const joining_stages = [_]Stage{
    .{ .features = &.{ "ccmp", "locl" } },
    .{ .features = &.{"isol"}, .mask = mask_isol },
    .{ .features = &.{"fina"}, .mask = mask_fina },
    .{ .features = &.{"fin2"}, .mask = mask_fin2 },
    .{ .features = &.{"fin3"}, .mask = mask_fin3 },
    .{ .features = &.{"medi"}, .mask = mask_medi },
    .{ .features = &.{"med2"}, .mask = mask_med2 },
    .{ .features = &.{"init"}, .mask = mask_init },
    .{ .features = &.{"rlig"} },
    .{ .features = &.{"calt"} },
    .{ .features = &.{ "liga", "clig", "mset" } },
};

const plain_stages = [_]Stage{
    .{ .features = &.{ "ccmp", "locl" } },
    .{ .features = &.{ "rlig", "calt", "liga", "clig" } },
};

const pos_stages = [_]Stage{
    .{ .features = &.{ "kern", "curs", "mark", "mkmk", "dist", "abvm", "blwm" } },
};

/// Shape one run (logical order, one font, one direction): GSUB features
/// of `script`, then advances from `advance(gid)` (font units) with marks
/// zero-width, then GPOS. `buf` holds the cmap glyphs, characters and
/// joining masks on entry and the positioned glyphs on return. False (and
/// `buf` untouched) when the font has no GSUB for `script`, so the caller
/// can fall back to presentation forms.
pub fn shape(
    alloc: std.mem.Allocator,
    t: Tables,
    script: Script,
    rtl: bool,
    buf: *std.ArrayList(Glyph),
    advance_ctx: anytype,
    comptime advance: fn (@TypeOf(advance_ctx), u16) i32,
) !bool {
    if (script.joins() and !hasScript(t.gsub, script)) return false;
    const gdef = Gdef.init(t.gdef);
    for (buf.items) |*g| g.class = glyphClass(gdef, g.gid, g.umark);
    const n0 = buf.items.len;
    var ctx: Ctx = .{
        .alloc = alloc,
        .buf = buf,
        .gdef = gdef,
        .table = t.gsub,
        .is_gsub = true,
        .rtl = rtl,
        .budget = @intCast(@min(4_000_000, 2000 + n0 * 400)),
        .limit = @min(n0 * 8 + 64, max_growth + n0),
    };
    if (rd16(t.gsub, 0) == 1) try runStages(&ctx, script, if (script.joins()) &joining_stages else &plain_stages);

    for (buf.items) |*g| {
        g.adv = if (g.ignorable) 0 else advance(advance_ctx, g.gid);
        g.dx = 0;
        g.dy = 0;
        g.attach = -1;
        g.cursive = -1;
    }
    if (rd16(t.gpos, 0) == 1 and hasScript(t.gpos, script)) {
        // zero-width marks before positioning, as the anchors expect
        for (buf.items) |*g| {
            if (g.class == class_mark) g.adv = 0;
        }
        ctx.table = t.gpos;
        ctx.is_gsub = false;
        try runStages(&ctx, script, &pos_stages);
        resolveCursive(buf.items);
    }
    // marks the font did not attach: hang them on the preceding base
    // (centred when they have their own width, else at its trailing edge)
    var base: ?usize = null;
    for (buf.items, 0..) |*g, i| {
        if (g.class != class_mark and !g.umark) {
            if (!g.ignorable) base = i;
            continue;
        }
        if (g.attach >= 0) continue;
        const b = base orelse continue;
        const bg = buf.items[b];
        g.attach = @intCast(b);
        g.dx += if (g.adv > 0) @divTrunc(bg.adv - g.adv, 2) else if (rtl) 0 else bg.adv;
        g.adv = 0;
    }
    return true;
}

// --- tests ---

const ttf = @import("ttf.zig");

fn advOf(f: *const ttf.Font, gid: u16) i32 {
    return @intFromFloat(f.advanceUnits(gid));
}

/// Shape `s` (one run) with `font`; caller frees the result.
fn testShape(alloc: std.mem.Allocator, font: *const ttf.Font, script: Script, rtl: bool, comptime s: []const u8) !?[]Glyph {
    const bidi = @import("bidi.zig");
    var cps: [64]u21 = undefined;
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) cps[n] = cp;
    var masks: [64]u8 = undefined;
    bidi.joiningMasks(cps[0..n], masks[0..n]);
    var buf: std.ArrayList(Glyph) = .empty;
    errdefer buf.deinit(alloc);
    for (cps[0..n], masks[0..n], 0..) |cp, m, i| {
        try buf.append(alloc, .{ .gid = font.glyphIndex(cp), .cl0 = @intCast(i), .cl1 = @intCast(i + 1), .mask = m | mask_global, .umark = bidi.class(cp) == .NSM });
    }
    if (!try shape(alloc, font.layout, script, rtl, &buf, font, advOf)) {
        buf.deinit(alloc);
        return null;
    }
    return try buf.toOwnedSlice(alloc);
}

test "gsub: arabic joining forms and lam-alef from the font" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    }) |path| {
        var font = ttf.Font.load(alloc, path) catch continue;
        defer font.deinit();
        // بيت: three letters, all changed from their nominal glyphs
        const g = (try testShape(alloc, &font, .arab, true, "بيت")) orelse continue;
        defer alloc.free(g);
        try std.testing.expectEqual(@as(usize, 3), g.len);
        try std.testing.expect(g[0].gid != font.glyphIndex(0x628));
        try std.testing.expect(g[1].gid != font.glyphIndex(0x64A));
        try std.testing.expect(g[2].gid != font.glyphIndex(0x62A));
        // ٹ ڈ (Urdu, outside Presentation Forms-B for some) still join:
        // ٹٹ -> initial + final
        const u = (try testShape(alloc, &font, .arab, true, "ٹٹ")).?;
        defer alloc.free(u);
        try std.testing.expect(u[0].gid != u[1].gid);
        try std.testing.expect(u[0].gid != font.glyphIndex(0x679));
        // سلام: lam + alef become one glyph covering both characters
        const s = (try testShape(alloc, &font, .arab, true, "سلام")).?;
        defer alloc.free(s);
        try std.testing.expectEqual(@as(usize, 3), s.len);
        try std.testing.expectEqual(@as(u32, 1), s[1].cl0);
        try std.testing.expectEqual(@as(u32, 3), s[1].cl1);
    }
}

test "gpos: harakat and niqqud attach to their base" {
    const alloc = std.testing.allocator;
    if (ttf.Font.load(alloc, "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf")) |f| {
        var font = f;
        defer font.deinit();
        // بَ: fatha over beh
        const g = (try testShape(alloc, &font, .arab, true, "بَ")).?;
        defer alloc.free(g);
        try std.testing.expectEqual(@as(usize, 2), g.len);
        try std.testing.expectEqual(@as(i32, 0), g[1].attach);
        try std.testing.expectEqual(@as(i32, 0), g[1].adv);
        // the anchors moved it: drawn over the letter, not after it
        try std.testing.expect(g[1].dx != 0 or g[1].dy != 0);
        try std.testing.expect(g[1].dx > -g[0].adv and g[1].dx < g[0].adv);
    } else |_| {}
    if (ttf.Font.load(alloc, "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf")) |f| {
        var font = f;
        defer font.deinit();
        // בָּ: dagesh and qamats under/in bet
        const g = (try testShape(alloc, &font, .hebr, true, "בָּ")).?;
        defer alloc.free(g);
        var attached: usize = 0;
        for (g) |x| {
            if (x.attach == 0) attached += 1;
        }
        try std.testing.expect(attached >= 1);
        try std.testing.expect(g[0].adv > 0);
    } else |_| {}
}

test "chained context on a hand-built GSUB; mutated tables never misbehave" {
    // rlig -> lookups 0, 1 and a dangling 7. Lookup 0: chained context
    // (format 3) whose records run lookup 1 (single: +1) and lookup 0
    // itself (recursion must stop) on glyph 5.
    const alloc = std.testing.allocator;
    const words = [_]u16{
        1, 0, 10, 30, 48, // header: scripts @10, features @30, lookups @48
        1, 0x6172, 0x6162, 8, // 10: 'arab' -> 18
        4, 0, // 18: default langsys -> 22
        0, 0xFFFF, 1, 0, // 22: feature 0
        1, 0x726C, 0x6967, 8, // 30: 'rlig' -> 38
        0, 3, 0, 1, 7, // 38: lookups 0, 1, 7
        2, 6, 40, // 48: lookups @54, @88
        6, 0, 1, 8, // 54: chain context, 1 subtable @62
        3, 0, 1, 20, 0, 2, 0, 1, 0, 0, // 62: format 3, input cov @82, records
        1, 1, 5, // 82: coverage {5}
        1, 8, 1, 8, // 88: single, ignore marks, subtable @96
        1, 6, 1, // 96: format 1, coverage @102, delta 1
        1, 1, 5, // 102: coverage {5}
    };
    var t: [words.len * 2]u8 = undefined;
    for (words, 0..) |v, i| std.mem.writeInt(u16, t[i * 2 ..][0..2], v, .big);

    var buf: std.ArrayList(Glyph) = .empty;
    defer buf.deinit(alloc);
    for (0..6) |i| try buf.append(alloc, .{ .gid = @intCast(3 + i % 3), .cl0 = @intCast(i), .cl1 = @intCast(i + 1) });
    const Adv = struct {
        fn f(_: void, _: u16) i32 {
            return 500;
        }
    };
    try std.testing.expect(try shape(alloc, .{ .gsub = &t }, .arab, true, &buf, {}, Adv.f));
    var got: [6]u16 = undefined;
    for (buf.items, &got) |g, *o| o.* = g.gid;
    try std.testing.expectEqualSlices(u16, &.{ 3, 4, 6, 3, 4, 6 }, &got);

    // every byte flip and truncation is survivable
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var copy: [t.len]u8 = undefined;
    for (0..20000) |_| {
        copy = t;
        for (0..r.intRangeAtMost(u8, 1, 6)) |_| copy[r.uintLessThan(usize, copy.len)] = r.int(u8);
        const len = r.intRangeAtMost(usize, 0, copy.len);
        buf.clearRetainingCapacity();
        for (0..8) |i| try buf.append(alloc, .{ .gid = @intCast(r.intRangeAtMost(u16, 0, 8)), .cl0 = @intCast(i), .cl1 = @intCast(i + 1), .umark = i % 3 == 2 });
        const tables: Tables = .{ .gsub = copy[0..len], .gpos = copy[0..len], .gdef = copy[0..len] };
        _ = try shape(alloc, tables, if (r.boolean()) .arab else .hebr, r.boolean(), &buf, {}, Adv.f);
        for (buf.items) |g| try std.testing.expect(g.attach < @as(i32, @intCast(buf.items.len)));
    }
}

test "shaping survives mutated GSUB/GPOS/GDEF of real fonts" {
    const alloc = std.testing.allocator;
    const sys = @import("../platform/sys.zig");
    const bidi = @import("bidi.zig");
    const seeds = [_]struct { path: []const u8, iters: usize }{
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf", .iters = 300 },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf", .iters = 200 },
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", .iters = 100 },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoNastaliqUrdu-Regular.ttf", .iters = 120 },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansSyriac-Regular.ttf", .iters = 120 },
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansCoptic-Regular.ttf", .iters = 100 },
    };
    const sample = [_]u21{ 0x633, 0x644, 0x627, 0x645, 0x20, 0x628, 0x64E, 0x64A, 0x652, 0x62A, 0x64C, 0x688, 0x6D2, 0x5E9, 0x5C1, 0x5B8, 0x5DC, 0x5D5, 0x5B9, 0x5DD, 0x644, 0x623, 0x651 };
    var masks: [sample.len]u8 = undefined;
    bidi.joiningMasks(&sample, &masks);
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    for (seeds) |sd| {
        const orig = sys.readFileAlloc(alloc, sd.path, 4 * 1024 * 1024) catch continue;
        defer alloc.free(orig);
        const buf = try alloc.dupe(u8, orig);
        defer alloc.free(buf);
        var probe = ttf.Font.parse(alloc, orig, 0) catch continue;
        const tabs = [_][]const u8{ probe.layout.gsub, probe.layout.gpos, probe.layout.gdef };
        probe.deinit();
        var ranges: [3][2]usize = undefined;
        for (tabs, &ranges) |t, *rg| rg.* = .{ @intFromPtr(t.ptr) - @intFromPtr(orig.ptr), t.len };
        var glyphs: std.ArrayList(Glyph) = .empty;
        defer glyphs.deinit(alloc);
        for (0..sd.iters) |_| {
            @memcpy(buf, orig);
            for (0..r.intRangeAtMost(u8, 1, 24)) |_| {
                const rg = ranges[r.uintLessThan(usize, 3)];
                if (rg[1] < 4) continue;
                // bias towards the headers, where offsets and counts live
                const span = if (r.boolean()) @min(rg[1], 256) else rg[1];
                const p = rg[0] + r.uintLessThan(usize, span - 1);
                switch (r.intRangeAtMost(u8, 0, 2)) {
                    0 => buf[p] = r.int(u8),
                    1 => std.mem.writeInt(u16, buf[p..][0..2], 0xFFFF, .big),
                    else => std.mem.writeInt(u16, buf[p..][0..2], r.int(u16) & 0x3F, .big),
                }
            }
            var font = ttf.Font.parse(alloc, buf, 0) catch continue;
            defer font.deinit();
            for ([_]Script{ .arab, .hebr }) |scr| {
                glyphs.clearRetainingCapacity();
                for (sample, masks, 0..) |cp, m, i| try glyphs.append(alloc, .{
                    .gid = font.glyphIndex(cp),
                    .cl0 = @intCast(i),
                    .cl1 = @intCast(i + 1),
                    .mask = m | mask_global,
                    .umark = bidi.class(cp) == .NSM,
                });
                _ = try shape(alloc, font.layout, scr, true, &glyphs, &font, advOf);
                for (glyphs.items) |g| {
                    try std.testing.expect(g.attach < @as(i32, @intCast(glyphs.items.len)));
                    try std.testing.expect(g.cursive < @as(i32, @intCast(glyphs.items.len)));
                    try std.testing.expect(g.cl0 <= g.cl1 and g.cl1 <= sample.len);
                }
            }
        }
    }
}

test "reverse chaining runs last glyph first; ligatures label their marks" {
    const alloc = std.testing.allocator;
    const words = [_]u16{
        1, 0, 10, 30, 46, // header
        1, 0x6172, 0x6162, 8, // 10: 'arab'
        4, 0, // 18
        0, 0xFFFF, 1, 0, // 22
        1, 0x726C, 0x6967, 8, // 30: 'rlig'
        0, 2, 0, 1, // 38: lookups 0, 1
        2, 6, 40, // 46: lookups @52, @86
        8, 0, 1, 8, // 52: reverse chaining, subtable @60
        1, 14, 0, 1, 20, 1, 9, // 60: 5 before a 5 -> 9
        1, 1, 5, // 74: coverage {5}
        1, 1, 5, // 80: lookahead {5}
        4, 8, 1, 8, // 86: ligature, ignore marks, subtable @94
        1, 8, 1, 14, // 94
        1, 1, 3, // 102: coverage {3}
        1, 4, // 108: one ligature @112
        7, 3, 4, 4, // 112: 3 4 4 -> 7
    };
    var t: [words.len * 2]u8 = undefined;
    for (words, 0..) |v, i| std.mem.writeInt(u16, t[i * 2 ..][0..2], v, .big);
    const Adv = struct {
        fn f(_: void, _: u16) i32 {
            return 500;
        }
    };
    var buf: std.ArrayList(Glyph) = .empty;
    defer buf.deinit(alloc);
    for (0..3) |i| try buf.append(alloc, .{ .gid = 5, .cl0 = @intCast(i), .cl1 = @intCast(i + 1) });
    _ = try shape(alloc, .{ .gsub = &t }, .arab, true, &buf, {}, Adv.f);
    var got: [3]u16 = undefined;
    for (buf.items, &got) |g, *o| o.* = g.gid;
    // forward order would give 9 9 5
    try std.testing.expectEqualSlices(u16, &.{ 5, 9, 5 }, &got);

    buf.clearRetainingCapacity();
    for ([_]u16{ 3, 6, 4, 6, 4, 6 }, 0..) |gid, i| try buf.append(alloc, .{ .gid = gid, .cl0 = @intCast(i), .cl1 = @intCast(i + 1), .umark = gid == 6 });
    _ = try shape(alloc, .{ .gsub = &t }, .arab, true, &buf, {}, Adv.f);
    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqual(@as(u16, 7), buf.items[0].gid);
    try std.testing.expectEqual(@as(u8, 3), buf.items[0].lig_n);
    // marks between components belong to the one before them; the mark
    // after the last stays unlabelled (mark-to-ligature then uses the
    // last component)
    for (buf.items[1..3], 1..) |m, k| {
        try std.testing.expectEqual(buf.items[0].lig_id, m.lig_id);
        try std.testing.expectEqual(@as(u8, @intCast(k)), m.lig_comp);
    }
    try std.testing.expectEqual(@as(u8, 0), buf.items[3].lig_comp);
    // mark-to-mark: marks on the same component stack, others do not
    const a: Glyph = .{ .gid = 1, .cl0 = 0, .cl1 = 1, .lig_id = 4, .lig_comp = 2 };
    var b = a;
    try std.testing.expect(sameBase(a, b));
    b.lig_comp = 1;
    try std.testing.expect(!sameBase(a, b));
    b.lig_id = 0;
    b.lig_comp = 0;
    try std.testing.expect(!sameBase(a, b));
    b.lig_id = 9; // b is itself a ligature (of marks)
    try std.testing.expect(sameBase(a, b));
}

test "cursive attachment: Nastaliq words step down to the baseline" {
    const alloc = std.testing.allocator;
    var font = ttf.Font.load(alloc, "/usr/share/fonts/truetype/noto/NotoNastaliqUrdu-Regular.ttf") catch return;
    defer font.deinit();
    // نستعلیق: a cascade, every letter joined to the next by its anchors
    const g = (try testShape(alloc, &font, .arab, true, "نستعلیق")).?;
    defer alloc.free(g);
    var chained: usize = 0;
    var top: i32 = std.math.minInt(i32);
    var bottom: i32 = std.math.maxInt(i32);
    for (g) |x| {
        if (x.class == class_mark) continue;
        if (x.cursive >= 0) chained += 1;
        top = @max(top, x.dy);
        bottom = @min(bottom, x.dy);
    }
    try std.testing.expect(chained >= 4);
    // the word rises towards its start: the first letter sits well above
    // the last (the root of the chain, on the baseline)
    try std.testing.expect(top - bottom > 200);
    var last_base: Glyph = g[g.len - 1];
    for (g) |x| {
        if (x.class != class_mark) last_base = x;
    }
    try std.testing.expectEqual(@as(i32, -1), last_base.cursive);
}
