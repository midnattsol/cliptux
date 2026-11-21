//! High-level text drawing: system fonts (found through fontconfig or a
//! directory scan, see fontdb.zig) with a per-codepoint fallback chain, so
//! characters the UI font lacks come from another installed face instead of
//! tofu. Falls back to the 5x7 bitmap font when no usable font exists.
//! Sizes are in pixels (already display-scaled). Text is decoded lossily:
//! invalid UTF-8 shows as U+FFFD, never crashes.

const std = @import("std");
const ttf = @import("ttf.zig");
const fontdb = @import("fontdb.zig");
const utf8 = @import("utf8.zig");
const bidi = @import("bidi.zig");
const otl = @import("otl.zig");
const wrap_mod = @import("wrap.zig");
const render = @import("render.zig");

const Canvas = render.Canvas;

pub const Style = enum { regular, bold, mono };

const max_fonts = 24;
const max_failed = 32;
const no_font: u8 = 0xFF;

const Slot = struct {
    font: ttf.Font,
    path: []u8,
    index: u32,
};

const State = struct {
    alloc: std.mem.Allocator,
    db: fontdb.Db,
    slots: [max_fonts]Slot = undefined,
    n: usize = 0,
    regular: u8 = no_font,
    bold: u8 = no_font,
    mono: u8 = no_font,
    bold_tried: bool = false,
    mono_tried: bool = false,
    /// bold style drawn by smearing the regular face horizontally
    faux_bold: bool = false,
    next_fallback: usize = 0,
    /// codepoint -> slot holding it (no_font: nothing has it)
    cp_cache: std.AutoHashMapUnmanaged(u21, u8) = .empty,
    failed: [max_failed][]u8 = undefined,
    n_failed: usize = 0,
    /// per-call layout scratch, reused
    scratch: Scratch = .{},

    fn deinit(self: *State) void {
        for (self.slots[0..self.n]) |*s| {
            s.font.deinit();
            self.alloc.free(s.path);
        }
        for (self.failed[0..self.n_failed]) |p| self.alloc.free(p);
        self.scratch.deinit(self.alloc);
        self.cp_cache.deinit(self.alloc);
        self.db.deinit();
    }

    /// Load `face` (taking ownership of its path) unless already loaded or
    /// known bad; returns its slot.
    fn add(self: *State, face: fontdb.Face) ?u8 {
        for (self.slots[0..self.n], 0..) |*s, i| {
            if (s.index == face.index and std.mem.eql(u8, s.path, face.path)) {
                face.deinit(self.alloc);
                return @intCast(i);
            }
        }
        for (self.failed[0..self.n_failed]) |p| {
            if (std.mem.eql(u8, p, face.path)) {
                face.deinit(self.alloc);
                return null;
            }
        }
        if (self.n >= max_fonts) {
            face.deinit(self.alloc);
            return null;
        }
        const f = ttf.Font.loadFace(self.alloc, face.path, face.index) catch |e| {
            std.log.debug("font {s}: {t}", .{ face.path, e });
            if (self.n_failed < max_failed) {
                self.failed[self.n_failed] = face.path;
                self.n_failed += 1;
            } else face.deinit(self.alloc);
            return null;
        };
        self.slots[self.n] = .{ .font = f, .path = face.path, .index = face.index };
        self.n += 1;
        return @intCast(self.n - 1);
    }

    /// First loadable face for `q`: fontconfig's pick, then the scan list.
    fn loadQuery(self: *State, q: fontdb.Query) u8 {
        if (self.db.match(q)) |f| if (self.add(f)) |i| return i;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const f = self.db.scanMatch(q, k) orelse break;
            if (self.add(f)) |i| return i;
        }
        return no_font;
    }

    fn styleSlot(self: *State, style: Style) u8 {
        switch (style) {
            .regular => return self.regular,
            .bold => {
                if (!self.bold_tried) {
                    self.bold_tried = true;
                    self.bold = self.loadQuery(.sans_bold);
                    // fontconfig answers with the regular face when no bold exists
                    self.faux_bold = self.bold == no_font or self.bold == self.regular;
                    if (self.faux_bold) self.bold = no_font;
                }
                return if (self.bold != no_font) self.bold else self.regular;
            },
            .mono => {
                if (!self.mono_tried) {
                    self.mono_tried = true;
                    self.mono = self.loadQuery(.mono);
                }
                return if (self.mono != no_font) self.mono else self.regular;
            },
        }
    }

    /// Slot and glyph index used to draw `cp` in `style`.
    fn resolve(self: *State, style: Style, cp: u21) struct { u8, u16 } {
        const primary = self.styleSlot(style);
        const pg = self.slots[primary].font.glyphIndex(cp);
        if (pg != 0) return .{ primary, pg };
        if (primary != self.regular) {
            const rg = self.slots[self.regular].font.glyphIndex(cp);
            if (rg != 0) return .{ self.regular, rg };
        }
        const slot = self.fallbackSlot(cp);
        if (slot != no_font) return .{ slot, self.slots[slot].font.glyphIndex(cp) };
        // an Arabic presentation form no font has: draw the plain letter
        const base = bidi.baseLetter(cp);
        if (base != cp) return self.resolve(style, base);
        return .{ primary, 0 }; // .notdef box
    }

    fn fallbackSlot(self: *State, cp: u21) u8 {
        if (self.cp_cache.get(cp)) |s| return s;
        const found = self.findFallback(cp);
        if (self.cp_cache.count() > 8192) self.cp_cache.clearRetainingCapacity();
        self.cp_cache.put(self.alloc, cp, found) catch {};
        return found;
    }

    fn findFallback(self: *State, cp: u21) u8 {
        for (self.slots[0..self.n], 0..) |*s, i| {
            if (s.font.hasGlyph(cp)) return @intCast(i);
        }
        if (self.db.forCodepoint(cp)) |f| {
            if (self.add(f)) |i| if (self.slots[i].font.hasGlyph(cp)) return i;
        }
        // no fontconfig answer: load the well-known wide-coverage faces in
        // order until one has it (each is loaded at most once)
        while (self.db.fallback(self.next_fallback)) |f| {
            self.next_fallback += 1;
            if (self.add(f)) |i| if (self.slots[i].font.hasGlyph(cp)) return i;
        }
        return no_font;
    }
};

