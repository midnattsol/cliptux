//! GPOS subtables: single and pair adjustment, cursive attachment, mark
//! attachment (to base, ligature and mark) and (chained) context; then
//! resolving the cursive chains.

const types = @import("types.zig");
const common = @import("common.zig");
const context = @import("context.zig");
const lookup = @import("lookup.zig");

const Glyph = types.Glyph;
const class_mark = types.class_mark;
const Ctx = lookup.Ctx;
const Lookup = lookup.Lookup;
const rd16 = common.rd16;
const rdi16 = common.rdi16;
const at = common.at;
const fit = common.fit;
const coverage = common.coverage;
const classOf = common.classOf;

/// Apply GPOS subtable `st` (type `kind`) at glyph `i`; the index to
/// continue from, or null when it does not apply.
pub fn apply(c: *Ctx, lk: Lookup, kind: u16, st: []const u8, i: usize, depth: u8) !?usize {
    return switch (kind) {
        1 => single(c, st, i),
        2 => pair(c, lk, st, i),
        3 => cursiveAttach(c, lk, st, i),
        4, 5, 6 => markAttach(c, lk, kind, st, i),
        7, 8 => try context.apply(c, lk, kind == 8, st, i, depth),
        else => null,
    };
}

fn single(c: *Ctx, st: []const u8, i: usize) ?usize {
    const ci = coverage(at(st, rd16(st, 2)), c.glyphs()[i].gid) orelse return null;
    const vf = rd16(st, 4);
    switch (rd16(st, 0)) {
        1 => addValue(c, i, st, 6, vf),
        2 => {
            if (ci >= rd16(st, 6)) return null;
            addValue(c, i, st, 8 + @as(usize, ci) * valueSize(vf), vf);
        },
        else => return null,
    }
    return i + 1;
}

fn pair(c: *Ctx, lk: Lookup, st: []const u8, i: usize) ?usize {
    const ci = coverage(at(st, rd16(st, 2)), c.glyphs()[i].gid) orelse return null;
    const j = c.next(lk, i) orelse return null;
    const vf: [2]u16 = .{ rd16(st, 4), rd16(st, 6) };
    return switch (rd16(st, 0)) {
        1 => pairOfGlyphs(c, st, ci, i, j, vf),
        2 => pairOfClasses(c, st, i, j, vf),
        else => null,
    };
}

/// Format 1: the pair set of the first glyph, searched for the second.
fn pairOfGlyphs(c: *Ctx, st: []const u8, ci: u16, i: usize, j: usize, vf: [2]u16) ?usize {
    if (ci >= rd16(st, 8)) return null;
    const g2 = c.glyphs()[j].gid;
    const set = at(st, rd16(st, 10 + @as(usize, ci) * 2));
    const rec = 2 + valueSize(vf[0]) + valueSize(vf[1]);
    const n = fit(set, 2, rd16(set, 0), rec);
    var lo: usize = 0;
    var hi: usize = n;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = 2 + mid * rec;
        const sg = rd16(set, r);
        if (g2 < sg) hi = mid else if (g2 > sg) lo = mid + 1 else return pairValues(c, set, r + 2, i, j, vf);
    }
    return null;
}

/// Format 2: the record of the two glyphs' classes.
fn pairOfClasses(c: *Ctx, st: []const u8, i: usize, j: usize, vf: [2]u16) ?usize {
    const g = c.glyphs();
    const c1 = classOf(at(st, rd16(st, 8)), g[i].gid);
    const c2 = classOf(at(st, rd16(st, 10)), g[j].gid);
    const n1 = rd16(st, 12);
    const n2 = rd16(st, 14);
    if (c1 >= n1 or c2 >= n2) return null;
    const size = valueSize(vf[0]) + valueSize(vf[1]);
    const r = 16 + (@as(usize, c1) * n2 + c2) * size;
    if (r + size > st.len) return null;
    return pairValues(c, st, r, i, j, vf);
}

