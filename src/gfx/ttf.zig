//! Minimal TrueType/OpenType font parser and rasterizer: cmap (formats 4
//! and 12), glyf (simple + composite), CFF outlines ('OTTO' fonts, via
//! cff.zig), loca, hmtx, and .ttc collections. Outlines are flattened and
//! filled with a 4x supersampled nonzero-winding scanline, producing 8-bit
//! coverage bitmaps. Enough for crisp UI text; no hinting, no kerning.
//!
//! Font files are untrusted: every table read is bounds-checked, and a
//! malformed glyph rasterizes as empty instead of failing the whole font.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../platform/sys.zig");
const cff_mod = @import("cff.zig");

pub const LoadError = error{
    Truncated,
    NotTrueType,
    MissingTables,
    NoUsableCmap,
    BadFont,
    OutOfMemory,
};

fn beU16(d: []const u8, off: usize) error{Truncated}!u16 {
    if (off > d.len or d.len - off < 2) return error.Truncated;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}
fn beI16(d: []const u8, off: usize) error{Truncated}!i16 {
    return @bitCast(try beU16(d, off));
}
fn beU32(d: []const u8, off: usize) error{Truncated}!u32 {
    if (off > d.len or d.len - off < 4) return error.Truncated;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

/// d[off..off+len] when it lies inside d.
fn sub(d: []const u8, off: usize, len: usize) ?[]const u8 {
    if (off > d.len or d.len - off < len) return null;
    return d[off..][0..len];
}

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
const max_edges = 100_000;
const max_components = 256;

const empty_glyph: Glyph = .{ .alpha = &.{}, .w = 0, .h = 0, .bearing_x = 0, .bearing_y = 0, .advance = 0 };

const sfnt_truetype = 0x00010000;
const sfnt_true = 0x74727565; // 'true' (Apple)
const sfnt_otto = 0x4F54544F; // 'OTTO' (CFF outlines)
const tag_ttcf = 0x74746366; // 'ttcf'

/// Number of faces in a font file (1 for plain .ttf/.otf, n for .ttc).
pub fn faceCount(data: []const u8) u32 {
    const tag = beU32(data, 0) catch return 0;
    if (tag != tag_ttcf) return 1;
    return @min(beU32(data, 8) catch 0, 1024);
}

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
        if (mapFile(path)) |m| {
            var f = parse(alloc, m, index) catch |e| {
                unmap(m);
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
        var dir: usize = 0;
        if ((beU32(data, 0) catch return error.NotTrueType) == tag_ttcf) {
            const n = try beU32(data, 8);
            if (index >= n) return error.BadFont;
            dir = try beU32(data, 12 + @as(usize, index) * 4);
        } else if (index != 0) return error.BadFont;

        const version = try beU32(data, dir);
        if (version != sfnt_truetype and version != sfnt_true and version != sfnt_otto) return error.NotTrueType;

        const num_tables = try beU16(data, dir + 4);
        var head: []const u8 = &.{};
        var maxp: []const u8 = &.{};
        var cmap: []const u8 = &.{};
        var glyf: []const u8 = &.{};
        var loca: []const u8 = &.{};
        var hhea: []const u8 = &.{};
        var hmtx: []const u8 = &.{};
        var cff_tab: []const u8 = &.{};

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = dir + 12 + i * 16;
            const tag = sub(data, rec, 4) orelse return error.Truncated;
            const off = try beU32(data, rec + 8);
            const len = try beU32(data, rec + 12);
            const slice = sub(data, off, len) orelse return error.Truncated;
            if (std.mem.eql(u8, tag, "head")) head = slice;
            if (std.mem.eql(u8, tag, "maxp")) maxp = slice;
            if (std.mem.eql(u8, tag, "cmap")) cmap = slice;
            if (std.mem.eql(u8, tag, "glyf")) glyf = slice;
            if (std.mem.eql(u8, tag, "loca")) loca = slice;
            if (std.mem.eql(u8, tag, "hhea")) hhea = slice;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = slice;
            if (std.mem.eql(u8, tag, "CFF ")) cff_tab = slice;
        }
        if (head.len < 54 or maxp.len < 6 or cmap.len < 4 or hhea.len < 36) return error.MissingTables;

        var cff: ?cff_mod.Cff = null;
        if (glyf.len == 0 or loca.len == 0) {
            if (cff_tab.len == 0) return error.MissingTables; // bitmap-only or CFF2
            cff = cff_mod.Cff.parse(cff_tab) catch return error.BadFont;
        }

        const upem = try beU16(head, 18);
        if (upem < 16 or upem > 16384) return error.BadFont;

        var font: Font = .{
            .alloc = alloc,
            .data = data,
            .storage = .borrowed,
            .glyf = glyf,
            .loca = loca,
            .hmtx = hmtx,
            .cff = cff,
            .num_h_metrics = try beU16(hhea, 34),
            .num_glyphs = try beU16(maxp, 4),
            .units_per_em = @floatFromInt(upem),
            .long_loca = (try beI16(head, 50)) != 0,
            .ascent = @floatFromInt(try beI16(hhea, 4)),
            .descent = @floatFromInt(try beI16(hhea, 6)),
            .cache = undefined,
        };
        if (font.ascent <= 0 or font.descent > 0 or font.ascent - font.descent > 4 * font.units_per_em) {
            font.ascent = font.units_per_em * 0.8;
            font.descent = -font.units_per_em * 0.2;
        }
        try font.pickCmap(cmap);
        font.cache = std.AutoHashMap(CacheKey, Glyph).init(alloc);
        return font;
    }

    fn pickCmap(self: *Font, cmap: []const u8) !void {
        const n_sub = try beU16(cmap, 2);
        var best4: i32 = -1;
        var best12: i32 = -1;
        var s: usize = 0;
        while (s < n_sub) : (s += 1) {
            const rec = 4 + s * 8;
            const platform = beU16(cmap, rec) catch break;
            const encoding = beU16(cmap, rec + 2) catch break;
            const sub_off = beU32(cmap, rec + 4) catch break;
            const format = beU16(cmap, sub_off) catch continue;
            // unicode: (3,10) full, (3,1) BMP, (0,*); (3,0) symbol fonts
            const score: i32 = if (platform == 3 and encoding == 10) 4 else if (platform == 3 and encoding == 1) 3 else if (platform == 0) 2 else if (platform == 3 and encoding == 0) 1 else -1;
            if (score < 0) continue;
            if (format == 4 and score > best4) {
                const sub_len = beU16(cmap, sub_off + 2) catch continue;
                const t = cmap[sub_off..@min(cmap.len, sub_off + sub_len)];
                if (!validCmap4(t)) continue;
                best4 = score;
                self.cmap4 = t;
            } else if (format == 12 and score > best12) {
                const n_groups = beU32(cmap, sub_off + 12) catch continue;
                const t = sub(cmap, sub_off, 16 + @as(usize, n_groups) * 12) orelse continue;
                best12 = score;
                self.cmap12 = t;
            }
        }
        if (self.cmap4.len == 0 and self.cmap12.len == 0) return error.NoUsableCmap;
    }

    fn validCmap4(t: []const u8) bool {
        // segment arrays must fit: header(14) + 4*segCountX2 + reservedPad(2)
        const seg_x2: usize = beU16(t, 6) catch return false;
        return seg_x2 % 2 == 0 and t.len >= 16 + seg_x2 * 4;
    }

    pub fn deinit(self: *Font) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.alloc.free(g.alpha);
        self.cache.deinit();
        switch (self.storage) {
            .heap => self.alloc.free(self.data),
            .mapped => unmap(self.data),
            .borrowed => {},
        }
    }

    /// Whether the font maps `cp` to a real glyph.
    pub fn hasGlyph(self: *const Font, cp: u21) bool {
        return self.glyphIndex(cp) != 0;
    }

    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        const gid = if (self.cmap12.len > 0) self.lookup12(cp) else self.lookup4(cp);
        return if (gid < self.num_glyphs) gid else 0;
    }

    fn lookup12(self: *const Font, cp: u21) u16 {
        const d = self.cmap12;
        const n = (d.len - 16) / 12;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const g = 16 + mid * 12;
            const start = beU32(d, g) catch return 0;
            const end = beU32(d, g + 4) catch return 0;
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                const gid = @as(u64, beU32(d, g + 8) catch return 0) + (cp - start);
                return if (gid <= 0xFFFF) @intCast(gid) else 0;
            }
        }
        return 0;
    }

    fn lookup4(self: *const Font, cp: u21) u16 {
        const d = self.cmap4;
        if (cp > 0xFFFF or d.len == 0) return 0;
        const c: u16 = @intCast(cp);
        const seg_x2: usize = beU16(d, 6) catch return 0;
        const seg = seg_x2 / 2;
        const end_base: usize = 14;
        const start_base = end_base + seg_x2 + 2;
        const delta_base = start_base + seg_x2;
        const range_base = delta_base + seg_x2;
        // first segment whose endCode >= c (endCodes are sorted)
        var lo: usize = 0;
        var hi: usize = seg;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if ((beU16(d, end_base + mid * 2) catch return 0) < c) lo = mid + 1 else hi = mid;
        }
        if (lo >= seg) return 0;
        const i = lo;
        const start_code = beU16(d, start_base + i * 2) catch return 0;
        if (c < start_code) return 0;
        const delta = beU16(d, delta_base + i * 2) catch return 0;
        const range_off = beU16(d, range_base + i * 2) catch return 0;
        if (range_off == 0) return c +% delta;
        const addr = range_base + i * 2 + range_off + 2 * @as(usize, c - start_code);
        const gid = beU16(d, addr) catch return 0;
        if (gid == 0) return 0;
        return gid +% delta;
    }

    fn advanceOf(self: *const Font, gid: u16) f64 {
        const n = self.num_h_metrics;
        if (n == 0) return 0;
        const idx = @min(gid, n - 1);
        return @floatFromInt(beU16(self.hmtx, @as(usize, idx) * 4) catch 0);
    }

    fn glyphData(self: *const Font, gid: u16) ?[]const u8 {
        if (gid >= self.num_glyphs) return null;
        var start: usize = 0;
        var end: usize = 0;
        if (self.long_loca) {
            const off = @as(usize, gid) * 4;
            start = beU32(self.loca, off) catch return null;
            end = beU32(self.loca, off + 4) catch return null;
        } else {
            const off = @as(usize, gid) * 2;
            start = @as(usize, beU16(self.loca, off) catch return null) * 2;
            end = @as(usize, beU16(self.loca, off + 2) catch return null) * 2;
        }
        if (end <= start or end > self.glyf.len) return null;
        return self.glyf[start..end];
    }

    const Pt = struct { x: f64, y: f64, on: bool };

    const OutlineError = error{ OutOfMemory, BadGlyph };

    /// Append the glyph outline (flattened, transformed) into `path`.
    /// Handles composites recursively with depth and component budgets.
    fn outline(self: *const Font, gid: u16, xform: [6]f64, depth: u8, budget: *u32, path: *Path) OutlineError!void {
        if (depth > 6) return error.BadGlyph;
        if (budget.* == 0) return error.BadGlyph;
        budget.* -= 1;
        const g = self.glyphData(gid) orelse return;
        if (g.len < 10) return;
        const n_contours = beI16(g, 0) catch return error.BadGlyph;
        if (n_contours == 0) return;
        if (n_contours < 0) return self.composite(g, xform, depth, budget, path);
        path.m = xform;
        return self.simple(g, @intCast(n_contours), path) catch |e| switch (e) {
            error.Truncated => error.BadGlyph,
            else => |x| x,
        };
    }

    fn composite(self: *const Font, g: []const u8, xform: [6]f64, depth: u8, budget: *u32, path: *Path) OutlineError!void {
        var off: usize = 10;
        while (true) {
            const flags = beU16(g, off) catch return error.BadGlyph;
            const comp_gid = beU16(g, off + 2) catch return error.BadGlyph;
            off += 4;
            var dx: f64 = 0;
            var dy: f64 = 0;
            if (flags & 0x0001 != 0) { // words
                const a = beI16(g, off) catch return error.BadGlyph;
                const b = beI16(g, off + 2) catch return error.BadGlyph;
                if (flags & 0x0002 != 0) { // xy values (else: point matching, unsupported)
                    dx = @floatFromInt(a);
                    dy = @floatFromInt(b);
                }
                off += 4;
            } else {
                const ab = sub(g, off, 2) orelse return error.BadGlyph;
                if (flags & 0x0002 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(ab[0])));
                    dy = @floatFromInt(@as(i8, @bitCast(ab[1])));
                }
                off += 2;
            }
            var a: f64 = 1;
            var b: f64 = 0;
            var c: f64 = 0;
            var d: f64 = 1;
            if (flags & 0x0008 != 0) { // single scale
                a = try f2dot14(g, off);
                d = a;
                off += 2;
            } else if (flags & 0x0040 != 0) { // x and y scale
                a = try f2dot14(g, off);
                d = try f2dot14(g, off + 2);
                off += 4;
            } else if (flags & 0x0080 != 0) { // 2x2
                a = try f2dot14(g, off);
                b = try f2dot14(g, off + 2);
                c = try f2dot14(g, off + 4);
                d = try f2dot14(g, off + 6);
                off += 8;
            }
            // compose: child -> (a,b,c,d,dx,dy) -> xform
            const m = [6]f64{
                xform[0] * a + xform[2] * b,
                xform[1] * a + xform[3] * b,
                xform[0] * c + xform[2] * d,
                xform[1] * c + xform[3] * d,
                xform[0] * dx + xform[2] * dy + xform[4],
                xform[1] * dx + xform[3] * dy + xform[5],
            };
            try self.outline(comp_gid, m, depth + 1, budget, path);
            if (flags & 0x0020 == 0) break; // no more components
        }
    }

    fn simple(self: *const Font, g: []const u8, nc: usize, path: *Path) !void {
        var off: usize = 10;
        const ends_base = off;
        // endPtsOfContours must increase strictly; the last one gives n_points
        var prev: i32 = -1;
        for (0..nc) |ci| {
            const e: i32 = try beU16(g, ends_base + ci * 2);
            if (e <= prev) return error.BadGlyph;
            prev = e;
        }
        const n_points: usize = @as(usize, @intCast(prev)) + 1;
        off += nc * 2;
        const ins_len = try beU16(g, off);
        off += 2 + @as(usize, ins_len);

        const flags = try self.alloc.alloc(u8, n_points);
        defer self.alloc.free(flags);
        var fi: usize = 0;
        while (fi < n_points) {
            if (off >= g.len) return error.BadGlyph;
            const fl = g[off];
            off += 1;
            flags[fi] = fl;
            fi += 1;
            if (fl & 0x08 != 0) {
                if (off >= g.len) return error.BadGlyph;
                var rep = g[off];
                off += 1;
                while (rep > 0 and fi < n_points) : (rep -= 1) {
                    flags[fi] = fl;
                    fi += 1;
                }
            }
        }

        const pts = try self.alloc.alloc(Pt, n_points);
        defer self.alloc.free(pts);

        // x coordinates
        var x: i32 = 0;
        for (flags, pts) |fl, *p| {
            if (fl & 0x02 != 0) {
                if (off >= g.len) return error.BadGlyph;
                const v: i32 = g[off];
                off += 1;
                x += if (fl & 0x10 != 0) v else -v;
            } else if (fl & 0x10 == 0) {
                x += try beI16(g, off);
                off += 2;
            }
            p.* = .{ .x = @floatFromInt(x), .y = 0, .on = fl & 0x01 != 0 };
        }
        // y coordinates
        var y: i32 = 0;
        for (flags, pts) |fl, *p| {
            if (fl & 0x04 != 0) {
                if (off >= g.len) return error.BadGlyph;
                const v: i32 = g[off];
                off += 1;
                y += if (fl & 0x20 != 0) v else -v;
            } else if (fl & 0x20 == 0) {
                y += try beI16(g, off);
                off += 2;
            }
            p.y = @floatFromInt(y);
        }

        // emit contours
        var start: usize = 0;
        for (0..nc) |ci| {
            const contour_end: usize = try beU16(g, ends_base + ci * 2);
            const cpts = pts[start .. contour_end + 1];
            start = contour_end + 1;
            if (cpts.len < 2) continue;
            try emitContour(cpts, path);
        }
    }

    pub fn rasterize(self: *Font, gid: u16, size_px: f64) !*const Glyph {
        if (!(size_px > 0 and size_px <= max_size_px)) return &empty_glyph;
        const key = CacheKey{ .gid = gid, .size10 = @intFromFloat(@round(size_px * 10.0)) };
        if (self.cache.getPtr(key)) |g| return g;

        const scale = size_px / self.units_per_em;
        var edges: std.ArrayList([4]f64) = .empty;
        defer edges.deinit(self.alloc);
        // y axis flipped (font units are y-up)
        var path: Path = .{ .alloc = self.alloc, .edges = &edges, .m = .{ scale, 0, 0, -scale, 0, 0 } };

        const res = if (self.cff) |*c|
            c.outline(gid, &path)
        else blk: {
            var budget: u32 = max_components;
            break :blk self.outline(gid, path.m, 0, &budget, &path);
        };
        res catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => edges.clearRetainingCapacity(), // malformed: draw nothing
        };

        var glyph = Glyph{
            .alpha = &.{},
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance = self.advanceOf(gid) * scale,
        };

        if (edges.items.len > 0) {
            var minx: f64 = std.math.floatMax(f64);
            var miny: f64 = std.math.floatMax(f64);
            var maxx: f64 = -std.math.floatMax(f64);
            var maxy: f64 = -std.math.floatMax(f64);
            for (edges.items) |e| {
                minx = @min(minx, @min(e[0], e[2]));
                maxx = @max(maxx, @max(e[0], e[2]));
                miny = @min(miny, @min(e[1], e[3]));
                maxy = @max(maxy, @max(e[1], e[3]));
            }
            const lim = 4 * max_size_px;
            if (minx > -lim and miny > -lim and maxx < lim and maxy < lim) {
                const x0 = @floor(minx);
                const y0 = @floor(miny);
                const w: i32 = @intFromFloat(@ceil(maxx) - x0 + 1);
                const h: i32 = @intFromFloat(@ceil(maxy) - y0 + 1);
                if (w > 0 and h > 0 and w < 4096 and h < 4096) {
                    glyph.w = w;
                    glyph.h = h;
                    glyph.bearing_x = @intFromFloat(x0);
                    glyph.bearing_y = @intFromFloat(y0);
                    glyph.alpha = try fillEdges(self.alloc, edges.items, x0, y0, w, h);
                }
            }
        }

        self.cache.put(key, glyph) catch |e| {
            self.alloc.free(glyph.alpha);
            return e;
        };
        return self.cache.getPtr(key).?;
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

