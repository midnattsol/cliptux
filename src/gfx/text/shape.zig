//! Paragraph shaping: decode, resolve bidi levels, pick a font per
//! character and turn the characters into glyphs (complex scripts with
//! the font's GSUB/GPOS, otherwise one glyph per character). The glyphs
//! land in the state's scratch, in logical order.

const std = @import("std");
const ttf = @import("../ttf.zig");
const utf8 = @import("../utf8.zig");
const bidi = @import("../bidi.zig");
const otl = @import("../otl.zig");
const tabular = @import("tabular.zig");
const state_mod = @import("state.zig");
const layout_mod = @import("layout.zig");

const State = state_mod.State;
const Style = state_mod.Style;
const Scratch = layout_mod.Scratch;
const LGlyph = layout_mod.LGlyph;
const no_font = state_mod.no_font;

/// Zero-width codepoints that should neither draw nor advance.
fn invisible(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x200B and cp <= 0x200F) or bidi.isExplicit(cp) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF or cp == 0x2060;
}

/// Script that needs shaping from the font's layout tables, or null.
/// Presentation forms (U+FB50...) are already shaped and are not listed.
fn scriptOf(cp: u21) ?otl.Script {
    return switch (cp) {
        0x0590...0x05FF, 0xFB1D...0xFB4F => .hebr,
        0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F, 0x08A0...0x08FF => .arab,
        0x0700...0x074F, 0x0860...0x086F => .syrc,
        0x07C0...0x07FF => .nko,
        else => null,
    };
}

pub fn isMark(cp: u21) bool {
    return cp >= 0x0300 and bidi.class(cp) == .NSM;
}

fn advanceUnits(f: *const ttf.Font, gid: u16) i32 {
    const a = f.advanceUnits(gid);
    return if (a < 1e6) @intFromFloat(a) else 0;
}

/// What a decoded paragraph contains.
const Contents = struct { rtl: bool, complex: bool, arabic: bool };

/// Shape paragraph `s` into the scratch (cps, starts, levels, ... lg).
pub fn shapePara(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) !void {
    const sc = &st.scratch;
    const has = try decode(st, s, dir == .rtl);
    try resolveLevels(st, dir, has.rtl);
    try prepareDrawn(st, has.arabic);
    try assignSlots(st, style, has.complex);
    _ = st.styleSlot(style);
    const smear: f64 = if (st.fauxBold(style)) @floatFromInt(state_mod.fauxBoldOffset(size_px)) else 0;
    sc.lg.clearRetainingCapacity();
    try sc.lg.ensureTotalCapacity(st.alloc, sc.cps.items.len);
    try appendGlyphs(st, size_px, style, smear);
}

/// Decode `s` (lossily) into codepoints and their byte offsets.
fn decode(st: *State, s: []const u8, rtl: bool) !Contents {
    const a = st.alloc;
    const sc = &st.scratch;
    sc.cps.clearRetainingCapacity();
    sc.starts.clearRetainingCapacity();
    var has: Contents = .{ .rtl = rtl, .complex = false, .arabic = false };
    var it = utf8.Iterator.init(s);
    var pos: usize = 0;
    while (it.next()) |cp| {
        try sc.cps.append(a, cp);
        try sc.starts.append(a, @intCast(pos));
        pos = it.i;
        if (cp >= 0x0590) {
            has.rtl = has.rtl or bidi.isRtl(cp);
            if (scriptOf(cp)) |scr| {
                has.complex = true;
                has.arabic = has.arabic or scr != .hebr;
            }
        }
    }
    return has;
}

