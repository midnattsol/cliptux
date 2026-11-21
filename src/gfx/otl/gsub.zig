//! GSUB subtables: single, multiple, alternate, ligature, (chained)
//! context and reverse chaining single substitution.

const types = @import("types.zig");
const common = @import("common.zig");
const context = @import("context.zig");
const lookup = @import("lookup.zig");

const Glyph = types.Glyph;
const Ctx = lookup.Ctx;
const Lookup = lookup.Lookup;
const rd16 = common.rd16;
const at = common.at;
const fit = common.fit;
const coverage = common.coverage;

/// Apply GSUB subtable `st` (type `kind`) at glyph `i`; the index to
/// continue from, or null when it does not apply.
pub fn apply(c: *Ctx, lk: Lookup, kind: u16, st: []const u8, i: usize, depth: u8) !?usize {
    return switch (kind) {
        1 => single(c, st, i),
        2, 3 => try multipleOrAlternate(c, kind == 3, st, i),
        4 => ligature(c, lk, st, i),
        5, 6 => try context.apply(c, lk, kind == 6, st, i, depth),
        8 => reverseChainSingle(c, lk, st, i),
        else => null,
    };
}

fn single(c: *Ctx, st: []const u8, i: usize) ?usize {
    const gid = c.glyphs()[i].gid;
    const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
    switch (rd16(st, 0)) {
        1 => c.setGid(i, gid +% rd16(st, 4)),
        2 => {
            if (ci >= rd16(st, 4)) return null;
            c.setGid(i, rd16(st, 6 + @as(usize, ci) * 2));
        },
        else => return null,
    }
    return i + 1;
}

fn multipleOrAlternate(c: *Ctx, alternate: bool, st: []const u8, i: usize) !?usize {
    if (rd16(st, 0) != 1) return null;
    const ci = coverage(at(st, rd16(st, 2)), c.glyphs()[i].gid) orelse return null;
    if (ci >= rd16(st, 4)) return null;
    const seq = at(st, rd16(st, 6 + @as(usize, ci) * 2));
    const n = fit(seq, 2, rd16(seq, 0), 2);
    if (n == 0) return if (alternate) null else delete(c, i);
    if (alternate) {
        // alternates: take the first
        c.setGid(i, rd16(seq, 2));
        return i + 1;
    }
    return expand(c, seq, n, i);
}

/// Delete glyph `i`; the neighbour takes over its characters.
fn delete(c: *Ctx, i: usize) ?usize {
    const g = c.glyphs();
    if (g.len == 1) return null;
    if (i > 0) g[i - 1].cl1 = @max(g[i - 1].cl1, g[i].cl1) else g[1].cl0 = @min(g[1].cl0, g[0].cl0);
    _ = c.buf.orderedRemove(i);
    return i;
}

/// Replace glyph `i` by the `n` glyphs of sequence `seq`.
fn expand(c: *Ctx, seq: []const u8, n: usize, i: usize) !?usize {
    if (c.glyphs().len + n - 1 > c.limit) return null;
    const tmpl = c.glyphs()[i];
    c.setGid(i, rd16(seq, 2));
    for (1..n) |k| {
        var g = tmpl;
        g.gid = rd16(seq, 2 + k * 2);
        g.class = common.glyphClass(c.gdef, g.gid, g.umark);
        try c.buf.insert(c.alloc, i + k, g);
    }
    return i + n;
}

fn ligature(c: *Ctx, lk: Lookup, st: []const u8, i: usize) ?usize {
    if (rd16(st, 0) != 1) return null;
    const ci = coverage(at(st, rd16(st, 2)), c.glyphs()[i].gid) orelse return null;
    if (ci >= rd16(st, 4)) return null;
    const set = at(st, rd16(st, 6 + @as(usize, ci) * 2));
    const nl = fit(set, 2, rd16(set, 0), 2);
    for (0..nl) |l| {
        const lig = at(set, rd16(set, 2 + l * 2));
        const comps = rd16(lig, 2);
        if (comps == 0 or comps > 16) continue;
        var pos: [16]usize = undefined;
        if (!matchComponents(c, lk, lig, i, pos[0..comps])) continue;
        ligate(c, pos[0..comps], rd16(lig, 0));
        return i + 1;
    }
    return null;
}

/// Whether the glyphs from `i` on spell ligature `lig`'s components;
/// their positions go to `pos`.
fn matchComponents(c: *Ctx, lk: Lookup, lig: []const u8, i: usize, pos: []usize) bool {
    pos[0] = i;
    for (1..pos.len) |k| {
        const j = c.next(lk, pos[k - 1]) orelse return false;
        if (c.glyphs()[j].gid != rd16(lig, 4 + (k - 1) * 2)) return false;
        pos[k] = j;
    }
    return true;
}