fn f2dot14(d: []const u8, off: usize) error{BadGlyph}!f64 {
    const v = beI16(d, off) catch return error.BadGlyph;
    return @as(f64, @floatFromInt(v)) / 16384.0;
}

fn mapFile(path: []const u8) ![]const u8 {
    const fd = try sys.openRead(path);
    defer sys.close(fd);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx)) != .SUCCESS) return error.StatFailed;
    if (stx.size < 12 or stx.size > 256 * 1024 * 1024) return error.BadSize;
    const len: usize = @intCast(stx.size);
    const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    const ptr: [*]const u8 = @ptrFromInt(rc);
    return ptr[0..len];
}

fn unmap(d: []const u8) void {
    const p: [*]align(std.heap.page_size_min) const u8 = @alignCast(d.ptr);
    _ = linux.munmap(p, d.len);
}

/// Receives outline commands in font units, applies the transform `m`, and
/// flattens curves into line edges in pixel space.
pub const Path = struct {
    alloc: std.mem.Allocator,
    edges: *std.ArrayList([4]f64),
    m: [6]f64,
    start: [2]f64 = .{ 0, 0 },
    cur: [2]f64 = .{ 0, 0 },

    /// curve flattening tolerance in pixels
    const tol = 0.15;

    fn apply(self: *const Path, x: f64, y: f64) [2]f64 {
        const m = self.m;
        return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
    }

    fn edge(self: *Path, p: [2]f64) !void {
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return error.BadGlyph;
        if (self.edges.items.len >= max_edges) return error.BadGlyph;
        try self.edges.append(self.alloc, .{ self.cur[0], self.cur[1], p[0], p[1] });
        self.cur = p;
    }

    pub fn moveTo(self: *Path, x: f64, y: f64) !void {
        self.start = self.apply(x, y);
        self.cur = self.start;
    }

    pub fn lineTo(self: *Path, x: f64, y: f64) !void {
        try self.edge(self.apply(x, y));
    }

    pub fn quadTo(self: *Path, cx: f64, cy: f64, x: f64, y: f64) !void {
        const p0 = self.cur;
        const c = self.apply(cx, cy);
        const p1 = self.apply(x, y);
        const ddx = p0[0] - 2 * c[0] + p1[0];
        const ddy = p0[1] - 2 * c[1] + p1[1];
        const n = segments(@sqrt(ddx * ddx + ddy * ddy) / 4.0);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const it = 1.0 - t;
            try self.edge(.{
                it * it * p0[0] + 2 * it * t * c[0] + t * t * p1[0],
                it * it * p0[1] + 2 * it * t * c[1] + t * t * p1[1],
            });
        }
    }

    pub fn cubicTo(self: *Path, x1: f64, y1: f64, x2: f64, y2: f64, x: f64, y: f64) !void {
        const p0 = self.cur;
        const c1 = self.apply(x1, y1);
        const c2 = self.apply(x2, y2);
        const p1 = self.apply(x, y);
        const ax = @abs(p0[0] - 2 * c1[0] + c2[0]) + @abs(c1[0] - 2 * c2[0] + p1[0]);
        const ay = @abs(p0[1] - 2 * c1[1] + c2[1]) + @abs(c1[1] - 2 * c2[1] + p1[1]);
        const n = segments(0.75 * @max(ax, ay));
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const it = 1.0 - t;
            const b0 = it * it * it;
            const b1 = 3 * it * it * t;
            const b2 = 3 * it * t * t;
            const b3 = t * t * t;
            try self.edge(.{
                b0 * p0[0] + b1 * c1[0] + b2 * c2[0] + b3 * p1[0],
                b0 * p0[1] + b1 * c1[1] + b2 * c2[1] + b3 * p1[1],
            });
        }
    }

    pub fn close(self: *Path) !void {
        if (self.cur[0] != self.start[0] or self.cur[1] != self.start[1]) try self.edge(self.start);
    }

    /// Segments needed so a curve with second-difference size `dd` stays
    /// within `tol` of its chords.
    fn segments(dd: f64) usize {
        if (!(dd > tol)) return 1;
        return @intFromFloat(@min(64.0, @ceil(@sqrt(dd / tol))));
    }
};