var state: ?State = null;

/// Find and load the system UI font once at startup. Safe to call
/// repeatedly. Bold, monospace and fallback faces load on first use.
pub fn init(alloc: std.mem.Allocator) void {
    initWith(alloc, null);
}

/// init, with `font_path` (when given and loadable) as the regular face
/// instead of the system UI font; for development tools and tests.
pub fn initWith(alloc: std.mem.Allocator, font_path: ?[]const u8) void {
    if (state != null) return;
    var st: State = .{ .alloc = alloc, .db = fontdb.Db.init(alloc) };
    if (font_path) |fp| if (alloc.dupe(u8, fp)) |path| {
        st.regular = st.add(.{ .path = path }) orelse no_font;
    } else |_| {};
    if (st.regular == no_font) st.regular = st.loadQuery(.sans);
    if (st.regular == no_font) {
        // any face at all beats the bitmap font
        var k: usize = 0;
        while (st.db.fallback(k)) |f| : (k += 1) {
            st.regular = st.add(f) orelse continue;
            break;
        }
        st.next_fallback = k;
    }
    if (st.regular == no_font) {
        std.log.warn("no usable system font found; falling back to the bitmap font", .{});
        st.deinit();
        return;
    }
    state = st;
}

pub fn deinit() void {
    clearWrapCache();
    if (state) |*st| st.deinit();
    state = null;
}

pub fn available() bool {
    return state != null;
}

/// Zero-width codepoints that should neither draw nor advance.
fn invisible(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x200B and cp <= 0x200F) or bidi.isExplicit(cp) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF or cp == 0x2060;
}