/// Paragraph level and per-character embedding levels (all 0 when the
/// paragraph has nothing right-to-left).
fn resolveLevels(st: *State, dir: bidi.Direction, has_rtl: bool) !void {
    const a = st.alloc;
    const sc = &st.scratch;
    const cps = sc.cps.items;
    try sc.levels.resize(a, cps.len);
    const levels = sc.levels.items;
    sc.para = 0;
    sc.has_rtl = has_rtl;
    if (has_rtl) {
        try sc.types.resize(a, cps.len);
        sc.para = bidi.paragraphLevel(cps, dir);
        bidi.resolveLevels(cps, sc.para, sc.types.items, levels);
    } else @memset(levels, 0);
}

/// Characters as drawn (mirrored at odd levels) and Arabic joining masks.
fn prepareDrawn(st: *State, has_arabic: bool) !void {
    const a = st.alloc;
    const sc = &st.scratch;
    const cps = sc.cps.items;
    try sc.shaped.resize(a, cps.len);
    for (cps, sc.levels.items, sc.shaped.items) |cp, l, *d| d.* = if (l % 2 == 1) bidi.mirror(cp) else cp;
    try sc.masks.resize(a, cps.len);
    if (has_arabic) bidi.joiningMasks(cps, sc.masks.items) else @memset(sc.masks.items, 0);
}

/// Font slot per character.
fn assignSlots(st: *State, style: Style, has_complex: bool) !void {
    const sc = &st.scratch;
    try sc.slots.resize(st.alloc, sc.cps.items.len);
    const slots = sc.slots.items;
    for (sc.shaped.items, slots, 0..) |cp, *sl, i| {
        if (invisible(cp)) {
            sl.* = no_font;
            continue;
        }
        sl.* = st.resolve(style, cp)[0];
        // a combining mark stays in its base's font when that has it
        if (i > 0 and isMark(cp) and slots[i - 1] != no_font and slots[i - 1] != sl.* and
            st.slots[slots[i - 1]].font.hasGlyph(cp)) sl.* = slots[i - 1];
    }
    if (has_complex) unifyScriptRuns(st, style, sc.cps.items, slots);
}

/// Split the paragraph into runs of one font, level and script and append
/// their glyphs: shaped by the font when it can, else one per character.
fn appendGlyphs(st: *State, size_px: f64, style: Style, smear: f64) !void {
    const sc = &st.scratch;
    const cps = sc.cps.items;
    const n = cps.len;
    var arabic_forms = false;
    var i: usize = 0;
    while (i < n) {
        const scr = runScript(cps, i);
        const j = runEnd(sc, i, scr);
        defer i = j;
        if (scr != null and sc.slots.items[i] != no_font and try shapeRun(st, size_px, smear, i, j, scr.?)) continue;
        // Arabic with a font lacking GSUB goes through presentation forms
        const forms = scr != null and scr.? != .hebr;
        if (forms and !arabic_forms) {
            arabic_forms = true;
            try presentationForms(st);
        }
        appendSimpleRun(st, size_px, style, smear, i, j, forms);
    }
}

/// End of the run starting at character `i`: same font, level and script.
fn runEnd(sc: *const Scratch, i: usize, scr: ?otl.Script) usize {
    const cps = sc.cps.items;
    const slots = sc.slots.items;
    const levels = sc.levels.items;
    var j = i + 1;
    while (j < cps.len and slots[j] == slots[i] and levels[j] == levels[i] and
        std.meta.eql(runScript(cps, j), scr) and !invisible(sc.shaped.items[j])) j += 1;
    return j;
}

/// Fill `pforms` with the drawn characters in Arabic presentation forms.
fn presentationForms(st: *State) !void {
    const sc = &st.scratch;
    try sc.pforms.resize(st.alloc, sc.shaped.items.len);
    @memcpy(sc.pforms.items, sc.shaped.items);
    bidi.shapeArabic(sc.pforms.items);
}

