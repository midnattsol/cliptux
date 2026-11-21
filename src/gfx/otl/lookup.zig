//! Lookup application: the shaping context, lookup flags (which glyphs a
//! lookup sees) and running a lookup's subtables over the buffer.

const std = @import("std");
const types = @import("types.zig");
const common = @import("common.zig");
const gsub = @import("gsub.zig");
const gpos = @import("gpos.zig");

const Glyph = types.Glyph;
const Gdef = common.Gdef;
const rd16 = common.rd16;
const rd32 = common.rd32;
const at = common.at;
const fit = common.fit;

const max_depth = 6;

pub const Lookup = struct {
    kind: u16,
    flag: u16,
    mark_set: u16,
    data: []const u8,
    n_sub: usize,

    pub fn sub(self: Lookup, i: usize) []const u8 {
        return at(self.data, rd16(self.data, 6 + i * 2));
    }
};

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(Glyph),
    gdef: Gdef,
    /// GSUB or GPOS table
    table: []const u8,
    is_gsub: bool,
    rtl: bool,
    /// feature mask the current stage applies to
    mask: u8 = types.mask_global,
    budget: u32,
    lig_counter: u8 = 0,
    limit: usize,

    pub fn glyphs(self: *Ctx) []Glyph {
        return self.buf.items;
    }

    pub fn lookup(self: *Ctx, index: u16) ?Lookup {
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
    pub fn skips(self: *Ctx, lk: Lookup, g: Glyph) bool {
        if (g.ignorable) return true;
        switch (g.class) {
            types.class_base => return lk.flag & 0x02 != 0,
            types.class_lig => return lk.flag & 0x04 != 0,
            types.class_mark => {
                if (lk.flag & 0x08 != 0) return true;
                if (lk.flag & 0x10 != 0) return !self.gdef.inMarkSet(lk.mark_set, g.gid);
                const want = lk.flag >> 8;
                if (want != 0) return common.classOf(self.gdef.mark_attach, g.gid) != want;
                return false;
            },
            else => return false,
        }
    }

    /// The next glyph after `i` that `lk` sees.
    pub fn next(self: *Ctx, lk: Lookup, i: usize) ?usize {
        var j = i + 1;
        const g = self.glyphs();
        while (j < g.len) : (j += 1) {
            if (!self.skips(lk, g[j])) return j;
        }
        return null;
    }

    /// The previous glyph before `i` that `lk` sees.
    pub fn prev(self: *Ctx, lk: Lookup, i: usize) ?usize {
        var j = i;
        const g = self.glyphs();
        while (j > 0) {
            j -= 1;
            if (!self.skips(lk, g[j])) return j;
        }
        return null;
    }

    /// Take one operation from the budget; false when it is used up.
    pub fn spend(self: *Ctx) bool {
        if (self.budget == 0) return false;
        self.budget -= 1;
        return true;
    }

    fn extensionKind(self: *Ctx) u16 {
        return if (self.is_gsub) 7 else 9;
    }

    /// Lookup type, looking through an extension lookup.
    fn kindOf(self: *Ctx, lk: Lookup) u16 {
        if (lk.kind != self.extensionKind() or lk.n_sub == 0) return lk.kind;
        return rd16(lk.sub(0), 2);
    }

    /// Whether the current stage's lookups apply to glyph `g`.
    fn wants(self: *Ctx, lk: Lookup, g: Glyph) bool {
        return g.mask & self.mask != 0 and !self.skips(lk, g);
    }

    /// Run one lookup over the whole buffer.
    pub fn applyLookup(self: *Ctx, index: u16) !void {
        const lk = self.lookup(index) orelse return;
        if (self.is_gsub and self.kindOf(lk) == 8) return self.applyReversed(lk);
        var i: usize = 0;
        while (i < self.glyphs().len) {
            if (!self.spend()) return;
            if (!self.wants(lk, self.glyphs()[i])) {
                i += 1;
                continue;
            }
            i = (try self.applyAt(lk, i, 0)) orelse i + 1;
        }
    }

    /// Reverse chaining: last glyph first, so substitutions feed the
    /// context of the glyphs before them.
    fn applyReversed(self: *Ctx, lk: Lookup) !void {
        var k = self.glyphs().len;
        while (k > 0) {
            k -= 1;
            if (!self.spend()) return;
            if (!self.wants(lk, self.glyphs()[k])) continue;
            _ = try self.applyAt(lk, k, 0);
        }
    }

    /// Apply the first matching subtable of `lk` at `i`; the index to
    /// continue from when something applied.
    pub fn applyAt(self: *Ctx, lk: Lookup, i: usize, depth: u8) error{OutOfMemory}!?usize {
        if (depth > max_depth) return null;
        for (0..lk.n_sub) |s| {
            var kind = lk.kind;
            var st = lk.sub(s);
            if (kind == self.extensionKind()) {
                if (rd16(st, 0) != 1) continue;
                kind = rd16(st, 2);
                if (kind == self.extensionKind()) continue;
                st = at(st, rd32(st, 4));
            }
            if (st.len == 0) continue;
            const r = if (self.is_gsub) try gsub.apply(self, lk, kind, st, i, depth) else try gpos.apply(self, lk, kind, st, i, depth);
            if (r) |n| return n;
        }
        return null;
    }

    /// Give glyph `i` a new glyph id (and that glyph's class).
    pub fn setGid(self: *Ctx, i: usize, gid: u16) void {
        const g = &self.glyphs()[i];
        g.gid = gid;
        g.class = common.glyphClass(self.gdef, gid, g.umark);
    }
};