/// Flatten one contour (mix of on/off curve points) into the path.
fn emitContour(cpts: []const Font.Pt, path: *Path) !void {
    const n = cpts.len;
    // find first on-curve point (or synthesize midpoint)
    var first: Font.Pt = undefined;
    var first_idx: usize = 0;
    var found = false;
    for (cpts, 0..) |p, i| {
        if (p.on) {
            first = p;
            first_idx = i;
            found = true;
            break;
        }
    }
    if (!found) {
        first = .{ .x = (cpts[0].x + cpts[n - 1].x) / 2, .y = (cpts[0].y + cpts[n - 1].y) / 2, .on = true };
        first_idx = n - 1; // start walking at cpts[0]
    }

    try path.moveTo(first.x, first.y);
    var pending_off: ?Font.Pt = null;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const p = cpts[(first_idx + i) % n];
        if (p.on) {
            if (pending_off) |q| {
                try path.quadTo(q.x, q.y, p.x, p.y);
                pending_off = null;
            } else {
                try path.lineTo(p.x, p.y);
            }
        } else {
            if (pending_off) |q| try path.quadTo(q.x, q.y, (q.x + p.x) / 2, (q.y + p.y) / 2);
            pending_off = p;
        }
    }
    if (pending_off) |q| try path.quadTo(q.x, q.y, first.x, first.y);
    try path.close();
}