/// One glyph per character of [i, j) (Latin and everything simple), from
/// the presentation forms when `forms`. Capacity is reserved by the caller.
fn appendSimpleRun(st: *State, size_px: f64, style: Style, smear: f64, i: usize, j: usize, forms: bool) void {
    const sc = &st.scratch;
    const drawn = sc.shaped.items;
    for (i..j) |k| {
        const cp = if (forms) sc.pforms.items[k] else drawn[k];
        var g: LGlyph = .{ .cp = cp, .c0 = @intCast(k), .c1 = @intCast(k + 1), .level = sc.levels.items[k], .slot = no_font, .gid = 0, .adv = 0 };
        if (!invisible(cp)) {
            const slot = sc.slots.items[k];
            if (cp == drawn[k] and slot != no_font) {
                g.slot = slot;
                g.gid = st.slots[slot].font.glyphIndex(cp);
            }
            if (g.gid == 0) g.slot, g.gid = st.resolve(style, cp);
            if (st.slots[g.slot].font.rasterize(g.gid, size_px)) |gl| {
                g.adv = gl.advance + smear;
            } else |_| {}
            if (style.tabular) tabularDigit(st, &g, size_px, smear);
        }
        sc.lg.appendAssumeCapacity(g);
    }
}

/// A digit drawn as its font's tabular figure: one advance for all ten.
fn tabularDigit(st: *State, g: *LGlyph, size_px: f64, smear: f64) void {
    const d = tabular.digitOf(g.cp) orelse return;
    const p = st.digits(g.slot).place(&st.slots[g.slot].font, d, size_px) orelse return;
    g.gid = p.gid;
    g.adv = p.adv + smear;
    g.dx = p.dx;
}

/// Script of the shaping run character `i` belongs to: its own, or for a
/// combining mark the one of the character it follows.
fn runScript(cps: []const u21, i: usize) ?otl.Script {
    var k = i;
    while (true) {
        if (scriptOf(cps[k])) |scr| return scr;
        if (k == 0 or !isMark(cps[k])) return null;
        k -= 1;
    }
}

/// Use one font for each word of a complex script when one font has all
/// its letters, so joining and marks are not split across fonts.
fn unifyScriptRuns(st: *State, style: Style, cps: []const u21, slots: []u8) void {
    var i: usize = 0;
    while (i < cps.len) {
        const scr = runScript(cps, i) orelse {
            i += 1;
            continue;
        };
        var j = i + 1;
        while (j < cps.len and std.meta.eql(runScript(cps, j), scr)) j += 1;
        defer i = j;
        if (oneFont(slots[i..j])) continue;
        var cands: [8]u8 = undefined;
        const nc = candidateSlots(st.styleSlot(style), slots[i..j], &cands);
        for (cands[0..nc]) |cand| {
            if (!covers(&st.slots[cand].font, cps[i..j], slots[i..j])) continue;
            for (slots[i..j]) |*sl| {
                if (sl.* != no_font) sl.* = cand;
            }
            break;
        }
    }
}

/// Whether the visible characters of a run all use one slot.
fn oneFont(slots: []const u8) bool {
    const first = slots[0];
    for (slots) |sl| {
        if (sl != first and sl != no_font) return false;
    }
    return true;
}

/// Fonts to try for a run: the style's, then those the run uses, in order
/// and without repeats; at most `out.len`.
fn candidateSlots(primary: u8, slots: []const u8, out: []u8) usize {
    out[0] = primary;
    var nc: usize = 1;
    for (slots) |sl| {
        if (sl == no_font or std.mem.indexOfScalar(u8, out[0..nc], sl) != null) continue;
        if (nc == out.len) break;
        out[nc] = sl;
        nc += 1;
    }
    return nc;
}

/// Whether `f` has every visible character of a run.
fn covers(f: *const ttf.Font, cps: []const u21, slots: []const u8) bool {
    for (cps, slots) |cp, sl| {
        if (sl != no_font and !f.hasGlyph(cp)) return false;
    }
    return true;
}

