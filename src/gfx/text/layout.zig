//! Line layout: a paragraph is shaped once (see shape.zig) and cached in
//! the state's scratch; each line of it is then cut out, reordered to
//! visual order and positioned as `Item`s.

const std = @import("std");
const bidi = @import("../bidi.zig");
const otl = @import("../otl.zig");
const state_mod = @import("state.zig");
const shape = @import("shape.zig");

const State = state_mod.State;
const Style = state_mod.Style;

/// One glyph of a laid-out line, in visual (left-to-right) order.
pub const Item = struct {
    /// first codepoint of the glyph's characters (after mirroring, and
    /// after presentation-form shaping when the font has no GSUB)
    cp: u21,
    /// byte range of the logical character(s) in the source string; every
    /// glyph of a cluster (ligature, base + marks) has the same range
    start: u32,
    end: u32,
    /// part of a right-to-left run (its leading edge is on the right)
    rtl: bool,
    slot: u8,
    gid: u16,
    /// caret box: left edge relative to the start of the line, and advance
    /// (0 for attached marks)
    x: f64,
    adv: f64,
    /// where the glyph is drawn: origin x relative to the line start, and
    /// offset below the baseline (negative: raised)
    gx: f64,
    gy: f64 = 0,
};

/// A glyph in logical order while a line is being laid out.
pub const LGlyph = struct {
    cp: u21,
    /// character index range [c0, c1)
    c0: u32,
    c1: u32,
    level: u8,
    slot: u8,
    gid: u16,
    adv: f64,
    dx: f64 = 0,
    dy: f64 = 0,
    /// global index of the glyph this one is attached to
    attach: i32 = -1,
    // filled while positioning
    x: f64 = 0,
    ox: f64 = 0,
    oy: f64 = 0,
};

pub const Scratch = struct {
    cps: std.ArrayList(u21) = .empty,
    starts: std.ArrayList(u32) = .empty,
    types: std.ArrayList(bidi.Class) = .empty,
    levels: std.ArrayList(u8) = .empty,
    order: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Item) = .empty,
    /// characters as drawn (mirrored at odd levels)
    shaped: std.ArrayList(u21) = .empty,
    /// presentation-form shaped copy (fallback for fonts without GSUB)
    pforms: std.ArrayList(u21) = .empty,
    masks: std.ArrayList(u8) = .empty,
    slots: std.ArrayList(u8) = .empty,
    run: std.ArrayList(otl.Glyph) = .empty,
    lg: std.ArrayList(LGlyph) = .empty,
    glevels: std.ArrayList(u8) = .empty,
    /// total advance of the last laid-out line
    width: f64 = 0,
    /// the paragraph shaped in cps..lg (null: none)
    key: ?ParaKey = null,
    para: u1 = 0,
    has_rtl: bool = false,
    /// the current line's glyphs, levels, and global -> line glyph index
    line: std.ArrayList(LGlyph) = .empty,
    line_levels: std.ArrayList(u8) = .empty,
    remap: std.ArrayList(i32) = .empty,

    pub fn deinit(self: *Scratch, alloc: std.mem.Allocator) void {
        self.cps.deinit(alloc);
        self.starts.deinit(alloc);
        self.types.deinit(alloc);
        self.levels.deinit(alloc);
        self.order.deinit(alloc);
        self.items.deinit(alloc);
        self.shaped.deinit(alloc);
        self.pforms.deinit(alloc);
        self.masks.deinit(alloc);
        self.slots.deinit(alloc);
        self.run.deinit(alloc);
        self.lg.deinit(alloc);
        self.glevels.deinit(alloc);
        self.line.deinit(alloc);
        self.line_levels.deinit(alloc);
        self.remap.deinit(alloc);
    }
};

