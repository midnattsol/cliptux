//! (Chained) context subtables, shared by GSUB 5/6 and GPOS 7/8: match a
//! rule's backtrack, input and lookahead, then run its nested lookups.

const common = @import("common.zig");
const lookup = @import("lookup.zig");

const Ctx = lookup.Ctx;
const Lookup = lookup.Lookup;
const rd16 = common.rd16;
const at = common.at;
const fit = common.fit;
const coverage = common.coverage;
const classOf = common.classOf;

/// A sequence of items a run of glyphs must match.
pub const Seq = struct {
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

const empty: Seq = .{ .kind = .glyphs, .d = &.{}, .off = 0, .n = 0, .base = &.{} };

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

/// Class definitions of the backtrack, input and lookahead sequences.
const ClassDefs = struct {
    back: []const u8 = &.{},
    input: []const u8 = &.{},
    ahead: []const u8 = &.{},
};

/// Apply context (`chain` false) or chained context subtable `st` at `i`.
pub fn apply(c: *Ctx, lk: Lookup, chain: bool, st: []const u8, i: usize, depth: u8) !?usize {
    const fmt = rd16(st, 0);
    switch (fmt) {
        1, 2 => return applyRuleSets(c, lk, chain, fmt == 2, st, i, depth),
        3 => {
            const defs: ClassDefs = .{ .back = st, .input = st, .ahead = st };
            const rl = parseRule(chain, st, 2, .coverages, defs, true) orelse return null;
            if (!rl.input.matches(0, c.glyphs()[i].gid)) return null;
            return applyRule(c, lk, rl, i, depth);
        },
        else => return null,
    }
}

/// Formats 1 (glyphs) and 2 (classes): try the rules of the set the first
/// glyph selects, in order.
fn applyRuleSets(c: *Ctx, lk: Lookup, chain: bool, classes: bool, st: []const u8, i: usize, depth: u8) !?usize {
    const gid = c.glyphs()[i].gid;
    const ci = coverage(at(st, rd16(st, 2)), gid) orelse return null;
    var set_idx: usize = ci;
    var defs: ClassDefs = .{};
    var sets_off: usize = 4;
    if (classes) {
        if (chain) {
            defs = .{ .back = at(st, rd16(st, 4)), .input = at(st, rd16(st, 6)), .ahead = at(st, rd16(st, 8)) };
            sets_off = 10;
        } else {
            defs.input = at(st, rd16(st, 4));
            sets_off = 6;
        }
        set_idx = classOf(defs.input, gid);
    }
    if (set_idx >= rd16(st, sets_off)) return null;
    const set = at(st, rd16(st, sets_off + 2 + set_idx * 2));
    const nr = fit(set, 2, rd16(set, 0), 2);
    for (0..nr) |r| {
        const rule = at(set, rd16(set, 2 + r * 2));
        const rl = parseRule(chain, rule, 0, if (classes) .classes else .glyphs, defs, false) orelse continue;
        if (try applyRule(c, lk, rl, i, depth)) |n| return n;
    }
    return null;
}

/// Read the rule at `d[start..]`; null when it has no input. Without
/// `has_first` the input array leaves out the first glyph.
fn parseRule(chain: bool, d: []const u8, start: usize, kind: @FieldType(Seq, "kind"), defs: ClassDefs, has_first: bool) ?Rule {
    return if (chain) parseChainRule(d, start, kind, defs, has_first) else parsePlainRule(d, start, kind, defs.input, has_first);
}

fn parseChainRule(d: []const u8, start: usize, kind: @FieldType(Seq, "kind"), defs: ClassDefs, has_first: bool) ?Rule {
    var rl: Rule = undefined;
    rl.input_has_first = has_first;
    var o = start;
    const nb = rd16(d, o);
    rl.back = .{ .kind = kind, .d = d, .off = o + 2, .n = nb, .base = defs.back };
    o += 2 + @as(usize, nb) * 2;
    const ni = rd16(d, o);
    if (ni == 0) return null;
    const n_in: usize = if (has_first) ni else ni - 1;
    rl.input = .{ .kind = kind, .d = d, .off = o + 2, .n = n_in, .base = defs.input };
    o += 2 + n_in * 2;
    const na = rd16(d, o);
    rl.ahead = .{ .kind = kind, .d = d, .off = o + 2, .n = na, .base = defs.ahead };
    o += 2 + @as(usize, na) * 2;
    rl.n_records = rd16(d, o);
    rl.records = d;
    rl.records_off = o + 2;
    return rl;
}

fn parsePlainRule(d: []const u8, start: usize, kind: @FieldType(Seq, "kind"), class_def: []const u8, has_first: bool) ?Rule {
    const ni = rd16(d, start);
    if (ni == 0) return null;
    const n_in: usize = if (has_first) ni else ni - 1;
    return .{
        .back = empty,
        .input = .{ .kind = kind, .d = d, .off = start + 4, .n = n_in, .base = class_def },
        .input_has_first = has_first,
        .ahead = empty,
        .records = d,
        .records_off = start + 4 + n_in * 2,
        .n_records = rd16(d, start + 2),
    };
}

fn applyRule(c: *Ctx, lk: Lookup, rl: Rule, i: usize, depth: u8) !?usize {
    if (!c.spend()) return null;
    const max_in = 64;
    const n_in = if (rl.input_has_first) rl.input.n else rl.input.n + 1;
    if (n_in > max_in or rl.back.n > 256 or rl.ahead.n > 256) return null;
    var pos: [max_in]usize = undefined;
    if (!matchInput(c, lk, rl, i, pos[0..n_in])) return null;
    if (!matchAround(c, lk, rl.back, i, .back)) return null;
    if (!matchAround(c, lk, rl.ahead, pos[n_in - 1], .ahead)) return null;
    return try runRecords(c, rl, pos[0..n_in], depth);
}

/// Whether the glyphs from `i` on match the rule's input; their
/// positions go to `pos`.
fn matchInput(c: *Ctx, lk: Lookup, rl: Rule, i: usize, pos: []usize) bool {
    const g = c.glyphs();
    pos[0] = i;
    for (1..pos.len) |k| {
        const j = c.next(lk, pos[k - 1]) orelse return false;
        const item = if (rl.input_has_first) k else k - 1;
        if (!rl.input.matches(item, g[j].gid)) return false;
        pos[k] = j;
    }
    return true;
}

/// Whether the glyphs before (`.back`) or after (`.ahead`) glyph `from`
/// match `seq`, nearest first.
pub fn matchAround(c: *Ctx, lk: Lookup, seq: Seq, from: usize, comptime dir: enum { back, ahead }) bool {
    const g = c.glyphs();
    var j = from;
    for (0..seq.n) |k| {
        j = (if (dir == .back) c.prev(lk, j) else c.next(lk, j)) orelse return false;
        if (!seq.matches(k, g[j].gid)) return false;
    }
    return true;
}

/// Matched: run the nested lookups at their input positions; the index
/// to continue from.
fn runRecords(c: *Ctx, rl: Rule, pos: []usize, depth: u8) !usize {
    var end = pos[pos.len - 1] + 1;
    const nrec = fit(rl.records, rl.records_off, rl.n_records, 4);
    for (0..nrec) |r| {
        const seq_i = rd16(rl.records, rl.records_off + r * 4);
        const li = rd16(rl.records, rl.records_off + r * 4 + 2);
        if (seq_i >= pos.len) continue;
        const p = pos[seq_i];
        if (p >= c.glyphs().len) continue;
        const nested = c.lookup(li) orelse continue;
        if (c.skips(nested, c.glyphs()[p])) continue;
        const before = c.glyphs().len;
        _ = try c.applyAt(nested, p, depth + 1);
        const after = c.glyphs().len;
        if (after == before) continue;
        // the buffer grew or shrank: shift the later positions
        const delta = @as(isize, @intCast(after)) - @as(isize, @intCast(before));
        for (pos[seq_i + 1 ..]) |*q| q.* = shifted(q.*, p, delta);
        end = shifted(end, p, delta);
    }
    return @min(end, c.glyphs().len);
}

/// Position `x` moved by `delta`, but never to or before `p`.
fn shifted(x: usize, p: usize, delta: isize) usize {
    return @intCast(@max(@as(isize, @intCast(p)) + 1, @as(isize, @intCast(x)) + delta));
}
