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
    if (state != null) return;
    var st: State = .{ .alloc = alloc, .db = fontdb.Db.init(alloc) };
    st.regular = st.loadQuery(.sans);
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
    if (state) |*st| st.deinit();
    state = null;
}

pub fn available() bool {
    return state != null;
}

/// Zero-width codepoints that should neither draw nor advance.
fn invisible(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF or cp == 0x2060;
}

fn fauxBoldOffset(size_px: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(size_px / 24.0))));
}

/// One glyph of a laid-out line, in visual (left-to-right) order.
pub const Item = struct {
    /// codepoint drawn (after Arabic shaping and mirroring)
    cp: u21,
    /// byte range of the logical character(s) in the source string
    start: u32,
    end: u32,
    /// part of a right-to-left run (its leading edge is on the right)
    rtl: bool,
    slot: u8,
    gid: u16,
    /// left edge relative to the start of the line, and advance
    x: f64,
    adv: f64,
};

const Scratch = struct {
    cps: std.ArrayList(u21) = .empty,
    starts: std.ArrayList(u32) = .empty,
    types: std.ArrayList(bidi.Class) = .empty,
    levels: std.ArrayList(u8) = .empty,
    order: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Item) = .empty,

    fn deinit(self: *Scratch, alloc: std.mem.Allocator) void {
        self.cps.deinit(alloc);
        self.starts.deinit(alloc);
        self.types.deinit(alloc);
        self.levels.deinit(alloc);
        self.order.deinit(alloc);
        self.items.deinit(alloc);
    }
};

/// Lay out one line: decode (lossily), shape Arabic, resolve bidi levels,
/// reorder to visual order, mirror brackets in RTL runs, and position
/// every glyph. The result lives in the state's scratch until the next
/// call. Null when memory runs out.
fn layout(st: *State, size_px: f64, style: Style, s: []const u8) ?[]Item {
    return layoutInner(st, size_px, style, s) catch null;
}

fn layoutInner(st: *State, size_px: f64, style: Style, s: []const u8) ![]Item {
    const a = st.alloc;
    const sc = &st.scratch;
    sc.cps.clearRetainingCapacity();
    sc.starts.clearRetainingCapacity();
    var it = utf8.Iterator.init(s);
    var has_rtl = false;
    var pos: usize = 0;
    while (it.next()) |cp| {
        try sc.cps.append(a, cp);
        try sc.starts.append(a, @intCast(pos));
        pos = it.i;
        has_rtl = has_rtl or bidi.isRtl(cp);
    }
    const n = sc.cps.items.len;
    const cps = sc.cps.items;
    try sc.order.resize(a, n);
    try sc.levels.resize(a, n);
    const order = sc.order.items;
    const levels = sc.levels.items;
    if (has_rtl) {
        try sc.types.resize(a, n);
        const para = bidi.paragraphLevel(cps, .auto);
        bidi.shapeArabic(cps);
        bidi.resolveLevels(cps, para, sc.types.items, levels);
        bidi.reorder(levels, order);
    } else {
        @memset(levels, 0);
        for (order, 0..) |*o, i| o.* = @intCast(i);
    }
    _ = st.styleSlot(style);
    const smear: f64 = if (style == .bold and st.faux_bold) @floatFromInt(fauxBoldOffset(size_px)) else 0;
    sc.items.clearRetainingCapacity();
    try sc.items.ensureTotalCapacity(a, n);
    var x: f64 = 0;
    for (order) |li| {
        const rtl = levels[li] % 2 == 1;
        var cp = cps[li];
        if (rtl) cp = bidi.mirror(cp);
        const start = sc.starts.items[li];
        const end: u32 = if (li + 1 < n) sc.starts.items[li + 1] else @intCast(s.len);
        var item: Item = .{ .cp = cp, .start = start, .end = end, .rtl = rtl, .slot = 0, .gid = 0, .x = x, .adv = 0 };
        if (!invisible(cp)) {
            item.slot, item.gid = st.resolve(style, cp);
            if (st.slots[item.slot].font.rasterize(item.gid, size_px)) |g| {
                item.adv = g.advance + smear;
            } else |_| {}
        } else item.slot = no_font;
        sc.items.appendAssumeCapacity(item);
        x += item.adv;
    }
    return sc.items.items;
}

/// Draw text with the top-left corner at (x, y).
pub fn draw(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    drawStyled(canvas, x, y, size_px, color, .regular, s);
}