/// Shape characters [i, j) (one font, level and script) with the font's
/// layout tables and append the glyphs. False when the font has no GSUB
/// for the script (the caller falls back to presentation forms).
fn shapeRun(st: *State, size_px: f64, smear: f64, i: usize, j: usize, scr: otl.Script) !bool {
    const a = st.alloc;
    const sc = &st.scratch;
    const font = &st.slots[sc.slots.items[i]].font;
    sc.run.clearRetainingCapacity();
    for (i..j) |k| {
        const cp = sc.shaped.items[k];
        try sc.run.append(a, .{
            .gid = font.glyphIndex(cp),
            .cl0 = @intCast(k),
            .cl1 = @intCast(k + 1),
            .mask = sc.masks.items[k] | otl.mask_global,
            .umark = isMark(cp),
        });
    }
    if (!try otl.shape(a, font.layout, scr, sc.levels.items[i] % 2 == 1, &sc.run, font, advanceUnits)) return false;
    mergeMarkClusters(sc.run.items, sc.cps.items);
    try appendShapedRun(st, size_px, smear, i);
    return true;
}

/// A mark joins the cluster of the glyph it follows, so carets and line
/// breaks never fall between a letter and its marks; then every glyph of
/// a cluster gets the cluster's full character range.
fn mergeMarkClusters(run: []otl.Glyph, cps: []const u21) void {
    for (run[1..], 1..) |*g, k| {
        if (isMark(cps[g.cl0]) and g.cl0 > run[k - 1].cl0) g.cl0 = run[k - 1].cl0;
    }
    var k = run.len;
    while (k > 1) {
        k -= 1;
        if (run[k].cl0 == run[k - 1].cl0) run[k - 1].cl1 = @max(run[k - 1].cl1, run[k].cl1);
    }
    for (run[1..], 1..) |*g, q| {
        if (g.cl0 == run[q - 1].cl0) g.cl1 = run[q - 1].cl1;
    }
}

/// Append the shaped glyphs of the run that starts at character `i`,
/// scaled from font units to pixels.
fn appendShapedRun(st: *State, size_px: f64, smear: f64, i: usize) !void {
    const sc = &st.scratch;
    const slot = sc.slots.items[i];
    const level = sc.levels.items[i];
    const font = &st.slots[slot].font;
    const run = sc.run.items;
    const scale = size_px / font.units_per_em;
    const base: i32 = @intCast(sc.lg.items.len);
    try sc.lg.ensureUnusedCapacity(st.alloc, run.len);
    for (run) |g| {
        const adv = @as(f64, @floatFromInt(g.adv)) * scale;
        sc.lg.appendAssumeCapacity(.{
            .cp = sc.shaped.items[g.cl0],
            .c0 = g.cl0,
            .c1 = g.cl1,
            .level = level,
            .slot = slot,
            .gid = g.gid,
            .adv = if (adv > 0) adv + smear else adv,
            .dx = @as(f64, @floatFromInt(g.dx)) * scale,
            .dy = -@as(f64, @floatFromInt(g.dy)) * scale,
            .attach = if (g.attach >= 0) base + g.attach else -1,
        });
    }
}

/// Drawn bounding box (left, top, right, bottom) of item `it` relative to
/// the line origin and baseline.
fn testBox(st: *State, it: layout_mod.Item, size: f64) [4]f64 {
    const g = st.slots[it.slot].font.rasterize(it.gid, size) catch unreachable;
    const l = it.gx + @as(f64, @floatFromInt(g.bearing_x));
    const t = it.gy + @as(f64, @floatFromInt(g.bearing_y));
    return .{ l, t, l + @as(f64, @floatFromInt(g.w)), t + @as(f64, @floatFromInt(g.h)) };
}

