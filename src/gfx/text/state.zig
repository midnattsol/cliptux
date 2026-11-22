//! Font state: the loaded faces, the style faces (regular, medium,
//! semibold, bold, mono) and the per-codepoint fallback chain; plus the
//! process-wide instance and its lifecycle.

const std = @import("std");
const ttf = @import("../ttf.zig");
const fontdb = @import("../fontdb.zig");
const bidi = @import("../bidi.zig");
const layout = @import("layout.zig");
const wrap_lines = @import("wrap_lines.zig");
const tabular = @import("tabular.zig");

/// The faces text is drawn in. Medium and semibold are real faces when
/// the system font family has them; else medium draws regular and
/// semibold draws bold.
pub const Face = enum(u3) { regular, medium, semibold, bold, mono };

/// How text is drawn: a face, and optionally tabular figures (digits of
/// one width, for numbers that change: sizes, timers, counters).
pub const Style = packed struct(u8) {
    face: Face = .regular,
    tabular: bool = false,
    _pad: u4 = 0,

    pub const regular: Style = .{};
    pub const medium: Style = .{ .face = .medium };
    pub const semibold: Style = .{ .face = .semibold };
    pub const bold: Style = .{ .face = .bold };
    pub const mono: Style = .{ .face = .mono };

    /// This style with tabular figures.
    pub fn num(self: Style) Style {
        var s = self;
        s.tabular = true;
        return s;
    }
};

/// The faces loaded on first use (all but regular), in Face order.
const lazy_faces = [_]Face{ .medium, .semibold, .bold, .mono };

const max_fonts = 24;
const max_failed = 32;
pub const no_font: u8 = 0xFF;

const Slot = struct {
    font: ttf.Font,
    path: []u8,
    index: u32,
    /// tabular digit glyphs, worked out on first use
    digits: ?tabular.Digits = null,
};

pub const State = struct {
    alloc: std.mem.Allocator,
    db: fontdb.Db,
    slots: [max_fonts]Slot = undefined,
    n: usize = 0,
    regular: u8 = no_font,
    /// slots of the lazy faces (lazy_faces order); no_font: not loaded
    /// or missing, see styleSlot
    lazy: [lazy_faces.len]u8 = @splat(no_font),
    tried: [lazy_faces.len]bool = @splat(false),
    next_fallback: usize = 0,
    /// codepoint -> slot holding it (no_font: nothing has it)
    cp_cache: std.AutoHashMapUnmanaged(u21, u8) = .empty,
    failed: [max_failed][]u8 = undefined,
    n_failed: usize = 0,
    /// per-call layout scratch, reused
    scratch: layout.Scratch = .{},

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

    /// Slot of `face` if it is already loaded.
    fn loadedSlot(self: *const State, face: fontdb.Face) ?u8 {
        for (self.slots[0..self.n], 0..) |*s, i| {
            if (s.index == face.index and std.mem.eql(u8, s.path, face.path)) return @intCast(i);
        }
        return null;
    }

    fn knownBad(self: *const State, path: []const u8) bool {
        for (self.failed[0..self.n_failed]) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    /// Load `face` (taking ownership of its path) unless already loaded or
    /// known bad; returns its slot.
    fn add(self: *State, face: fontdb.Face) ?u8 {
        if (self.loadedSlot(face)) |i| {
            face.deinit(self.alloc);
            return i;
        }
        if (self.knownBad(face.path) or self.n >= max_fonts) {
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

    /// Slot drawing `style`; every face but regular loads on first use.
    /// A missing medium draws regular; a missing semibold draws bold; a
    /// missing bold draws a smeared regular (see `fauxBold`).
    pub fn styleSlot(self: *State, style: Style) u8 {
        return switch (style.face) {
            .regular => self.regular,
            .medium => self.lazySlot(.medium) orelse self.regular,
            .semibold => self.lazySlot(.semibold) orelse self.styleSlot(.bold),
            .bold => self.lazySlot(.bold) orelse self.regular,
            .mono => self.lazySlot(.mono) orelse self.regular,
        };
    }

    /// Whether `style` is drawn as a synthesized bold.
    pub fn fauxBold(self: *State, style: Style) bool {
        return switch (style.face) {
            .bold => self.lazySlot(.bold) == null,
            .semibold => self.lazySlot(.semibold) == null and self.lazySlot(.bold) == null,
            else => false,
        };
    }

    /// The slot of a face loaded on first use; null when the system has
    /// no such face (fontconfig answers a missing weight with the regular
    /// face: that counts as missing too).
    fn lazySlot(self: *State, face: Face) ?u8 {
        const i = std.mem.indexOfScalar(Face, &lazy_faces, face).?;
        if (!self.tried[i]) {
            self.tried[i] = true;
            const slot = self.loadQuery(switch (face) {
                .medium => .sans_medium,
                .semibold => .sans_semibold,
                .mono => .mono,
                else => .sans_bold,
            });
            self.lazy[i] = if (slot == self.regular) no_font else slot;
        }
        return if (self.lazy[i] == no_font) null else self.lazy[i];
    }

    /// The tabular digits of the font in `slot`.
    pub fn digits(self: *State, slot: u8) *const tabular.Digits {
        const s = &self.slots[slot];
        if (s.digits == null) s.digits = tabular.compute(self.alloc, &s.font);
        return &s.digits.?;
    }

    /// Slot and glyph index used to draw `cp` in `style`.
    pub fn resolve(self: *State, style: Style, cp: u21) struct { u8, u16 } {
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

    /// Any face at all as the regular one (it beats the bitmap font).
    fn loadAnyRegular(self: *State) void {
        var k: usize = 0;
        while (self.db.fallback(k)) |f| : (k += 1) {
            self.regular = self.add(f) orelse continue;
            break;
        }
        self.next_fallback = k;
    }
};

/// The loaded fonts; null: none usable, text uses the bitmap font.
pub var state: ?State = null;

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
    if (st.regular == no_font) st.loadAnyRegular();
    if (st.regular == no_font) {
        std.log.warn("no usable system font found; falling back to the bitmap font", .{});
        st.deinit();
        return;
    }
    state = st;
}

pub fn deinit() void {
    wrap_lines.clearCache();
    if (state) |*st| st.deinit();
    state = null;
}

pub fn available() bool {
    return state != null;
}

/// Horizontal smear of the synthesized bold, in pixels.
pub fn fauxBoldOffset(size_px: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(size_px / 24.0))));
}

/// Scale of the bitmap font used when no font is loaded.
pub fn bitmapScale(size_px: f64) i32 {
    if (!(size_px > 0)) return 1;
    return @intFromFloat(@max(1.0, @min(256.0, @round(size_px / 8.0))));
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

test "every face resolves to a loaded slot; medium never smears" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();
    const st = if (state) |*p| p else return; // no fonts installed
    inline for (@typeInfo(Face).@"enum".field_names) |name| {
        const style: Style = .{ .face = @field(Face, name) };
        try std.testing.expect(st.styleSlot(style) < st.n);
        try std.testing.expect(st.styleSlot(style.num()) == st.styleSlot(style));
    }
    try std.testing.expect(!st.fauxBold(.medium));
    // a missing semibold borrows bold, real or synthesized
    if (st.styleSlot(.semibold) == st.styleSlot(.bold)) try std.testing.expectEqual(st.fauxBold(.bold), st.fauxBold(.semibold));
}
