//! A loaded font face: table slices, glyph lookup, metrics, and a cache
//! of rasterized glyphs.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const cff_mod = @import("../cff.zig");
const otl = @import("../otl.zig");
const bytes = @import("bytes.zig");
const sfnt = @import("sfnt.zig");
const cmap_table = @import("cmap.zig");
const glyf_table = @import("glyf.zig");
const raster = @import("raster.zig");
const mmap = @import("mmap.zig");
const Path = @import("path.zig").Path;
const beU16 = bytes.beU16;
const beI16 = bytes.beI16;

pub const LoadError = error{
    Truncated,
    NotTrueType,
    MissingTables,
    NoUsableCmap,
    BadFont,
    OutOfMemory,
};

pub const Glyph = struct {
    /// 8-bit coverage, w*h
    alpha: []u8,
    w: i32,
    h: i32,
    /// offset from pen position (x) and from baseline (y, downward)
    bearing_x: i32,
    bearing_y: i32,
    advance: f64,
};

const CacheKey = struct {
    gid: u16,
    size10: u32, // size in tenths of a pixel
};

/// Largest size we rasterize at; larger (or NaN/negative) sizes draw nothing.
pub const max_size_px = 1024.0;
const max_components = 256;

const empty_glyph: Glyph = .{ .alpha = &.{}, .w = 0, .h = 0, .bearing_x = 0, .bearing_y = 0, .advance = 0 };

const Storage = enum { heap, mapped, borrowed };

pub const Font = struct {
    alloc: std.mem.Allocator,
    data: []const u8,
    storage: Storage = .heap,
    // table slices
    glyf: []const u8 = &.{},
    loca: []const u8 = &.{},
    cmap4: []const u8 = &.{}, // format-4 subtable
    cmap12: []const u8 = &.{}, // format-12 subtable (preferred: covers > U+FFFF)
    hmtx: []const u8,
    cff: ?cff_mod.Cff = null,
    /// GSUB/GPOS/GDEF, for shaping (otl.zig)
    layout: otl.Tables = .{},
    num_h_metrics: u16,
    num_glyphs: u16,
    units_per_em: f64,
    long_loca: bool = false,
    ascent: f64, // font units
    descent: f64, // font units, negative

    cache: std.AutoHashMap(CacheKey, Glyph),

    /// Load the first face of a font file.
    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Font {
        return loadFace(alloc, path, 0);
    }

    /// Load face `index` of a font file (.ttf, .otf or .ttc). The file is
    /// memory-mapped, so large CJK collections cost address space only.
    pub fn loadFace(alloc: std.mem.Allocator, path: []const u8, index: u32) !Font {
        if (mmap.mapFile(path)) |m| {
            var f = parse(alloc, m, index) catch |e| {
                mmap.unmap(m);
                return e;
            };
            f.storage = .mapped;
            return f;
        } else |_| {}
        const data = try sys.readFileAlloc(alloc, path, 64 * 1024 * 1024);
        errdefer alloc.free(data);
        var f = try parse(alloc, data, index);
        f.storage = .heap;
        return f;
    }

    /// Parse font bytes without taking ownership (caller keeps `data` alive
    /// and frees it after deinit).
    pub fn parse(alloc: std.mem.Allocator, data: []const u8, index: u32) LoadError!Font {
        const dir = try sfnt.directoryOffset(data, index);
        const t = try sfnt.readTables(data, dir);
        if (t.head.len < 54 or t.maxp.len < 6 or t.cmap.len < 4 or t.hhea.len < 36) return error.MissingTables;
        const cff = try loadCff(t);

        const upem = try beU16(t.head, 18);
        if (upem < 16 or upem > 16384) return error.BadFont;

        var font: Font = .{
            .alloc = alloc,
            .data = data,
            .storage = .borrowed,
            .glyf = t.glyf,
            .loca = t.loca,
            .hmtx = t.hmtx,
            .cff = cff,
            .layout = t.layout,
            .num_h_metrics = try beU16(t.hhea, 34),
            .num_glyphs = try beU16(t.maxp, 4),
            .units_per_em = @floatFromInt(upem),
            .long_loca = (try beI16(t.head, 50)) != 0,
            .ascent = @floatFromInt(try beI16(t.hhea, 4)),
            .descent = @floatFromInt(try beI16(t.hhea, 6)),
            .cache = undefined,
        };
        font.sanitizeVerticalMetrics();
        const cmaps = try cmap_table.pick(t.cmap);
        font.cmap4 = cmaps.cmap4;
        font.cmap12 = cmaps.cmap12;
        font.cache = std.AutoHashMap(CacheKey, Glyph).init(alloc);
        return font;
    }

    /// CFF outlines, when the face has no glyf/loca.
    fn loadCff(t: sfnt.Tables) LoadError!?cff_mod.Cff {
        if (t.glyf.len != 0 and t.loca.len != 0) return null;
        if (t.cff.len == 0) return error.MissingTables; // bitmap-only or CFF2
        return cff_mod.Cff.parse(t.cff) catch return error.BadFont;
    }

    /// Replace implausible hhea ascent/descent with 0.8/-0.2 em.
    fn sanitizeVerticalMetrics(font: *Font) void {
        if (font.ascent <= 0 or font.descent > 0 or font.ascent - font.descent > 4 * font.units_per_em) {
            font.ascent = font.units_per_em * 0.8;
            font.descent = -font.units_per_em * 0.2;
        }
    }

    pub fn deinit(self: *Font) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.alloc.free(g.alpha);
        self.cache.deinit();
        switch (self.storage) {
            .heap => self.alloc.free(self.data),
            .mapped => mmap.unmap(self.data),
            .borrowed => {},
        }
    }

    /// Whether the font maps `cp` to a real glyph.
    pub fn hasGlyph(self: *const Font, cp: u21) bool {
        return self.glyphIndex(cp) != 0;
    }

    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        const gid = if (self.cmap12.len > 0) cmap_table.lookup12(self.cmap12, cp) else cmap_table.lookup4(self.cmap4, cp);
        return if (gid < self.num_glyphs) gid else 0;
    }

    /// Advance width of glyph `gid` in font units.
    pub fn advanceUnits(self: *const Font, gid: u16) f64 {
        const n = self.num_h_metrics;
        if (n == 0) return 0;
        const idx = @min(gid, n - 1);
        return @floatFromInt(beU16(self.hmtx, @as(usize, idx) * 4) catch 0);
    }

    pub fn rasterize(self: *Font, gid: u16, size_px: f64) !*const Glyph {
        if (!(size_px > 0 and size_px <= max_size_px)) return &empty_glyph;
        const key = CacheKey{ .gid = gid, .size10 = @intFromFloat(@round(size_px * 10.0)) };
        if (self.cache.getPtr(key)) |g| return g;

        const scale = size_px / self.units_per_em;
        var edges: std.ArrayList([4]f64) = .empty;
        defer edges.deinit(self.alloc);
        try self.outlineEdges(gid, scale, &edges);

        var glyph = Glyph{
            .alpha = &.{},
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance = self.advanceUnits(gid) * scale,
        };
        if (try raster.render(self.alloc, edges.items, 4 * max_size_px)) |b| {
            glyph.alpha = b.alpha;
            glyph.w = b.w;
            glyph.h = b.h;
            glyph.bearing_x = b.bearing_x;
            glyph.bearing_y = b.bearing_y;
        }

        self.cache.put(key, glyph) catch |e| {
            self.alloc.free(glyph.alpha);
            return e;
        };
        return self.cache.getPtr(key).?;
    }

    /// Flatten glyph `gid` at `scale` into pixel-space edges; a malformed
    /// glyph leaves `edges` empty.
    fn outlineEdges(self: *const Font, gid: u16, scale: f64, edges: *std.ArrayList([4]f64)) !void {
        // y axis flipped (font units are y-up)
        var path: Path = .{ .alloc = self.alloc, .edges = edges, .m = .{ scale, 0, 0, -scale, 0, 0 } };
        const res = if (self.cff) |*c|
            c.outline(gid, &path)
        else blk: {
            var budget: u32 = max_components;
            break :blk self.glyfTable().outline(gid, path.m, 0, &budget, &path);
        };
        res catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => edges.clearRetainingCapacity(), // malformed: draw nothing
        };
    }

    fn glyfTable(self: *const Font) glyf_table.Glyf {
        return .{
            .alloc = self.alloc,
            .glyf = self.glyf,
            .loca = self.loca,
            .long_loca = self.long_loca,
            .num_glyphs = self.num_glyphs,
        };
    }

    pub fn ascentPx(self: *const Font, size_px: f64) f64 {
        return self.ascent * (size_px / self.units_per_em);
    }
    pub fn descentPx(self: *const Font, size_px: f64) f64 {
        return -self.descent * (size_px / self.units_per_em);
    }
    pub fn lineHeightPx(self: *const Font, size_px: f64) f64 {
        return (self.ascent - self.descent) * (size_px / self.units_per_em);
    }
};