/// Add the pair's two value records at `d[off..]`; the index to continue
/// from (the second glyph, unless it was adjusted too).
fn pairValues(c: *Ctx, d: []const u8, off: usize, i: usize, j: usize, vf: [2]u16) usize {
    addValue(c, i, d, off, vf[0]);
    addValue(c, j, d, off + valueSize(vf[0]), vf[1]);
    return if (vf[1] != 0) j + 1 else j;
}

/// Add a ValueRecord to glyph `i`. Right to left, a wider advance
/// opens the gap on the glyph's left (towards the next logical glyph).
fn addValue(c: *Ctx, i: usize, d: []const u8, off: usize, vf: u16) void {
    var o = off;
    const g = &c.glyphs()[i];
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
        if (c.rtl) g.dx +%= a;
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

// --- mark attachment ---

/// Mark-to-base (4), mark-to-ligature (5) and mark-to-mark (6): the
/// mark's anchor meets its base's anchor of the same class.
fn markAttach(c: *Ctx, lk: Lookup, kind: u16, st: []const u8, i: usize) ?usize {
    const g = c.glyphs();
    if (rd16(st, 0) != 1 or g[i].class != class_mark) return null;
    const mi = coverage(at(st, rd16(st, 2)), g[i].gid) orelse return null;
    const n_class = rd16(st, 6);
    const marks = at(st, rd16(st, 8));
    const bases = at(st, rd16(st, 10));
    if (mi >= rd16(marks, 0)) return null;
    const mrec = 2 + @as(usize, mi) * 4;
    const mclass = rd16(marks, mrec);
    if (mclass >= n_class) return null;
    const manchor = anchor(at(marks, rd16(marks, mrec + 2))) orelse return null;
    // the glyph it sits on: previous non-mark (base, ligature),
    // or for mark-to-mark the previous glyph, which must be a mark
    const j = (if (kind == 6) previousMark(c, lk, i) else previousBase(g, i)) orelse return null;
    const bi = coverage(at(st, rd16(st, 4)), g[j].gid) orelse return null;
    if (bi >= rd16(bases, 0)) return null;
    const banchor = (if (kind == 5)
        ligatureAnchor(bases, bi, n_class, mclass, g[i], g[j])
    else
        anchor(at(bases, rd16(bases, 2 + (@as(usize, bi) * n_class + mclass) * 2)))) orelse return null;
    const m = &g[i];
    m.attach = @intCast(j);
    m.dx = banchor[0] - manchor[0];
    m.dy = banchor[1] - manchor[1];
    m.adv = 0;
    return i + 1;
}

/// The previous mark, looking past what the mark filters skip but not
/// past bases or ligatures; null unless it may carry mark `i`.
fn previousMark(c: *Ctx, lk: Lookup, i: usize) ?usize {
    var flk = lk;
    flk.flag &= ~@as(u16, 0x0E);
    const j = c.prev(flk, i) orelse return null;
    const g = c.glyphs();
    if (g[j].class != class_mark) return null;
    if (!sameBase(g[i], g[j])) return null;
    return j;
}

/// The previous visible non-mark before `i`.
fn previousBase(g: []const Glyph, i: usize) ?usize {
    var j: usize = i;
    while (j > 0) {
        j -= 1;
        if (!g[j].ignorable and g[j].class != class_mark) break;
    } else return null;
    if (g[j].class == class_mark or g[j].ignorable) return null;
    return j;
}

/// Anchor of class `mclass` on the ligature component mark `m` belongs
/// to (the last one unless it is labelled for `lig`).
fn ligatureAnchor(bases: []const u8, bi: u16, n_class: u16, mclass: u16, m: Glyph, lig: Glyph) ?[2]i32 {
    const la = at(bases, rd16(bases, 2 + @as(usize, bi) * 2));
    const n_comp = rd16(la, 0);
    if (n_comp == 0) return null;
    var comp: usize = n_comp - 1;
    if (m.lig_id != 0 and m.lig_id == lig.lig_id and m.lig_comp > 0)
        comp = @min(@as(usize, m.lig_comp), n_comp) - 1;
    return anchor(at(la, rd16(la, 2 + (comp * n_class + mclass) * 2)));
}

/// Whether two marks sit on the same base or ligature component, so one
/// may stack on the other (mark-to-mark).
pub fn sameBase(m1: Glyph, m2: Glyph) bool {
    if (m1.lig_id == m2.lig_id) return m1.lig_id == 0 or m1.lig_comp == m2.lig_comp;
    // different ids: fine when one of the marks is itself a ligature
    return (m1.lig_id > 0 and m1.lig_comp == 0) or (m2.lig_id > 0 and m2.lig_comp == 0);
}

// --- cursive attachment ---

/// This glyph's entry anchor joins the previous one's exit.
fn cursiveAttach(c: *Ctx, lk: Lookup, st: []const u8, i: usize) ?usize {
    if (rd16(st, 0) != 1) return null;
    const g = c.glyphs();
    const n = rd16(st, 4);
    const cj = coverage(at(st, rd16(st, 2)), g[i].gid) orelse return null;
    if (cj >= n) return null;
    const entry = anchor(at(st, rd16(st, 6 + @as(usize, cj) * 4))) orelse return null;
    const p = c.prev(lk, i) orelse return null;
    const cp = coverage(at(st, rd16(st, 2)), g[p].gid) orelse return null;
    if (cp >= n) return null;
    const exit = anchor(at(st, rd16(st, 6 + @as(usize, cp) * 4 + 2))) orelse return null;
    joinCursive(g, c.rtl, lk.flag & 0x01 != 0, p, i, exit, entry);
    return i + 1;
}

/// Join glyph `a`'s exit anchor to the next glyph `b`'s entry: the
/// advances meet at the anchors, and the child (`a` with the
/// right-to-left flag, else `b`) follows its parent's baseline.
fn joinCursive(g: []Glyph, rtl: bool, rtl_flag: bool, a: usize, b: usize, exit: [2]i32, entry: [2]i32) void {
    if (rtl) {
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
    const dy = entry[1] -% exit[1];
    if (rtl_flag) linkBaseline(g, a, b, dy) else linkBaseline(g, b, a, -%dy);
}

/// Make `child` follow `parent`'s baseline, `dy` off it. A parent
/// attached to its new child lets go; any longer loop through the child
/// is refused.
fn linkBaseline(g: []Glyph, child: usize, parent: usize, dy: i32) void {
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

/// Turn cursive dy offsets (relative to the parent) into absolute ones:
/// each glyph follows its parent's resolved baseline.
pub fn resolveCursive(g: []Glyph) void {
    var any = false;
    for (g) |x| any = any or x.cursive >= 0;
    if (!any) return;
    // chains run either way; sweep until every glyph sits on a resolved
    // parent (a bounded number of times: chains are short in practice)
    var resolved: [256]bool = undefined;
    if (g.len > resolved.len) return resolveTwoPasses(g);
    const r = resolved[0..g.len];
    for (g, r) |x, *v| v.* = x.cursive < 0;
    var sweep: usize = 0;
    while (sweep < g.len + 1) : (sweep += 1) {
        if (!resolveSweep(g, r)) break;
    }
}

/// Long buffers: one pass each way is enough for real fonts.
fn resolveTwoPasses(g: []Glyph) void {
    var k = g.len;
    while (k > 0) {
        k -= 1;
        if (g[k].cursive > @as(i32, @intCast(k))) g[k].dy +%= g[@intCast(g[k].cursive)].dy;
    }
    for (g, 0..) |*x, i| {
        if (x.cursive >= 0 and x.cursive < @as(i32, @intCast(i))) x.dy +%= g[@intCast(x.cursive)].dy;
    }
}

/// Resolve every glyph whose parent is resolved; whether any changed.
fn resolveSweep(g: []Glyph, r: []bool) bool {
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
    return changed;
}