/// Nonzero-winding scanline fill with 4x vertical supersampling and
/// fractional horizontal coverage.
fn fillEdges(alloc: std.mem.Allocator, edges: []const [4]f64, x0: f64, y0: f64, w: i32, h: i32) ![]u8 {
    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    const alpha = try alloc.alloc(u8, wu * hu);
    errdefer alloc.free(alpha);
    @memset(alpha, 0);

    const acc = try alloc.alloc(f32, wu);
    defer alloc.free(acc);

    const Crossing = struct { x: f64, dir: i32 };
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(alloc);

    // edges sorted by top y so each scanline stops at the first edge below it
    const Edge = struct { top: f64, bot: f64, e: [4]f64 };
    const sorted = try alloc.alloc(Edge, edges.len);
    defer alloc.free(sorted);
    var n_edges: usize = 0;
    for (edges) |e| {
        if (e[1] == e[3]) continue;
        sorted[n_edges] = .{ .top = @min(e[1], e[3]), .bot = @max(e[1], e[3]), .e = e };
        n_edges += 1;
    }
    std.mem.sort(Edge, sorted[0..n_edges], {}, struct {
        fn lt(_: void, a: Edge, b: Edge) bool {
            return a.top < b.top;
        }
    }.lt);

    const samples = 4;
    var row: usize = 0;
    while (row < hu) : (row += 1) {
        @memset(acc, 0);
        var s: usize = 0;
        while (s < samples) : (s += 1) {
            const y = y0 + @as(f64, @floatFromInt(row)) + (@as(f64, @floatFromInt(s)) + 0.5) / samples;
            crossings.clearRetainingCapacity();
            for (sorted[0..n_edges]) |se| {
                if (se.top > y) break;
                if (y >= se.bot) continue;
                const e = se.e;
                const t = (y - e[1]) / (e[3] - e[1]);
                const x = e[0] + (e[2] - e[0]) * t;
                try crossings.append(alloc, .{ .x = x, .dir = if (e[3] > e[1]) 1 else -1 });
            }
            if (crossings.items.len < 2) continue;
            std.mem.sort(Crossing, crossings.items, {}, struct {
                fn lt(_: void, a: Crossing, b: Crossing) bool {
                    return a.x < b.x;
                }
            }.lt);
            var winding: i32 = 0;
            var span_start: f64 = 0;
            for (crossings.items) |cr| {
                if (winding == 0) span_start = cr.x;
                winding += cr.dir;
                if (winding == 0) {
                    // fill span [span_start, cr.x)
                    const xa = @max(0.0, span_start - x0);
                    const xb = @min(@as(f64, @floatFromInt(w)), cr.x - x0);
                    if (xb <= xa) continue;
                    const ia: usize = @intFromFloat(@floor(xa));
                    const ib: usize = @min(wu, @as(usize, @intFromFloat(@ceil(xb))));
                    if (ib <= ia + 1) {
                        if (ia < wu) acc[ia] += @floatCast((xb - xa) / samples);
                        continue;
                    }
                    // partial first and last pixel, full ones in between
                    acc[ia] += @floatCast((@as(f64, @floatFromInt(ia + 1)) - xa) / samples);
                    var px = ia + 1;
                    while (px + 1 < ib) : (px += 1) acc[px] += 1.0 / @as(f32, samples);
                    acc[ib - 1] += @floatCast((xb - @as(f64, @floatFromInt(ib - 1))) / samples);
                }
            }
        }
        for (acc, 0..) |v, i| {
            alpha[row * wu + i] = @intFromFloat(@min(255.0, @max(0.0, v * 255.0 + 0.5)));
        }
    }
    return alpha;
}

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