fn fauxBoldOffset(size_px: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(size_px / 24.0))));
}

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
const LGlyph = struct {
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

const Scratch = struct {
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

    fn deinit(self: *Scratch, alloc: std.mem.Allocator) void {
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
    }
};

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

fn isMark(cp: u21) bool {
    return cp >= 0x0300 and bidi.class(cp) == .NSM;
}

fn advanceUnits(f: *const ttf.Font, gid: u16) i32 {
    const a = f.advanceUnits(gid);
    return if (a < 1e6) @intFromFloat(a) else 0;
}

/// Lay out one line: decode (lossily), resolve bidi levels, shape runs of
/// complex scripts with the font's GSUB/GPOS (or Arabic presentation forms
/// when the font has none), reorder to visual order, mirror brackets in
/// RTL runs, and position every glyph. `dir` sets the paragraph direction
/// (.auto: from the first strong character). The result lives in the
/// state's scratch until the next call. Null when memory runs out.
fn layout(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) ?[]Item {
    return layoutInner(st, size_px, style, s, dir) catch null;
}

fn layoutInner(st: *State, size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) ![]Item {
    const a = st.alloc;
    const sc = &st.scratch;
    sc.cps.clearRetainingCapacity();
    sc.starts.clearRetainingCapacity();
    var it = utf8.Iterator.init(s);
    var has_rtl = dir == .rtl;
    var has_complex = false;
    var has_arabic = false;
    var pos: usize = 0;
    while (it.next()) |cp| {
        try sc.cps.append(a, cp);
        try sc.starts.append(a, @intCast(pos));
        pos = it.i;
        if (cp >= 0x0590) {
            has_rtl = has_rtl or bidi.isRtl(cp);
            if (scriptOf(cp)) |scr| {
                has_complex = true;
                has_arabic = has_arabic or scr != .hebr;
            }
        }
    }
    const n = sc.cps.items.len;
    const cps = sc.cps.items;
    try sc.levels.resize(a, n);
    const levels = sc.levels.items;
    if (has_rtl) {
        try sc.types.resize(a, n);
        bidi.resolveLevels(cps, bidi.paragraphLevel(cps, dir), sc.types.items, levels);
    } else @memset(levels, 0);

    // characters as drawn: mirrored at odd levels; the presentation-form
    // copy is only used where a font cannot shape Arabic itself
    try sc.shaped.resize(a, n);
    const drawn = sc.shaped.items;
    for (cps, levels, drawn) |cp, l, *d| d.* = if (l % 2 == 1) bidi.mirror(cp) else cp;
    try sc.masks.resize(a, n);
    const masks = sc.masks.items;
    if (has_arabic) bidi.joiningMasks(cps, masks) else @memset(masks, 0);

    // font per character
    try sc.slots.resize(a, n);
    const slots = sc.slots.items;
    for (drawn, slots, 0..) |cp, *sl, i| {
        if (invisible(cp)) {
            sl.* = no_font;
            continue;
        }
        sl.* = st.resolve(style, cp)[0];
        // a combining mark stays in its base's font when that has it
        if (i > 0 and isMark(cp) and slots[i - 1] != no_font and slots[i - 1] != sl.* and
            st.slots[slots[i - 1]].font.hasGlyph(cp)) sl.* = slots[i - 1];
    }
    if (has_complex) unifyScriptRuns(st, style, cps, slots);

    _ = st.styleSlot(style);
    const smear: f64 = if (style == .bold and st.faux_bold) @floatFromInt(fauxBoldOffset(size_px)) else 0;
    sc.lg.clearRetainingCapacity();
    try sc.lg.ensureTotalCapacity(a, n);
    var arabic_forms = false;
    var i: usize = 0;
    while (i < n) {
        const scr = runScript(cps, i);
        var j = i + 1;
        while (j < n and slots[j] == slots[i] and levels[j] == levels[i] and
            std.meta.eql(runScript(cps, j), scr) and !invisible(drawn[j])) j += 1;
        if (scr != null and slots[i] != no_font and try shapeRun(st, size_px, smear, i, j, scr.?)) {
            i = j;
            continue;
        }
        // one glyph per character (Latin and everything simple; Arabic
        // with a font lacking GSUB goes through presentation forms)
        const forms = scr != null and scr.? != .hebr;
        if (forms and !arabic_forms) {
            arabic_forms = true;
            try sc.pforms.resize(a, n);
            @memcpy(sc.pforms.items, drawn);
            bidi.shapeArabic(sc.pforms.items);
        }
        for (i..j) |k| {
            const cp = if (forms) sc.pforms.items[k] else drawn[k];
            var g: LGlyph = .{ .cp = cp, .c0 = @intCast(k), .c1 = @intCast(k + 1), .level = levels[k], .slot = no_font, .gid = 0, .adv = 0 };
            if (!invisible(cp)) {
                if (cp == drawn[k] and slots[k] != no_font) {
                    g.slot = slots[k];
                    g.gid = st.slots[g.slot].font.glyphIndex(cp);
                }
                if (g.gid == 0) g.slot, g.gid = st.resolve(style, cp);
                if (st.slots[g.slot].font.rasterize(g.gid, size_px)) |gl| {
                    g.adv = gl.advance + smear;
                } else |_| {}
            }
            sc.lg.appendAssumeCapacity(g);
        }
        i = j;
    }

    // visual order of the glyphs
    const lg = sc.lg.items;
    const m = lg.len;
    try sc.glevels.resize(a, m);
    try sc.order.resize(a, m);
    for (lg, sc.glevels.items) |g, *l| l.* = g.level;
    const order = sc.order.items;
    if (has_rtl) bidi.reorder(sc.glevels.items, order) else for (order, 0..) |*o, k| {
        o.* = @intCast(k);
    }
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
    sc.width = x;
    sc.items.clearRetainingCapacity();
    try sc.items.ensureTotalCapacity(a, m);
    for (order) |li| {
        const g = lg[li];
        sc.items.appendAssumeCapacity(.{
            .cp = g.cp,
            .start = sc.starts.items[g.c0],
            .end = if (g.c1 < n) sc.starts.items[g.c1] else @intCast(s.len),
            .rtl = g.level % 2 == 1,
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
        const first = slots[i];
        const same = for (slots[i..j]) |sl| {
            if (sl != first and sl != no_font) break false;
        } else true;
        if (same) continue;
        var cands: [8]u8 = undefined;
        var nc: usize = 0;
        cands[0] = st.styleSlot(style);
        nc = 1;
        for (slots[i..j]) |sl| {
            if (sl == no_font or std.mem.indexOfScalar(u8, cands[0..nc], sl) != null) continue;
            if (nc == cands.len) break;
            cands[nc] = sl;
            nc += 1;
        }
        for (cands[0..nc]) |cand| {
            const f = &st.slots[cand].font;
            const covers = for (cps[i..j], slots[i..j]) |cp, sl| {
                if (sl != no_font and !f.hasGlyph(cp)) break false;
            } else true;
            if (!covers) continue;
            for (slots[i..j]) |*sl| {
                if (sl.* != no_font) sl.* = cand;
            }
            break;
        }
    }
}

/// Shape characters [i, j) (one font, level and script) with the font's
/// layout tables and append the glyphs. False when the font has no GSUB
/// for the script (the caller falls back to presentation forms).
fn shapeRun(st: *State, size_px: f64, smear: f64, i: usize, j: usize, scr: otl.Script) !bool {
    const a = st.alloc;
    const sc = &st.scratch;
    const slot = sc.slots.items[i];
    const font = &st.slots[slot].font;
    const level = sc.levels.items[i];
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
    if (!try otl.shape(a, font.layout, scr, level % 2 == 1, &sc.run, font, advanceUnits)) return false;
    const run = sc.run.items;
    // a mark joins the cluster of the glyph it follows: carets and line
    // breaks never fall between a letter and its marks
    for (run[1..], 1..) |*g, k| {
        if (isMark(sc.cps.items[g.cl0]) and g.cl0 > run[k - 1].cl0) g.cl0 = run[k - 1].cl0;
    }
    var k = run.len;
    while (k > 1) {
        k -= 1;
        if (run[k].cl0 == run[k - 1].cl0) run[k - 1].cl1 = @max(run[k - 1].cl1, run[k].cl1);
    }
    for (run[1..], 1..) |*g, q| {
        if (g.cl0 == run[q - 1].cl0) g.cl1 = run[q - 1].cl1;
    }
    const scale = size_px / font.units_per_em;
    const base: i32 = @intCast(sc.lg.items.len);
    try sc.lg.ensureUnusedCapacity(a, run.len);
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
    return true;
}

/// Draw text with the top-left corner at (x, y).
pub fn draw(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    drawStyled(canvas, x, y, size_px, color, .regular, s);
}

/// Draw text in a given style (bold and monospace fall back to regular,
/// bold to a synthesized bold, when the system lacks those faces).
/// Right-to-left and mixed text is shaped and drawn in visual order.
pub fn drawStyled(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8) void {
    drawDir(canvas, x, y, size_px, color, style, s, .auto);
}

/// drawStyled with an explicit paragraph direction (for a line wrapped
/// out of a longer paragraph, whose direction comes from the paragraph).
pub fn drawDir(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8, dir: bidi.Direction) void {
    const st = if (state) |*p| p else {
        canvas.text(x, y, bitmapScale(size_px), color, s);
        return;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return;
    const items = layout(st, size_px, style, s, dir) orelse return;
    const primary = st.styleSlot(style);
    const smear: i32 = if (style == .bold and st.faux_bold) fauxBoldOffset(size_px) else 0;
    const baseline = @as(f64, @floatFromInt(y)) + st.slots[primary].font.ascentPx(size_px);
    const x0: f64 = @floatFromInt(x);
    const right = @as(f64, @floatFromInt(canvas.w)) + 1024;
    for (items) |item| {
        if (item.slot == no_font) continue;
        const pen = x0 + item.gx;
        // far past the right edge: nothing more can show
        if (x0 + item.x > right) break;
        const g = st.slots[item.slot].font.rasterize(item.gid, size_px) catch continue;
        if (g.w > 0) {
            const gx = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
            const gy = @as(i32, @intFromFloat(@round(baseline + item.gy))) + g.bearing_y;
            var k: i32 = 0;
            while (k <= smear) : (k += 1) blitAlpha(canvas, gx + k, gy, g, color);
        }
    }
}

pub fn width(size_px: f64, s: []const u8) i32 {
    return widthStyled(size_px, .regular, s);
}

pub fn widthStyled(size_px: f64, style: Style, s: []const u8) i32 {
    return widthDir(size_px, style, s, .auto);
}

pub fn widthDir(size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) i32 {
    const st = if (state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    _ = layout(st, size_px, style, s, dir) orelse return 0;
    const total = st.scratch.width;
    if (!(total < 1e9)) return std.math.maxInt(i32) / 2;
    return @intFromFloat(@ceil(total));
}

/// The run of items around `k` drawing the same characters (a cluster:
/// a ligature, a letter and its marks, a multi-glyph substitution), as
/// [first, last] item indices and its left and right edges.
fn clusterAt(items: []const Item, k: usize) struct { usize, usize, f64, f64 } {
    var lo = k;
    var hi = k;
    const same = struct {
        fn f(p: Item, q: Item) bool {
            return p.start == q.start and p.end == q.end;
        }
    }.f;
    while (lo > 0 and same(items[lo - 1], items[k])) lo -= 1;
    while (hi + 1 < items.len and same(items[hi + 1], items[k])) hi += 1;
    var x0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    for (items[lo .. hi + 1]) |it| {
        if (it.adv <= 0) continue;
        x0 = @min(x0, it.x);
        x1 = @max(x1, it.x + it.adv);
    }
    if (x0 > x1) {
        x0 = items[k].x;
        x1 = x0;
    }
    return .{ lo, hi, x0, x1 };
}

/// Caret stops inside a cluster's characters: byte offsets in (start, end)
/// that do not split a letter from its marks; at most `out.len`.
fn innerStops(s: []const u8, start: usize, end: usize, out: []usize) usize {
    var n: usize = 0;
    var it = utf8.Iterator.init(s[0..end]);
    it.i = start;
    _ = it.next();
    while (it.i < end) {
        const at = it.i;
        const cp = it.next() orelse break;
        if (isMark(cp)) continue;
        if (n == out.len) break;
        out[n] = at;
        n += 1;
    }
    return n;
}

/// Byte offset in `s` of the caret position closest to `x` pixels from
/// the left edge of the drawn text. Works in visual order, so clicks on
/// right-to-left text land on the right logical character.
pub fn offsetForX(size_px: f64, style: Style, s: []const u8, x: i32) usize {
    return offsetForXDir(size_px, style, s, x, .auto);
}

pub fn offsetForXDir(size_px: f64, style: Style, s: []const u8, x: i32, dir: bidi.Direction) usize {
    const st = if (state) |*p| p else return bitmapOffsetForX(size_px, s, x);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s, dir) orelse return 0;
    if (items.len == 0) return 0;
    const fx: f64 = @floatFromInt(x);
    // before the first / past the last glyph: the visual line ends
    const first = items[0];
    if (fx <= first.x) return if (first.rtl) first.end else first.start;
    var last_vis: ?Item = null;
    for (items, 0..) |item, k| {
        if (item.adv <= 0) continue;
        last_vis = item;
        if (fx < item.x + item.adv) {
            _, _, const c0, const c1 = clusterAt(items, k);
            // a cluster of several characters (ligature): split it evenly
            var stops: [32]usize = undefined;
            const ns = innerStops(s, item.start, item.end, &stops);
            const w = @max(1e-9, c1 - c0);
            var t = std.math.clamp((fx - c0) / w, 0.0, 1.0);
            if (item.rtl) t = 1 - t;
            const idx: usize = @intFromFloat(@round(t * @as(f64, @floatFromInt(ns + 1))));
            if (idx == 0) return item.start;
            if (idx > ns) return item.end;
            return stops[idx - 1];
        }
    }
    const last = last_vis orelse items[items.len - 1];
    return if (last.rtl) last.start else last.end;
}

/// Pixel x (from the left edge of the drawn text) of the caret placed
/// before the character at byte offset `offset` (or after the last one
/// when `offset == s.len`), in visual order.
pub fn xForOffset(size_px: f64, style: Style, s: []const u8, offset: usize) i32 {
    return xForOffsetDir(size_px, style, s, offset, .auto);
}

pub fn xForOffsetDir(size_px: f64, style: Style, s: []const u8, offset: usize, dir: bidi.Direction) i32 {
    const st = if (state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s[0..@min(offset, s.len)]);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s, dir) orelse return 0;
    if (items.len == 0) return 0;
    var x: f64 = 0;
    if (offset >= s.len) {
        // trailing edge of the logically last character
        var found: ?usize = null;
        for (items, 0..) |item, k| {
            if (item.end == s.len and (found == null or item.adv > 0)) found = k;
        }
        if (found) |k| {
            _, _, const c0, const c1 = clusterAt(items, k);
            x = if (items[k].rtl) c0 else c1;
        } else if (dir == .rtl) x = 0 else x = st.scratch.width;
    } else {
        var found: ?usize = null;
        for (items, 0..) |item, k| {
            if (offset >= item.start and offset < item.end) {
                if (found == null) found = k;
                if (item.adv > 0) {
                    found = k;
                    break;
                }
            }
        }
        if (found) |k| {
            const item = items[k];
            _, _, const c0, const c1 = clusterAt(items, k);
            var t: f64 = 0;
            if (offset > item.start) {
                // inside a ligature: proportional to the caret stop
                var stops: [32]usize = undefined;
                const ns = innerStops(s, item.start, item.end, &stops);
                const idx = for (stops[0..ns], 0..) |p, q| {
                    if (p >= offset) break q + 1;
                } else ns;
                t = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(ns + 1));
            }
            x = if (item.rtl) c1 - t * (c1 - c0) else c0 + t * (c1 - c0);
        }
    }
    return @intFromFloat(@round(x));
}

pub const Line = wrap_mod.Line;

fn measureFor(ctx: struct { f64, Style }, s: []const u8) f64 {
    return @floatFromInt(widthStyled(ctx[0], ctx[1], s));
}

const WrapKey = struct { hash: u64, len: usize, size: u64, style: Style, max_w: i32 };
const WrapEntry = struct { key: WrapKey, lines: []Line };
var wrap_cache: [8]?WrapEntry = @splat(null);
var wrap_next: usize = 0;
var wrap_alloc: ?std.mem.Allocator = null;

fn clearWrapCache() void {
    const a = wrap_alloc orelse return;
    for (&wrap_cache) |*e| {
        if (e.*) |x| a.free(x.lines);
        e.* = null;
    }
}

/// Visual lines of paragraph `s` (no newlines) in a box `max_w` pixels
/// wide: breaks after spaces and hyphens and around CJK, long words cut
/// between graphemes (see wrap.zig). Appended to `out`. Recent results are
/// cached, since boxes are laid out on every frame.
pub fn wrapLines(alloc: std.mem.Allocator, size_px: f64, style: Style, s: []const u8, max_w: i32, out: *std.ArrayList(Line)) !void {
    const key: WrapKey = .{ .hash = std.hash.Wyhash.hash(0, s), .len = s.len, .size = @bitCast(size_px), .style = style, .max_w = max_w };
    const cacheable = state != null;
    if (cacheable) {
        for (wrap_cache) |e| {
            const x = e orelse continue;
            if (std.meta.eql(x.key, key)) return out.appendSlice(alloc, x.lines);
        }
    }
    const first = out.items.len;
    try wrap_mod.wrap(alloc, s, @floatFromInt(max_w), .{ size_px, style }, measureFor, out);
    if (!cacheable) return;
    const st_alloc = state.?.alloc;
    const copy = st_alloc.dupe(Line, out.items[first..]) catch return;
    wrap_alloc = st_alloc;
    if (wrap_cache[wrap_next]) |old| st_alloc.free(old.lines);
    wrap_cache[wrap_next] = .{ .key = key, .lines = copy };
    wrap_next = (wrap_next + 1) % wrap_cache.len;
}

/// Where the characters in byte range [a, b) of line `s` are drawn: up to
/// `out.len` horizontal spans [x0, x1) from the line's left edge, in
/// visual order, adjacent glyphs merged. Mixed-direction text gives
/// several spans. A ligature partly inside the range counts as inside.
pub fn rangeSpans(size_px: f64, style: Style, s: []const u8, a: usize, b: usize, dir: bidi.Direction, out: [][2]i32) usize {
    if (a >= b or out.len == 0) return 0;
    const st = if (state) |*p| p else {
        const sc = bitmapScale(size_px);
        out[0] = .{ Canvas.textWidth(sc, s[0..@min(a, s.len)]), Canvas.textWidth(sc, s[0..@min(b, s.len)]) };
        return 1;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s, dir) orelse return 0;
    var n: usize = 0;
    var cur: ?[2]f64 = null;
    for (items) |it| {
        if (it.adv <= 0) continue;
        const inside = it.start < b and it.end > a;
        if (inside) {
            if (cur) |*c| {
                if (@abs(it.x - c[1]) < 0.5) {
                    c[1] = it.x + it.adv;
                    continue;
                }
            }
        }
        if (cur) |c| {
            if (n == out.len) return n;
            out[n] = .{ @intFromFloat(@round(c[0])), @intFromFloat(@round(c[1])) };
            n += 1;
            cur = null;
        }
        if (inside) cur = .{ it.x, it.x + it.adv };
    }
    if (cur) |c| if (n < out.len) {
        out[n] = .{ @intFromFloat(@round(c[0])), @intFromFloat(@round(c[1])) };
        n += 1;
    };
    return n;
}

fn bitmapOffsetForX(size_px: f64, s: []const u8, x: i32) usize {
    const cell = Canvas.textWidth(bitmapScale(size_px), "x");
    var it = utf8.Iterator.init(s);
    var pos: i32 = 0;
    var prev: usize = 0;
    while (it.next()) |_| {
        if (x < pos + @divTrunc(cell, 2)) return prev;
        pos += cell;
        prev = it.i;
    }
    return s.len;
}

pub fn height(size_px: f64) i32 {
    return heightStyled(size_px, .regular);
}

pub fn heightStyled(size_px: f64, style: Style) i32 {
    const st = if (state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const h = st.slots[st.styleSlot(style)].font.lineHeightPx(size_px);
    if (!(h >= 0 and h < 1e6)) return 0;
    return @intFromFloat(@ceil(h));
}

/// Distance from the top of a line to its baseline.
pub fn ascent(size_px: f64) i32 {
    const st = if (state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const a = st.slots[st.regular].font.ascentPx(size_px);
    if (!(a >= 0 and a < 1e6)) return 0;
    return @intFromFloat(@round(a));
}

fn bitmapScale(size_px: f64) i32 {
    if (!(size_px > 0)) return 1;
    return @intFromFloat(@max(1.0, @min(256.0, @round(size_px / 8.0))));
}

/// Blend glyph coverage onto the canvas, clipped to the canvas once up
/// front instead of per pixel.
fn blitAlpha(canvas: *Canvas, x0: i32, y0: i32, g: *const ttf.Glyph, color: u32) void {
    const base_a: u32 = color >> 24;
    const gx0 = @max(0, 0 -| x0);
    const gy0 = @max(0, 0 -| y0);
    const gx1 = @min(g.w, canvas.w -| x0);
    const gy1 = @min(g.h, canvas.h -| y0);
    if (gx0 >= gx1 or gy0 >= gy1) return;
    const rgb = color & 0x00FFFFFF;
    var gy = gy0;
    while (gy < gy1) : (gy += 1) {
        const src = g.alpha[@intCast(gy * g.w)..][0..@intCast(g.w)];
        const row: usize = @intCast((y0 + gy) * canvas.w + x0);
        var gx = gx0;
        while (gx < gx1) : (gx += 1) {
            const cov: u32 = src[@intCast(gx)];
            if (cov == 0) continue;
            const a = (base_a * cov + 127) / 255;
            const di = row + @as(usize, @intCast(gx));
            canvas.px[di] = Canvas.blendPixel(canvas.px[di], rgb | (a << 24));
        }
    }
}

test "text survives invalid utf-8 and odd sizes" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();
    var px: [64 * 32]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 64, 32);
    const bad = "save\xE2\x82 dir \xFF\xC3";
    draw(&c, 2, 2, 14, 0xFFFFFFFF, bad);
    _ = width(14, bad);
    for ([_]Style{ .regular, .bold, .mono }) |st| {
        drawStyled(&c, -30, -10, 40, 0xFFFFFFFF, st, "Wg漢€");
        drawStyled(&c, 60, 30, 13, 0xFFFFFFFF, st, "edge");
        _ = widthStyled(13, st, "x");
        _ = heightStyled(13, st);
    }
    for ([_]f64{ 0, -5, std.math.nan(f64), std.math.inf(f64), 1e12 }) |sz| {
        draw(&c, 0, 0, sz, 0xFFFFFFFF, "abc");
        _ = width(sz, "abc");
        _ = height(sz);
    }
    try std.testing.expectEqual(@as(usize, 0), offsetForX(14, .regular, "abc", -5));
    try std.testing.expectEqual(@as(usize, 3), offsetForX(14, .regular, "abc", 1000));
}

test "fallback chain covers characters the UI font lacks" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();
    const st = if (state) |*p| p else return; // no fonts installed
    const kanji: u21 = 0x6F22;
    if (st.slots[st.regular].font.hasGlyph(kanji)) return;
    const slot, const gid = st.resolve(.regular, kanji);
    if (slot == st.regular) return; // no CJK font on this system
    try std.testing.expect(gid != 0);
}

test "bidi layout: visual order, carets and shaping" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();
    const st = if (state) |*p| p else return;
    // Hebrew is drawn right to left
    const heb = "\u{5E9}\u{5DC}\u{5D5}\u{5DD}"; // shalom
    const items = layout(st, 16, .regular, heb, .auto).?;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqual(@as(u21, 0x5DD), items[0].cp);
    try std.testing.expect(items[0].rtl);
    const w = width(16, heb);
    // caret before the first logical letter is at the right edge
    try std.testing.expect(@abs(xForOffset(16, .regular, heb, 0) - w) <= 1);
    try std.testing.expectEqual(@as(i32, 0), xForOffset(16, .regular, heb, heb.len));
    // clicking near the right edge puts the caret at the start
    try std.testing.expectEqual(@as(usize, 0), offsetForX(16, .regular, heb, w - 1));
    try std.testing.expectEqual(heb.len, offsetForX(16, .regular, heb, 0));
    // round trip for every boundary
    var off: usize = 0;
    while (off <= heb.len) : (off += 2) {
        try std.testing.expectEqual(off, offsetForX(16, .regular, heb, xForOffset(16, .regular, heb, off)));
    }
    // LTR stays as before
    try std.testing.expectEqual(@as(usize, 0), offsetForX(16, .regular, "abc", -5));
    try std.testing.expectEqual(@as(usize, 3), offsetForX(16, .regular, "abc", 1000));
    try std.testing.expectEqual(@as(i32, 0), xForOffset(16, .regular, "abc", 0));
    try std.testing.expect(@abs(width(16, "abc") - xForOffset(16, .regular, "abc", 3)) <= 1);
    // Arabic is shaped: salaam -> 3 visible glyphs (lam-alef ligature)
    const ar = "\u{633}\u{644}\u{627}\u{645}";
    const ai = layout(st, 16, .regular, ar, .auto).?;
    var visible: usize = 0;
    for (ai) |it| {
        if (it.slot != no_font) visible += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), visible);
    try std.testing.expectEqual(@as(u32, 6), ai[0].start); // meem, leftmost
    // a range across both directions highlights each part where it is
    // "bc א" in "abc אבג def": the Hebrew letter is drawn apart from "bc "
    const mixed = "abc \u{5D0}\u{5D1}\u{5D2} def";
    var spans: [4][2]i32 = undefined;
    const ns = rangeSpans(16, .regular, mixed, 1, 6, .ltr, &spans);
    try std.testing.expectEqual(@as(usize, 2), ns);
    var covered: i32 = 0;
    for (spans[0..ns]) |sp| covered += sp[1] - sp[0];
    try std.testing.expect(@abs(covered - width(16, "bc ") - width(16, "\u{5D0}")) <= 2);
    // mixed text with numbers and invalid bytes never crashes
    var px: [64 * 32]u32 = @splat(0);
    var c = Canvas.init(&px, 64, 32);
    draw(&c, 0, 0, 14, 0xFFFFFFFF, "abc \u{5D0}\u{5D1} 123 (\u{627}\u{644}) \xFF\xC3");
    _ = offsetForX(14, .bold, "\u{5D0}1(2)\u{5D1}", 7);
    _ = xForOffset(14, .mono, "\u{5D0}1(2)\u{5D1}", 3);
}

/// Drawn bounding box (left, top, right, bottom) of item `it` relative to
/// the line origin and baseline.
fn testBox(st: *State, it: Item, size: f64) [4]f64 {
    const g = st.slots[it.slot].font.rasterize(it.gid, size) catch unreachable;
    const l = it.gx + @as(f64, @floatFromInt(g.bearing_x));
    const t = it.gy + @as(f64, @floatFromInt(g.bearing_y));
    return .{ l, t, l + @as(f64, @floatFromInt(g.w)), t + @as(f64, @floatFromInt(g.h)) };
}

test "complex scripts are shaped with the font: joining, ligatures, marks" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();
    const st = if (state) |*p| p else return;
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

test {
    _ = @import("wrap.zig");
    _ = @import("bidi.zig");
    _ = @import("otl.zig");
    _ = @import("ttf.zig");
    _ = @import("fontdb.zig");
    _ = @import("utf8.zig");
}