/// Component counts while labelling a ligature's marks.
const Components = struct {
    /// components so far, counting those of components that were
    /// ligatures themselves
    so_far: u32 = 0,
    /// components in the last component seen
    last_n: u32 = 1,
    last_id: u8 = 0,

    /// The ligature component of a mark on component `this` of the last
    /// component.
    fn of(self: Components, this: u32) u8 {
        return @intCast(@min(255, self.so_far - self.last_n + @min(this, self.last_n)));
    }
};

/// Replace the glyphs at `pos` (ascending) by ligature `lig` at pos[0].
/// Marks skipped in between stay, labelled with the component they
/// follow, so mark-to-ligature positioning finds it.
fn ligate(c: *Ctx, pos: []const usize, lig: u16) void {
    const g = c.glyphs();
    const first = pos[0];
    const last = pos[pos.len - 1];
    mergeClusters(g[first .. last + 1]);
    const id = nextLigId(c);
    const comps = labelMarks(g, pos, id);
    relabelTrailingMarks(g, last + 1, id, comps);
    g[first].lig_id = id;
    g[first].lig_comp = 0;
    g[first].lig_n = @intCast(@min(255, comps.so_far));
    c.setGid(first, lig);
    if (g[first].class == types.class_base and c.gdef.glyph_class.len == 0) g[first].class = types.class_lig;
    // remove the consumed components, last first
    var r = pos.len;
    while (r > 1) {
        r -= 1;
        _ = c.buf.orderedRemove(pos[r]);
    }
}

/// Give every glyph of `g` the union of their character ranges.
fn mergeClusters(g: []Glyph) void {
    var c0 = g[0].cl0;
    var c1 = g[0].cl1;
    for (g) |x| {
        c0 = @min(c0, x.cl0);
        c1 = @max(c1, x.cl1);
    }
    for (g) |*x| {
        x.cl0 = c0;
        x.cl1 = c1;
    }
}

/// A fresh ligature id (never 0).
fn nextLigId(c: *Ctx) u8 {
    c.lig_counter +%= 1;
    if (c.lig_counter == 0) c.lig_counter = 1;
    return c.lig_counter;
}

/// Marks between the components get the ligature's id and the component
/// they belong to, counting components of components that were ligatures
/// themselves (as shapers do).
fn labelMarks(g: []Glyph, pos: []const usize, id: u8) Components {
    var cs: Components = .{};
    var k: usize = 0;
    for (pos[0]..pos[pos.len - 1] + 1) |j| {
        if (k < pos.len and j == pos[k]) {
            cs.last_id = g[j].lig_id;
            cs.last_n = if (g[j].lig_id != 0 and g[j].lig_comp == 0 and g[j].lig_n > 0) g[j].lig_n else 1;
            cs.so_far += cs.last_n;
            k += 1;
        } else {
            var this: u32 = g[j].lig_comp;
            if (this == 0) this = cs.last_n;
            g[j].lig_id = id;
            g[j].lig_comp = cs.of(this);
        }
    }
    return cs;
}

/// Marks from `from` on that belonged to the last component (when that
/// was a ligature) follow along.
fn relabelTrailingMarks(g: []Glyph, from: usize, id: u8, cs: Components) void {
    var m = from;
    while (m < g.len and cs.last_id != 0 and g[m].lig_id == cs.last_id and g[m].lig_comp != 0) : (m += 1) {
        g[m].lig_id = id;
        g[m].lig_comp = cs.of(g[m].lig_comp);
    }
}

/// Reverse chaining contextual single substitution.
fn reverseChainSingle(c: *Ctx, lk: Lookup, st: []const u8, i: usize) ?usize {
    if (rd16(st, 0) != 1) return null;
    const ci = coverage(at(st, rd16(st, 2)), c.glyphs()[i].gid) orelse return null;
    const nb = rd16(st, 4);
    const oa = 6 + @as(usize, nb) * 2;
    const na = rd16(st, oa);
    const os = oa + 2 + @as(usize, na) * 2;
    if (nb > 256 or na > 256 or ci >= rd16(st, os)) return null;
    const back: context.Seq = .{ .kind = .coverages, .d = st, .off = 6, .n = nb, .base = st };
    const ahead: context.Seq = .{ .kind = .coverages, .d = st, .off = oa + 2, .n = na, .base = st };
    if (!context.matchAround(c, lk, back, i, .back)) return null;
    if (!context.matchAround(c, lk, ahead, i, .ahead)) return null;
    c.setGid(i, rd16(st, os + 2 + @as(usize, ci) * 2));
    return i + 1;
}
