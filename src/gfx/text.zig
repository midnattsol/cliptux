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

    fn deinit(self: *State) void {
        for (self.slots[0..self.n]) |*s| {
            s.font.deinit();
            self.alloc.free(s.path);
        }
        for (self.failed[0..self.n_failed]) |p| self.alloc.free(p);
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

/// Draw text with the top-left corner at (x, y).
pub fn draw(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    drawStyled(canvas, x, y, size_px, color, .regular, s);
}

/// Draw text in a given style (bold and monospace fall back to regular,
/// bold to a synthesized bold, when the system lacks those faces).
pub fn drawStyled(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, style: Style, s: []const u8) void {
    const st = if (state) |*p| p else {
        canvas.text(x, y, bitmapScale(size_px), color, s);
        return;
    };
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return;
    const primary = st.styleSlot(style);
    const faux = style == .bold and st.faux_bold;
    const smear: i32 = if (faux) fauxBoldOffset(size_px) else 0;
    const baseline = @as(f64, @floatFromInt(y)) + st.slots[primary].font.ascentPx(size_px);
    var pen: f64 = @floatFromInt(x);
    var it = utf8.Iterator.init(s);
    while (it.next()) |cp| {
        if (invisible(cp)) continue;
        // far past the right edge: nothing more can show
        if (pen > @as(f64, @floatFromInt(canvas.w)) + 1024) break;
        const slot, const gid = st.resolve(style, cp);
        const g = st.slots[slot].font.rasterize(gid, size_px) catch continue;
        if (g.w > 0) {
            const gx = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
            const gy = @as(i32, @intFromFloat(@round(baseline))) + g.bearing_y;
            var k: i32 = 0;
            while (k <= smear) : (k += 1) blitAlpha(canvas, gx + k, gy, g, color);
        }
        pen += g.advance + @as(f64, @floatFromInt(smear));
    }
}

pub fn width(size_px: f64, s: []const u8) i32 {
    return widthStyled(size_px, .regular, s);
}

pub fn widthStyled(size_px: f64, style: Style, s: []const u8) i32 {
    const st = if (state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s);
    _ = st.styleSlot(style);
    const smear: f64 = if (style == .bold and st.faux_bold) @floatFromInt(fauxBoldOffset(size_px)) else 0;
    var total: f64 = 0;
    var it = utf8.Iterator.init(s);
    while (it.next()) |cp| {
        if (invisible(cp)) continue;
        const slot, const gid = st.resolve(style, cp);
        const g = st.slots[slot].font.rasterize(gid, size_px) catch continue;
        total += g.advance + smear;
    }
    if (!(total < 1e9)) return std.math.maxInt(i32) / 2;
    return @intFromFloat(@ceil(total));
}

/// Byte offset in `s` of the character boundary closest to `x` pixels from
/// the start of the text (for caret placement).
pub fn offsetForX(size_px: f64, style: Style, s: []const u8, x: i32) usize {
    var it = utf8.Iterator.init(s);
    var prev_end: usize = 0;
    var prev_w: i32 = 0;
    while (it.next()) |_| {
        const w = widthStyled(size_px, style, s[0..it.i]);
        if (w >= x) return if (x - prev_w < w - x) prev_end else it.i;
        prev_end = it.i;
        prev_w = w;
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

test {
    _ = @import("ttf.zig");
    _ = @import("fontdb.zig");
    _ = @import("utf8.zig");
}