test {
    _ = @import("cff.zig");
}

/// Build a tiny valid TrueType font: .notdef, a simple glyph for 'A' (a
/// square with one quadratic corner) and a composite for 'B' (two scaled
/// copies of 'A'), plus U+1F600 mapped to 'A' through cmap format 12.
fn buildTestFont(alloc: std.mem.Allocator) ![]u8 {
    const W = struct {
        fn u16be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .big);
            try l.appendSlice(a, &b);
        }
        fn u32be(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .big);
            try l.appendSlice(a, &b);
        }
    };
    var tables: [8]std.ArrayList(u8) = @splat(.empty);
    defer for (&tables) |*t| t.deinit(alloc);
    const tags = [8]*const [4]u8{ "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name" };
    const a = alloc;

    // cmap: (3,1) format 4 + (3,10) format 12
    const cmap = &tables[0];
    try W.u16be(cmap, a, 0);
    try W.u16be(cmap, a, 2);
    try W.u16be(cmap, a, 3);
    try W.u16be(cmap, a, 1);
    try W.u32be(cmap, a, 20);
    try W.u16be(cmap, a, 3);
    try W.u16be(cmap, a, 10);
    try W.u32be(cmap, a, 20 + 32);
    // format 4: segments ['A','B'] -> 1,2 and the 0xFFFF terminator
    try W.u16be(cmap, a, 4);
    try W.u16be(cmap, a, 32);
    try W.u16be(cmap, a, 0);
    try W.u16be(cmap, a, 4); // segCountX2
    try W.u16be(cmap, a, 4);
    try W.u16be(cmap, a, 1);
    try W.u16be(cmap, a, 0);
    try W.u16be(cmap, a, 'B'); // endCode
    try W.u16be(cmap, a, 0xFFFF);
    try W.u16be(cmap, a, 0); // pad
    try W.u16be(cmap, a, 'A'); // startCode
    try W.u16be(cmap, a, 0xFFFF);
    try W.u16be(cmap, a, @bitCast(@as(i16, 1 - 'A'))); // delta
    try W.u16be(cmap, a, 1);
    try W.u16be(cmap, a, 0); // rangeOffset
    try W.u16be(cmap, a, 0);
    // format 12: 'A'..'B' -> 1, U+1F600 -> 1
    try W.u16be(cmap, a, 12);
    try W.u16be(cmap, a, 0);
    try W.u32be(cmap, a, 16 + 2 * 12);
    try W.u32be(cmap, a, 0);
    try W.u32be(cmap, a, 2);
    for ([_][3]u32{ .{ 'A', 'B', 1 }, .{ 0x1F600, 0x1F600, 1 } }) |g| {
        for (g) |v| try W.u32be(cmap, a, v);
    }

    // glyf: glyph 0 empty, glyph 1 simple, glyph 2 composite
    const glyf = &tables[1];
    var loca: [4]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    try W.u16be(glyf, a, 1); // one contour
    for ([_]u16{ 0, 0, 600, 700 }) |v| try W.u16be(glyf, a, v); // bbox
    try W.u16be(glyf, a, 4); // endPts[0]: 5 points
    try W.u16be(glyf, a, 0); // no instructions
    const flags = [_]u8{ 1, 1, 0, 1, 1 }; // point 2 off-curve
    try glyf.appendSlice(a, &flags);
    const xs = [_]i16{ 50, 500, 50, 0, -500 };
    const ys = [_]i16{ 50, 0, 300, 300, -100 };
    for (xs) |v| try W.u16be(glyf, a, @bitCast(v));
    for (ys) |v| try W.u16be(glyf, a, @bitCast(v));
    while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
    loca[2] = @intCast(glyf.items.len);
    try W.u16be(glyf, a, @bitCast(@as(i16, -1)));
    for ([_]u16{ 0, 0, 600, 700 }) |v| try W.u16be(glyf, a, v);
    // component 1: words + xy + scale + more components
    try W.u16be(glyf, a, 0x0001 | 0x0002 | 0x0008 | 0x0020);
    try W.u16be(glyf, a, 1);
    try W.u16be(glyf, a, 0);
    try W.u16be(glyf, a, 0);
    try W.u16be(glyf, a, 0x2000); // scale 0.5
    // component 2: bytes + xy + 2x2
    try W.u16be(glyf, a, 0x0002 | 0x0080);
    try W.u16be(glyf, a, 1);
    try glyf.appendSlice(a, &.{ 100, 50 });
    for ([_]u16{ 0x2000, 0, 0x0800, 0x2000 }) |v| try W.u16be(glyf, a, v);
    while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
    loca[3] = @intCast(glyf.items.len);

    const head = &tables[2];
    try head.appendNTimes(a, 0, 54);
    std.mem.writeInt(u16, head.items[18..20], 1000, .big);
    std.mem.writeInt(i16, head.items[50..52], 1, .big); // long loca
    const hhea = &tables[3];
    try hhea.appendNTimes(a, 0, 36);
    std.mem.writeInt(i16, hhea.items[4..6], 800, .big);
    std.mem.writeInt(i16, hhea.items[6..8], -200, .big);
    std.mem.writeInt(u16, hhea.items[34..36], 3, .big);
    for (0..3) |_| {
        try W.u16be(&tables[4], a, 650);
        try W.u16be(&tables[4], a, 0);
    }
    for (loca) |v| try W.u32be(&tables[5], a, v);
    const maxp = &tables[6];
    try W.u32be(maxp, a, 0x00005000);
    try W.u16be(maxp, a, 3);
    try W.u16be(&tables[7], a, 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try W.u32be(&out, a, sfnt_truetype);
    try W.u16be(&out, a, tables.len);
    try out.appendNTimes(a, 0, 6);
    var off: u32 = 12 + 16 * tables.len;
    for (tables, tags) |t, tag| {
        try out.appendSlice(a, tag);
        try W.u32be(&out, a, 0);
        try W.u32be(&out, a, off);
        try W.u32be(&out, a, @intCast(t.items.len));
        off += @intCast((t.items.len + 3) / 4 * 4);
    }
    for (tables) |t| {
        try out.appendSlice(a, t.items);
        while (out.items.len % 4 != 0) try out.append(a, 0);
    }
    return out.toOwnedSlice(a);
}