/// Lay out a line: the whole of `s`, or bytes [a, b) of it when `s` is a
/// paragraph wrapped into several lines. The paragraph is decoded
/// (lossily), its bidi levels resolved and its runs shaped as a whole
/// (complex scripts with the font's GSUB/GPOS, or Arabic presentation
/// forms when the font has none), so letters at a line break keep the
/// forms they have in the unbroken word; then the line's glyphs are
/// reordered to visual order (L1-L2) and positioned. `dir` sets the
/// paragraph direction (.auto: from its first strong character). Item
/// byte offsets are in `s`. The result lives in the state's scratch until
/// the next call; the shaped paragraph is reused while `s`, the size,
/// style and direction stay the same. Null when memory runs out.
pub fn layout(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) ?[]Item {
    return layoutRange(st, size_px, style, s, dir, 0, s.len);
}

pub fn layoutRange(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction, a: usize, b: usize) ?[]Item {
    ensureShaped(st, size_px, style, s, dir) catch return null;
    return placeLine(st, s, a, b) catch null;
}

const ParaKey = struct { hash: u64, len: usize, size: u64, style: Style, dir: bidi.Direction };

/// Shape paragraph `s` into the scratch unless it already holds it.
pub fn ensureShaped(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) !void {
    const key: ParaKey = .{ .hash = std.hash.Wyhash.hash(0, s), .len = s.len, .size = @bitCast(size_px), .style = style, .dir = dir };
    if (st.scratch.key) |k| if (std.meta.eql(k, key)) return;
    st.scratch.key = null;
    try shape.shapePara(st, size_px, style, s, dir);
    st.scratch.key = key;
}

/// Character index of byte offset `off` (the first character starting
/// at or after it).
fn charAt(starts: []const u32, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] < off) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Total advance of the glyphs of bytes [a, b) of the shaped paragraph.
pub fn rangeAdvance(st: *State, a: usize, b: usize) f64 {
    const sc = &st.scratch;
    const c_lo = charAt(sc.starts.items, a);
    const c_hi = charAt(sc.starts.items, b);
    var w: f64 = 0;
    for (sc.lg.items) |g| {
        if (g.c0 >= c_lo and g.c0 < c_hi) w += g.adv;
    }
    return w;
}

/// Visual order and positions of the glyphs of bytes [a, b) of the
/// shaped paragraph `s`.
fn placeLine(st: *State, s: []const u8, a_byte: usize, b_byte: usize) ![]Item {
    const sc = &st.scratch;
    const c_lo = charAt(sc.starts.items, @min(a_byte, s.len));
    const c_hi = @max(c_lo, charAt(sc.starts.items, @min(b_byte, s.len)));
    try collectLine(st, c_lo, c_hi);
    try orderLine(st, c_lo, c_hi);
    sc.width = positionLine(sc.line.items, sc.order.items);
    return emitItems(st, s);
}

/// Copy the paragraph glyphs of characters [c_lo, c_hi) to `line`
/// (logical order), with attachments renumbered to line indices.
fn collectLine(st: *State, c_lo: usize, c_hi: usize) !void {
    const al = st.alloc;
    const sc = &st.scratch;
    const all = sc.lg.items;
    sc.line.clearRetainingCapacity();
    try sc.remap.resize(al, all.len);
    for (all, 0..) |g, k| {
        if (g.c0 >= c_lo and g.c0 < c_hi) {
            sc.remap.items[k] = @intCast(sc.line.items.len);
            try sc.line.append(al, g);
        } else sc.remap.items[k] = -1;
    }
    for (sc.line.items) |*g| {
        if (g.attach >= 0) g.attach = sc.remap.items[@intCast(g.attach)];
    }
}