test "complex scripts are shaped with the font: joining, ligatures, marks" {
    const Item = layout_mod.Item;
    const layout = layout_mod.layout;
    const width = @import("measure.zig").width;
    const caret = @import("caret.zig");
    const xForOffset = caret.xForOffset;
    const offsetForX = caret.offsetForX;
    const alloc = std.testing.allocator;
    state_mod.init(alloc);
    defer state_mod.deinit();
    const st = if (state_mod.state) |*p| p else return;
    // Urdu ڈاکٹر: letters outside Presentation Forms-B still join (ٹ
    // and ک take their initial/medial glyphs)
    const urdu = "\u{688}\u{627}\u{6A9}\u{679}\u{631}";
    const items = layout(st, 32, .regular, urdu, .auto).?;
    const slot = items[0].slot;
    if (!otl.hasScript(st.slots[slot].font.layout.gsub, .arab)) return; // no shaping font
    var changed: usize = 0;
    for (items) |it| {
        try std.testing.expectEqual(slot, it.slot); // one font for the word
        if (it.gid != st.slots[slot].font.glyphIndex(it.cp)) changed += 1;
    }
    try std.testing.expect(changed >= 2);
    // lam-alef: one glyph for two characters; the caret between them sits
    // inside it, the ends at its edges
    const la = "\u{644}\u{627}";
    const li = layout(st, 32, .regular, la, .auto).?;
    try std.testing.expectEqual(@as(usize, 1), li.len);
    try std.testing.expectEqual(@as(u32, 0), li[0].start);
    try std.testing.expectEqual(@as(u32, 4), li[0].end);
    const w = width(32, la);
    const mid = xForOffset(32, .regular, la, 2);
    try std.testing.expect(mid > 0 and mid < w);
    try std.testing.expect(@abs(xForOffset(32, .regular, la, 0) - w) <= 1);
    try std.testing.expectEqual(@as(usize, 2), offsetForX(32, .regular, la, mid));
    // fatha sits above beh, over it (not after it); the caret never lands
    // between a letter and its mark
    const bf = "\u{628}\u{64E}";
    const bi = layout(st, 32, .regular, bf, .auto).?;
    try std.testing.expectEqual(@as(usize, 2), bi.len);
    var base: Item = bi[0];
    var mark: Item = bi[1];
    if (mark.cp != 0x64E) std.mem.swap(Item, &base, &mark);
    try std.testing.expectEqual(@as(f64, 0), mark.adv);
    try std.testing.expectEqual(base.start, mark.start);
    const bb = testBox(st, base, 32);
    const mb = testBox(st, mark, 32);
    try std.testing.expect(mb[1] < bb[1] + 2); // top of the mark above the letter's
    const mcx = (mb[0] + mb[2]) / 2;
    try std.testing.expect(mcx > base.x and mcx < base.x + base.adv);
    try std.testing.expectEqual(@as(usize, 0), offsetForX(32, .regular, bf, @intFromFloat(base.x + base.adv - 1)));
    // Hebrew qamats goes under bet
    const hq = "\u{5D1}\u{5B8}";
    const hi = layout(st, 32, .regular, hq, .auto).?;
    for (hi) |it| {
        if (it.cp != 0x5B8) continue;
        const other = if (hi[0].cp == 0x5B8) hi[1] else hi[0];
        const qb = testBox(st, it, 32);
        const ob = testBox(st, other, 32);
        try std.testing.expect(qb[3] > ob[3]); // reaches below the letter
        try std.testing.expect((qb[0] + qb[2]) / 2 > other.x and (qb[0] + qb[2]) / 2 < other.x + other.adv);
    }
    // ASCII is laid out exactly as before: one glyph per character, nominal
    const ascii = "office fi ffl AV To.";
    const ai = layout(st, 20, .regular, ascii, .auto).?;
    try std.testing.expectEqual(ascii.len, ai.len);
    var x: f64 = 0;
    for (ai, 0..) |it, k| {
        try std.testing.expectEqual(@as(u21, ascii[k]), it.cp);
        try std.testing.expectEqual(st.slots[it.slot].font.glyphIndex(ascii[k]), it.gid);
        try std.testing.expectEqual(x, it.x);
        x += it.adv;
    }
}