/// Draw text in a given style (bold and monospace fall back to regular,
/// bold to a synthesized bold, when the system lacks those faces).
/// Right-to-left and mixed text is shaped and drawn in visual order.
pub fn drawStyled(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8) void {
    const st = if (state) |*p| p else {
        canvas.text(x, y, bitmapScale(size_px), color, s);
        return;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return;
    const items = layout(st, size_px, style, s) orelse return;
    const primary = st.styleSlot(style);
    const smear: i32 = if (style == .bold and st.faux_bold) fauxBoldOffset(size_px) else 0;
    const baseline = @as(f64, @floatFromInt(y)) + st.slots[primary].font.ascentPx(size_px);
    const x0: f64 = @floatFromInt(x);
    for (items) |item| {
        if (item.slot == no_font) continue;
        const pen = x0 + item.x;
        // far past the right edge: nothing more can show
        if (pen > @as(f64, @floatFromInt(canvas.w)) + 1024) break;
        const g = st.slots[item.slot].font.rasterize(item.gid, size_px) catch continue;
        if (g.w > 0) {
            const gx = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
            const gy = @as(i32, @intFromFloat(@round(baseline))) + g.bearing_y;
            var k: i32 = 0;
            while (k <= smear) : (k += 1) blitAlpha(canvas, gx + k, gy, g, color);
        }
    }
}

pub fn width(size_px: f64, s: []const u8) i32 {
    return widthStyled(size_px, .regular, s);
}

pub fn widthStyled(size_px: f64, style: Style, s: []const u8) i32 {
    const st = if (state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s) orelse return 0;
    if (items.len == 0) return 0;
    const last = items[items.len - 1];
    const total = last.x + last.adv;
    if (!(total < 1e9)) return std.math.maxInt(i32) / 2;
    return @intFromFloat(@ceil(total));
}

/// Byte offset in `s` of the caret position closest to `x` pixels from
/// the left edge of the drawn text. Works in visual order, so clicks on
/// right-to-left text land on the right logical character.
pub fn offsetForX(size_px: f64, style: Style, s: []const u8, x: i32) usize {
    const st = if (state) |*p| p else return bitmapOffsetForX(size_px, s, x);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s) orelse return 0;
    if (items.len == 0) return 0;
    const fx: f64 = @floatFromInt(x);
    // before the first / past the last glyph: the visual line ends
    const first = items[0];
    if (fx <= first.x) return if (first.rtl) first.end else first.start;
    var last_vis: ?Item = null;
    for (items) |item| {
        if (item.adv <= 0) continue;
        last_vis = item;
        if (fx < item.x + item.adv) {
            const left_half = fx < item.x + item.adv / 2;
            return if (left_half != item.rtl) item.start else item.end;
        }
    }
    const last = last_vis orelse items[items.len - 1];
    return if (last.rtl) last.start else last.end;
}

/// Pixel x (from the left edge of the drawn text) of the caret placed
/// before the character at byte offset `offset` (or after the last one
/// when `offset == s.len`), in visual order.
pub fn xForOffset(size_px: f64, style: Style, s: []const u8, offset: usize) i32 {
    const st = if (state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s[0..@min(offset, s.len)]);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    const items = layout(st, size_px, style, s) orelse return 0;
    if (items.len == 0) return 0;
    var x: f64 = 0;
    if (offset >= s.len) {
        // trailing edge of the logically last character
        for (items) |item| {
            if (item.end == s.len) x = if (item.rtl) item.x else item.x + item.adv;
        }
    } else {
        for (items) |item| {
            if (offset >= item.start and offset < item.end) {
                x = if (item.rtl) item.x + item.adv else item.x;
                break;
            }
        }
    }
    return @intFromFloat(@round(x));
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
    const items = layout(st, 16, .regular, heb).?;
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
    const ai = layout(st, 16, .regular, ar).?;
    var visible: usize = 0;
    for (ai) |it| {
        if (it.slot != no_font) visible += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), visible);
    try std.testing.expectEqual(@as(u21, 0xFEE1), ai[0].cp); // meem, isolated, leftmost
    // mixed text with numbers and invalid bytes never crashes
    var px: [64 * 32]u32 = @splat(0);
    var c = Canvas.init(&px, 64, 32);
    draw(&c, 0, 0, 14, 0xFFFFFFFF, "abc \u{5D0}\u{5D1} 123 (\u{627}\u{644}) \xFF\xC3");
    _ = offsetForX(14, .bold, "\u{5D0}1(2)\u{5D1}", 7);
    _ = xForOffset(14, .mono, "\u{5D0}1(2)\u{5D1}", 3);
}

test {
    _ = @import("bidi.zig");
    _ = @import("ttf.zig");
    _ = @import("fontdb.zig");
    _ = @import("utf8.zig");
}