/// Embedding level of each line glyph (L1: trailing whitespace goes to
/// the paragraph level) and the visual order of the glyphs (L2).
fn orderLine(st: *State, c_lo: usize, c_hi: usize) !void {
    const al = st.alloc;
    const sc = &st.scratch;
    const lg = sc.line.items;
    try sc.glevels.resize(al, lg.len);
    try sc.order.resize(al, lg.len);
    if (sc.has_rtl) {
        try sc.line_levels.resize(al, c_hi - c_lo);
        @memcpy(sc.line_levels.items, sc.levels.items[c_lo..c_hi]);
        bidi.lineLevels(sc.cps.items[c_lo..c_hi], sc.para, sc.line_levels.items);
        for (lg, sc.glevels.items) |g, *l| l.* = sc.line_levels.items[g.c0 - c_lo];
    } else @memset(sc.glevels.items, 0);
    const order = sc.order.items;
    if (sc.has_rtl) bidi.reorder(sc.glevels.items, order) else for (order, 0..) |*o, k| {
        o.* = @intCast(k);
    }
}

/// Place the glyphs left to right in `order`, then attached marks on
/// their bases; returns the line's total advance.
fn positionLine(lg: []LGlyph, order: []const u32) f64 {
    var x: f64 = 0;
    for (order) |li| {
        const g = &lg[li];
        g.x = x;
        g.ox = x + g.dx;
        g.oy = g.dy;
        x += g.adv;
    }
    // attached marks follow their base (always earlier in logical order)
    for (lg, 0..) |*g, k| {
        if (g.attach < 0 or g.attach >= k) continue;
        const b = lg[@intCast(g.attach)];
        g.x = b.x;
        g.ox = b.ox + g.dx;
        g.oy = b.oy + g.dy;
    }
    return x;
}

/// The positioned line glyphs as items, in visual order.
fn emitItems(st: *State, s: []const u8) ![]Item {
    const sc = &st.scratch;
    const n = sc.cps.items.len;
    const lg = sc.line.items;
    sc.items.clearRetainingCapacity();
    try sc.items.ensureTotalCapacity(st.alloc, lg.len);
    for (sc.order.items) |li| {
        const g = lg[li];
        sc.items.appendAssumeCapacity(.{
            .cp = g.cp,
            .start = sc.starts.items[g.c0],
            .end = if (g.c1 < n) sc.starts.items[g.c1] else @intCast(s.len),
            .rtl = sc.glevels.items[li] % 2 == 1,
            .slot = g.slot,
            .gid = g.gid,
            .x = g.x,
            .adv = g.adv,
            .gx = g.ox,
            .gy = g.oy,
        });
    }
    return sc.items.items;
}

test "a word cut across lines keeps the forms of the unbroken word" {
    const measure = @import("measure.zig");
    const alloc = std.testing.allocator;
    state_mod.init(alloc);
    defer state_mod.deinit();
    const st = if (state_mod.state) |*p| p else return;
    const word = "\u{679}\u{6CC}\u{644}\u{6CC}\u{641}\u{648}\u{646}"; // ٹیلیفون
    const full = layout(st, 32, .regular, word, .rtl).?;
    if (!otl.hasScript(st.slots[full[0].slot].font.layout.gsub, .arab)) return;
    var gid_at: [32]u16 = @splat(0);
    for (full) |it| gid_at[it.start] = it.gid;
    const cut = 6; // after three letters
    var n_items: usize = 0;
    for ([_][2]usize{ .{ 0, cut }, .{ cut, word.len } }) |r| {
        const part = layoutRange(st, 32, .regular, word, .rtl, r[0], r[1]).?;
        for (part) |it| {
            try std.testing.expect(it.start >= r[0] and it.start < r[1]);
            // same glyph as in the unbroken word: medial letters at the
            // cut stay medial
            try std.testing.expectEqual(gid_at[it.start], it.gid);
            n_items += 1;
        }
        // and the line's width is its glyphs' advances
        var w: f64 = 0;
        for (part) |it| w += it.adv;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(measure.widthRange(32, .regular, word, r[0], r[1], .rtl))) - w) <= 1);
    }
    try std.testing.expectEqual(full.len, n_items);
    // the isolated shaping of the second half would differ (initial form)
    const alone = layout(st, 32, .regular, word[cut..], .rtl).?;
    var differs = false;
    for (alone) |it| differs = differs or it.gid != gid_at[it.start + cut];
    try std.testing.expect(differs);
}