test "embedded test font: simple, composite and format 12 glyphs" {
    const alloc = std.testing.allocator;
    const data = try buildTestFont(alloc);
    defer alloc.free(data);
    var font = try Font.parse(alloc, data, 0);
    defer font.deinit();
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex(0x1F600));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex('C'));
    const g = try font.rasterize(1, 20);
    try std.testing.expect(g.w >= 8 and g.h >= 8);
    const c = try font.rasterize(2, 20);
    try std.testing.expect(c.w > 0);
}

/// Parse and rasterize mutated copies of `seed`: every outcome must be an
/// error or a glyph, never a panic, hang or leak.
fn fuzzFont(alloc: std.mem.Allocator, seed: []const u8, iterations: usize, rng_seed: u64, max_glyphs: u16) !void {
    var prng = std.Random.DefaultPrng.init(rng_seed);
    const r = prng.random();
    const buf = try alloc.alloc(u8, seed.len);
    defer alloc.free(buf);
    const extremes = [_]u32{ 0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x7FFFFFFF, 0xFFFFFFFF, 0x10000 };
    for (0..iterations) |_| {
        @memcpy(buf, seed);
        var len = seed.len;
        const n_mut = r.intRangeAtMost(u8, 1, 12);
        for (0..n_mut) |_| {
            // half the mutations land in the header and table directory
            const span = if (r.boolean()) @min(len, 512) else len;
            if (span < 4) break;
            const at = r.uintLessThan(usize, span - 3);
            switch (r.intRangeAtMost(u8, 0, 3)) {
                0 => buf[at] = r.int(u8),
                1 => buf[at] ^= @as(u8, 1) << r.int(u3),
                2 => std.mem.writeInt(u32, buf[at..][0..4], extremes[r.uintLessThan(usize, extremes.len)], .big),
                else => std.mem.writeInt(u16, buf[at..][0..2], @truncate(extremes[r.uintLessThan(usize, extremes.len)]), .big),
            }
            if (r.intRangeAtMost(u8, 0, 30) == 0) len = r.intRangeAtMost(usize, 0, len);
        }
        var font = Font.parse(alloc, buf[0..len], r.intRangeAtMost(u32, 0, 1)) catch continue;
        defer font.deinit();
        for ([_]u21{ 'A', 'g', 0xE9, 0x20AC, 0x6F22, 0x1F600, 0x10FFFF }) |cp| {
            _ = try font.rasterize(font.glyphIndex(cp), 17);
        }
        var gid: u16 = 0;
        while (gid < @min(font.num_glyphs, max_glyphs)) : (gid += 1) {
            _ = try font.rasterize(gid, 9);
        }
        _ = try font.rasterize(r.int(u16), 31);
    }
}

test "font parser survives mutated fonts" {
    const alloc = std.testing.allocator;
    const embedded = try buildTestFont(alloc);
    defer alloc.free(embedded);
    try fuzzFont(alloc, embedded, 3000, 1, 8);

    const seeds = [_]struct { path: []const u8, iters: usize, glyphs: u16 }{
        .{ .path = "/usr/share/fonts/truetype/noto/NotoSansLycian-Regular.ttf", .iters = 400, .glyphs = 64 },
        .{ .path = "/usr/share/fonts/opentype/urw-base35/StandardSymbolsPS.otf", .iters = 150, .glyphs = 256 },
        .{ .path = "/usr/share/fonts/opentype/urw-base35/D050000L.otf", .iters = 100, .glyphs = 256 },
        .{ .path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", .iters = 40, .glyphs = 200 },
    };
    for (seeds, 0..) |s, i| {
        const data = sys.readFileAlloc(alloc, s.path, 2 * 1024 * 1024) catch continue;
        defer alloc.free(data);
        try fuzzFont(alloc, data, s.iters, 10 + i, s.glyphs);
    }
}