test "load system font and rasterize" {
    const alloc = std.testing.allocator;
    var font = Font.load(alloc, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") catch return; // skip if absent
    defer font.deinit();
    const gid = font.glyphIndex('A');
    try std.testing.expect(gid != 0);
    const g = try font.rasterize(gid, 16.0);
    try std.testing.expect(g.w > 4 and g.h > 8);
    // coverage present
    var sum: usize = 0;
    for (g.alpha) |a| sum += a;
    try std.testing.expect(sum > 1000);
    // composite glyph (accented letter) also rasterizes
    const ae = try font.rasterize(font.glyphIndex(0xE9), 16.0);
    try std.testing.expect(ae.w > 3);
    // absurd sizes are rejected without crashing
    try std.testing.expectEqual(@as(i32, 0), (try font.rasterize(gid, -1)).w);
    try std.testing.expectEqual(@as(i32, 0), (try font.rasterize(gid, std.math.inf(f64))).w);
    try std.testing.expectEqual(@as(i32, 0), (try font.rasterize(gid, std.math.nan(f64))).w);
}

test "cff collection: CJK glyph from a .ttc" {
    const alloc = std.testing.allocator;
    const path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
    var font = Font.loadFace(alloc, path, 0) catch return; // skip if absent
    defer font.deinit();
    try std.testing.expect(font.cff != null);
    const gid = font.glyphIndex(0x6F22); // 漢
    try std.testing.expect(gid != 0);
    const g = try font.rasterize(gid, 32.0);
    try std.testing.expect(g.w > 20 and g.h > 20);
    var sum: usize = 0;
    for (g.alpha) |a| sum += a;
    try std.testing.expect(sum > 255 * 60);
    // a supplementary-plane character via cmap format 12
    try std.testing.expect(font.glyphIndex(0x20B9F) != 0); // 𠮟
}

test "otf with cff outlines" {
    const alloc = std.testing.allocator;
    var font = Font.load(alloc, "/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf") catch return;
    defer font.deinit();
    const g = try font.rasterize(font.glyphIndex('B'), 24.0);
    try std.testing.expect(g.w > 8 and g.h > 12);
}
