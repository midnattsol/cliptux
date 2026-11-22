//! Shaping one run: the GSUB feature stages, advances, the GPOS stage and
//! a fallback for marks the font left unattached.

const std = @import("std");
const types = @import("types.zig");
const common = @import("common.zig");
const gpos = @import("gpos.zig");
const Ctx = @import("lookup.zig").Ctx;

const Glyph = types.Glyph;
const Script = types.Script;
const Tables = types.Tables;
const class_mark = types.class_mark;
const mask_global = types.mask_global;
const rd16 = common.rd16;

const max_growth = 4096;

const Stage = struct { features: []const *const [4]u8, mask: u8 = mask_global };

fn runStages(ctx: *Ctx, script: Script, stages: []const Stage) !void {
    for (stages) |stage| {
        var buf: [common.max_lookups]u16 = undefined;
        const lookups = common.collectLookups(ctx.table, script, stage.features, &buf);
        ctx.mask = stage.mask;
        for (lookups) |li| try ctx.applyLookup(li);
    }
}

const joining_stages = [_]Stage{
    .{ .features = &.{ "ccmp", "locl" } },
    .{ .features = &.{"isol"}, .mask = types.mask_isol },
    .{ .features = &.{"fina"}, .mask = types.mask_fina },
    .{ .features = &.{"fin2"}, .mask = types.mask_fin2 },
    .{ .features = &.{"fin3"}, .mask = types.mask_fin3 },
    .{ .features = &.{"medi"}, .mask = types.mask_medi },
    .{ .features = &.{"med2"}, .mask = types.mask_med2 },
    .{ .features = &.{"init"}, .mask = types.mask_init },
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
    if (script.joins() and !common.hasScript(t.gsub, script)) return false;
    const gdef = common.Gdef.init(t.gdef);
    for (buf.items) |*g| g.class = common.glyphClass(gdef, g.gid, g.umark);
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
    resetPositions(buf.items, advance_ctx, advance);
    if (rd16(t.gpos, 0) == 1 and common.hasScript(t.gpos, script)) try position(&ctx, t.gpos, script);
    hangUnattachedMarks(buf.items, rtl);
    return true;
}

/// Apply only the GSUB lookups of `features` (for `script`, else the
/// font's default script) to `buf`: no other substitution, no
/// positioning. For optional features such as tabular figures ("tnum").
pub fn substitute(alloc: std.mem.Allocator, t: Tables, script: Script, features: []const *const [4]u8, buf: *std.ArrayList(Glyph)) !void {
    if (rd16(t.gsub, 0) != 1) return;
    const gdef = common.Gdef.init(t.gdef);
    for (buf.items) |*g| g.class = common.glyphClass(gdef, g.gid, g.umark);
    const n0 = buf.items.len;
    var ctx: Ctx = .{
        .alloc = alloc,
        .buf = buf,
        .gdef = gdef,
        .table = t.gsub,
        .is_gsub = true,
        .rtl = false,
        .budget = @intCast(@min(4_000_000, 2000 + n0 * 400)),
        .limit = @min(n0 * 8 + 64, max_growth + n0),
    };
    try runStages(&ctx, script, &.{.{ .features = features }});
}

/// Nominal advances (none for ignorables) and no offsets or attachments.
fn resetPositions(items: []Glyph, advance_ctx: anytype, comptime advance: fn (@TypeOf(advance_ctx), u16) i32) void {
    for (items) |*g| {
        g.adv = if (g.ignorable) 0 else advance(advance_ctx, g.gid);
        g.dx = 0;
        g.dy = 0;
        g.attach = -1;
        g.cursive = -1;
    }
}

/// Run the GPOS stage over the substituted glyphs.
fn position(ctx: *Ctx, table: []const u8, script: Script) !void {
    // zero-width marks before positioning, as the anchors expect
    for (ctx.glyphs()) |*g| {
        if (g.class == class_mark) g.adv = 0;
    }
    ctx.table = table;
    ctx.is_gsub = false;
    try runStages(ctx, script, &pos_stages);
    gpos.resolveCursive(ctx.glyphs());
}

/// Marks the font did not attach: hang them on the preceding base
/// (centred when they have their own width, else at its trailing edge).
fn hangUnattachedMarks(items: []Glyph, rtl: bool) void {
    var base: ?usize = null;
    for (items, 0..) |*g, i| {
        if (g.class != class_mark and !g.umark) {
            if (!g.ignorable) base = i;
            continue;
        }
        if (g.attach >= 0) continue;
        const b = base orelse continue;
        const bg = items[b];
        g.attach = @intCast(b);
        g.dx += if (g.adv > 0) @divTrunc(bg.adv - g.adv, 2) else if (rtl) 0 else bg.adv;
        g.adv = 0;
    }
}

const ttf = @import("../ttf.zig");
const sameBase = gpos.sameBase;

fn advOf(f: *const ttf.Font, gid: u16) i32 {
    return @intFromFloat(f.advanceUnits(gid));
}

/// Shape `s` (one run) with `font`; caller frees the result.
fn testShape(alloc: std.mem.Allocator, font: *const ttf.Font, script: Script, rtl: bool, comptime s: []const u8) !?[]Glyph {
    const bidi = @import("../bidi.zig");
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

test "one optional feature, from the default script, on a hand-built GSUB" {
    // 'DFLT' only; 'tnum' -> lookup 0: single substitution, glyph 5 -> 105
    const alloc = std.testing.allocator;
    const words = [_]u16{
        1, 0, 10, 30, 48, // header: scripts @10, features @30, lookups @48
        1, 0x4446, 0x4C54, 8, // 10: 'DFLT' -> 18
        4, 0, // 18: default langsys -> 22
        0, 0xFFFF, 1, 0, // 22: feature 0
        1, 0x746E, 0x756D, 8, // 30: 'tnum' -> 38
        0, 1, 0, 0, 0, // 38: lookup 0 (and padding)
        1, 4, // 48: lookup @52
        1, 0, 1, 8, // 52: single, 1 subtable @60
        1, 6, 100, // 60: format 1, coverage @66, delta 100
        1, 1, 5, // 66: coverage {5}
    };
    var t: [words.len * 2]u8 = undefined;
    for (words, 0..) |v, i| std.mem.writeInt(u16, t[i * 2 ..][0..2], v, .big);
    var buf: std.ArrayList(Glyph) = .empty;
    defer buf.deinit(alloc);
    for ([_]u16{ 4, 5, 6 }, 0..) |g, i| try buf.append(alloc, .{ .gid = g, .cl0 = @intCast(i), .cl1 = @intCast(i + 1) });
    try substitute(alloc, .{ .gsub = &t }, .latn, &.{"tnum"}, &buf);
    try std.testing.expectEqual(@as(u16, 105), buf.items[1].gid);
    try std.testing.expectEqual(@as(u16, 4), buf.items[0].gid);
    // a feature the font does not have changes nothing
    try substitute(alloc, .{ .gsub = &t }, .latn, &.{"pnum"}, &buf);
    try std.testing.expectEqual(@as(u16, 105), buf.items[1].gid);
}

test "shaping survives mutated GSUB/GPOS/GDEF of real fonts" {
    const alloc = std.testing.allocator;
    const sys = @import("../../platform/sys.zig");
    const bidi = @import("../bidi.zig");
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
