//! Minimal TrueType font parser and rasterizer: cmap (format 4), glyf
//! (simple + composite), loca, hmtx. Quadratic outlines are flattened and
//! filled with a 4x supersampled nonzero-winding scanline, producing 8-bit
//! coverage bitmaps. Enough for crisp UI text; no hinting, no kerning.

const std = @import("std");
const sys = @import("../platform/sys.zig");

fn beU16(d: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, d[off..][0..2], .big);
}
fn beI16(d: []const u8, off: usize) i16 {
    return std.mem.readInt(i16, d[off..][0..2], .big);
}
fn beU32(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .big);
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

pub const Font = struct {
    alloc: std.mem.Allocator,
    data: []u8,
    // table slices
    glyf: []const u8,
    loca: []const u8,
    cmap4: []const u8, // format-4 subtable
    hmtx: []const u8,
    num_h_metrics: u16,
    num_glyphs: u16,
    units_per_em: f64,
    long_loca: bool,
    ascent: f64, // font units
    descent: f64, // font units, negative

    cache: std.AutoHashMap(CacheKey, Glyph),

    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Font {
        const data = try sys.readFileAlloc(alloc, path, 32 * 1024 * 1024);
        errdefer alloc.free(data);
        if (data.len < 12 or beU32(data, 0) != 0x00010000) return error.NotTrueType;

        const num_tables = beU16(data, 4);
        var head: []const u8 = &.{};
        var maxp: []const u8 = &.{};
        var cmap: []const u8 = &.{};
        var glyf: []const u8 = &.{};
        var loca: []const u8 = &.{};
        var hhea: []const u8 = &.{};
        var hmtx: []const u8 = &.{};

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.Truncated;
            const tag = data[rec .. rec + 4];
            const off = beU32(data, rec + 8);
            const len = beU32(data, rec + 12);
            if (off + len > data.len) return error.Truncated;
            const slice = data[off .. off + len];
            if (std.mem.eql(u8, tag, "head")) head = slice;
            if (std.mem.eql(u8, tag, "maxp")) maxp = slice;
            if (std.mem.eql(u8, tag, "cmap")) cmap = slice;
            if (std.mem.eql(u8, tag, "glyf")) glyf = slice;
            if (std.mem.eql(u8, tag, "loca")) loca = slice;
            if (std.mem.eql(u8, tag, "hhea")) hhea = slice;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = slice;
        }
        if (head.len < 52 or maxp.len < 6 or cmap.len < 4 or glyf.len == 0 or loca.len == 0 or hhea.len < 36) {
            return error.MissingTables;
        }

        // find a format-4 unicode subtable
        var cmap4: []const u8 = &.{};
        const n_sub = beU16(cmap, 2);
        var best_score: i32 = -1;
        var s: usize = 0;
        while (s < n_sub) : (s += 1) {
            const rec = 4 + s * 8;
            const platform = beU16(cmap, rec);
            const encoding = beU16(cmap, rec + 2);
            const sub_off = beU32(cmap, rec + 4);
            if (sub_off + 4 > cmap.len) continue;
            const format = beU16(cmap, sub_off);
            if (format != 4) continue;
            const score: i32 = if (platform == 3 and encoding == 1) 2 else if (platform == 0) 1 else 0;
            if (score > best_score) {
                best_score = score;
                const sub_len = beU16(cmap, sub_off + 2);
                const end = @min(cmap.len, sub_off + sub_len);
                cmap4 = cmap[sub_off..end];
            }
        }
        if (cmap4.len == 0) return error.NoUsableCmap;
        // segment arrays must fit: header(14) + 4*segCountX2 + reservedPad(2)
        if (cmap4.len < 14) return error.NoUsableCmap;
        const seg_x2: usize = beU16(cmap4, 6);
        if (cmap4.len < 14 + seg_x2 * 4 + 2) return error.NoUsableCmap;

        return .{
            .alloc = alloc,
            .data = data,
            .glyf = glyf,
            .loca = loca,
            .cmap4 = cmap4,
            .hmtx = hmtx,
            .num_h_metrics = beU16(hhea, 34),
            .num_glyphs = beU16(maxp, 4),
            .units_per_em = @floatFromInt(beU16(head, 18)),
            .long_loca = beI16(head, 50) != 0,
            .ascent = @floatFromInt(beI16(hhea, 4)),
            .descent = @floatFromInt(beI16(hhea, 6)),
            .cache = std.AutoHashMap(CacheKey, Glyph).init(alloc),
        };
    }

    pub fn deinit(self: *Font) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| self.alloc.free(g.alpha);
        self.cache.deinit();
        self.alloc.free(self.data);
    }

    pub fn glyphIndex(self: *const Font, cp: u21) u16 {
        const d = self.cmap4;
        if (cp > 0xFFFF) return 0;
        const c: u16 = @intCast(cp);
        const seg_x2 = beU16(d, 6);
        const seg = seg_x2 / 2;
        const end_base: usize = 14;
        const start_base = end_base + seg_x2 + 2;
        const delta_base = start_base + seg_x2;
        const range_base = delta_base + seg_x2;
        var i: usize = 0;
        while (i < seg) : (i += 1) {
            const end_code = beU16(d, end_base + i * 2);
            if (c > end_code) continue;
            const start_code = beU16(d, start_base + i * 2);
            if (c < start_code) return 0;
            const delta = beU16(d, delta_base + i * 2);
            const range_off = beU16(d, range_base + i * 2);
            if (range_off == 0) return c +% delta;
            const addr = range_base + i * 2 + range_off + 2 * @as(usize, c - start_code);
            if (addr + 2 > d.len) return 0;
            const gid = beU16(d, addr);
            if (gid == 0) return 0;
            return gid +% delta;
        }
        return 0;
    }

    fn advanceOf(self: *const Font, gid: u16) f64 {
        const n = self.num_h_metrics;
        if (n == 0) return 0;
        const idx = @min(gid, n - 1);
        const off = @as(usize, idx) * 4;
        if (off + 2 > self.hmtx.len) return 0;
        return @floatFromInt(beU16(self.hmtx, off));
    }

    fn glyphData(self: *const Font, gid: u16) ?[]const u8 {
        if (gid >= self.num_glyphs) return null;
        var start: usize = 0;
        var end: usize = 0;
        if (self.long_loca) {
            const off = @as(usize, gid) * 4;
            if (off + 8 > self.loca.len) return null;
            start = beU32(self.loca, off);
            end = beU32(self.loca, off + 4);
        } else {
            const off = @as(usize, gid) * 2;
            if (off + 4 > self.loca.len) return null;
            start = @as(usize, beU16(self.loca, off)) * 2;
            end = @as(usize, beU16(self.loca, off + 2)) * 2;
        }
        if (end <= start or end > self.glyf.len) return null;
        return self.glyf[start..end];
    }

    const Pt = struct { x: f64, y: f64, on: bool };

    /// Append the glyph outline (flattened to line segments in font units,
    /// transformed) into `edges`. Handles composites recursively.
    fn outline(
        self: *const Font,
        gid: u16,
        xform: [6]f64, // a b c d e f: x' = a*x + c*y + e ; y' = b*x + d*y + f
        depth: u8,
        edges: *std.ArrayList([4]f64),
        pts: *std.ArrayList(Pt),
    ) !void {
        if (depth > 5) return;
        const g = self.glyphData(gid) orelse return;
        if (g.len < 10) return;
        const n_contours = beI16(g, 0);

        if (n_contours < 0) {
            // composite glyph
            var off: usize = 10;
            while (true) {
                if (off + 4 > g.len) return;
                const flags = beU16(g, off);
                const comp_gid = beU16(g, off + 2);
                off += 4;
                var dx: f64 = 0;
                var dy: f64 = 0;
                if (flags & 0x0001 != 0) { // words
                    if (flags & 0x0002 != 0) { // xy values
                        dx = @floatFromInt(beI16(g, off));
                        dy = @floatFromInt(beI16(g, off + 2));
                    }
                    off += 4;
                } else {
                    if (flags & 0x0002 != 0) {
                        dx = @floatFromInt(@as(i8, @bitCast(g[off])));
                        dy = @floatFromInt(@as(i8, @bitCast(g[off + 1])));
                    }
                    off += 2;
                }
                var a: f64 = 1;
                var b: f64 = 0;
                var c: f64 = 0;
                var d: f64 = 1;
                if (flags & 0x0008 != 0) { // single scale
                    a = f2dot14(g, off);
                    d = a;
                    off += 2;
                } else if (flags & 0x0040 != 0) { // x and y scale
                    a = f2dot14(g, off);
                    d = f2dot14(g, off + 2);
                    off += 4;
                } else if (flags & 0x0080 != 0) { // 2x2
                    a = f2dot14(g, off);
                    b = f2dot14(g, off + 2);
                    c = f2dot14(g, off + 4);
                    d = f2dot14(g, off + 6);
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
                try self.outline(comp_gid, m, depth + 1, edges, pts);
                if (flags & 0x0020 == 0) break; // no more components
            }
            return;
        }

        const nc: usize = @intCast(n_contours);
        var off: usize = 10;
        if (off + nc * 2 + 2 > g.len) return;
        const n_points: usize = @as(usize, beU16(g, off + (nc - 1) * 2)) + 1;
        const ends_base = off;
        off += nc * 2;
        const ins_len = beU16(g, off);
        off += 2 + ins_len;

        // flags
        var flags_buf: [1024]u8 = undefined;
        if (n_points > flags_buf.len) return;
        var fi: usize = 0;
        while (fi < n_points) {
            if (off >= g.len) return;
            const fl = g[off];
            off += 1;
            flags_buf[fi] = fl;
            fi += 1;
            if (fl & 0x08 != 0) {
                if (off >= g.len) return;
                var rep = g[off];
                off += 1;
                while (rep > 0 and fi < n_points) : (rep -= 1) {
                    flags_buf[fi] = fl;
                    fi += 1;
                }
            }
        }

        pts.clearRetainingCapacity();
        try pts.ensureTotalCapacity(self.alloc, n_points);

        // x coordinates
        var x: i32 = 0;
        for (flags_buf[0..n_points]) |fl| {
            if (fl & 0x02 != 0) {
                if (off >= g.len) return;
                const v: i32 = g[off];
                off += 1;
                x += if (fl & 0x10 != 0) v else -v;
            } else if (fl & 0x10 == 0) {
                if (off + 2 > g.len) return;
                x += beI16(g, off);
                off += 2;
            }
            pts.appendAssumeCapacity(.{ .x = @floatFromInt(x), .y = 0, .on = fl & 0x01 != 0 });
        }
        // y coordinates
        var y: i32 = 0;
        for (flags_buf[0..n_points], 0..) |fl, idx| {
            if (fl & 0x04 != 0) {
                if (off >= g.len) return;
                const v: i32 = g[off];
                off += 1;
                y += if (fl & 0x20 != 0) v else -v;
            } else if (fl & 0x20 == 0) {
                if (off + 2 > g.len) return;
                y += beI16(g, off);
                off += 2;
            }
            pts.items[idx].y = @floatFromInt(y);
        }

        // emit contours
        var start: usize = 0;
        var ci: usize = 0;
        while (ci < nc) : (ci += 1) {
            const contour_end: usize = beU16(g, ends_base + ci * 2);
            const cpts = pts.items[start .. contour_end + 1];
            start = contour_end + 1;
            if (cpts.len < 2) continue;
            try emitContour(cpts, xform, edges, self.alloc);
        }
    }

    pub fn rasterize(self: *Font, gid: u16, size_px: f64) !*const Glyph {
        const key = CacheKey{ .gid = gid, .size10 = @intFromFloat(@round(size_px * 10.0)) };
        if (self.cache.getPtr(key)) |g| return g;

        const scale = size_px / self.units_per_em;
        var edges: std.ArrayList([4]f64) = .empty;
        defer edges.deinit(self.alloc);
        var pts: std.ArrayList(Pt) = .empty;
        defer pts.deinit(self.alloc);

        // y axis flipped (font units are y-up)
        try self.outline(gid, .{ scale, 0, 0, -scale, 0, 0 }, 0, &edges, &pts);

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

        try self.cache.put(key, glyph);
        return self.cache.getPtr(key).?;
    }

    pub fn ascentPx(self: *const Font, size_px: f64) f64 {
        return self.ascent * (size_px / self.units_per_em);
    }
    pub fn lineHeightPx(self: *const Font, size_px: f64) f64 {
        return (self.ascent - self.descent) * (size_px / self.units_per_em);
    }
};

fn f2dot14(d: []const u8, off: usize) f64 {
    return @as(f64, @floatFromInt(beI16(d, off))) / 16384.0;
}

/// Flatten one contour (mix of on/off curve points) into line segments.
fn emitContour(cpts: []const Font.Pt, m: [6]f64, edges: *std.ArrayList([4]f64), alloc: std.mem.Allocator) !void {
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
    }

    var cur = first;
    var pending_off: ?Font.Pt = null;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const p = cpts[(first_idx + i) % n];
        if (p.on) {
            if (pending_off) |q| {
                try quad(cur, q, p, m, edges, alloc);
                pending_off = null;
            } else {
                try lineSeg(cur, p, m, edges, alloc);
            }
            cur = p;
        } else {
            if (pending_off) |q| {
                const mid = Font.Pt{ .x = (q.x + p.x) / 2, .y = (q.y + p.y) / 2, .on = true };
                try quad(cur, q, mid, m, edges, alloc);
                cur = mid;
            }
            pending_off = p;
        }
    }
    // close
    if (pending_off) |q| {
        try quad(cur, q, first, m, edges, alloc);
    } else if (cur.x != first.x or cur.y != first.y) {
        try lineSeg(cur, first, m, edges, alloc);
    }
}

fn apply(m: [6]f64, x: f64, y: f64) [2]f64 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}

fn lineSeg(a: Font.Pt, b: Font.Pt, m: [6]f64, edges: *std.ArrayList([4]f64), alloc: std.mem.Allocator) !void {
    const p0 = apply(m, a.x, a.y);
    const p1 = apply(m, b.x, b.y);
    try edges.append(alloc, .{ p0[0], p0[1], p1[0], p1[1] });
}

fn quad(a: Font.Pt, q: Font.Pt, b: Font.Pt, m: [6]f64, edges: *std.ArrayList([4]f64), alloc: std.mem.Allocator) !void {
    const p0 = apply(m, a.x, a.y);
    const pc = apply(m, q.x, q.y);
    const p1 = apply(m, b.x, b.y);
    const steps = 8;
    var prev = p0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / steps;
        const it = 1.0 - t;
        const x = it * it * p0[0] + 2 * it * t * pc[0] + t * t * p1[0];
        const y = it * it * p0[1] + 2 * it * t * pc[1] + t * t * p1[1];
        try edges.append(alloc, .{ prev[0], prev[1], x, y });
        prev = .{ x, y };
    }
}

/// Nonzero-winding scanline fill with 4x vertical supersampling and
/// fractional horizontal coverage.
fn fillEdges(alloc: std.mem.Allocator, edges: []const [4]f64, x0: f64, y0: f64, w: i32, h: i32) ![]u8 {
    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    const alpha = try alloc.alloc(u8, wu * hu);
    @memset(alpha, 0);

    const acc = try alloc.alloc(f32, wu);
    defer alloc.free(acc);

    const Crossing = struct { x: f64, dir: i32 };
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(alloc);

    const samples = 4;
    var row: usize = 0;
    while (row < hu) : (row += 1) {
        @memset(acc, 0);
        var s: usize = 0;
        while (s < samples) : (s += 1) {
            const y = y0 + @as(f64, @floatFromInt(row)) + (@as(f64, @floatFromInt(s)) + 0.5) / samples;
            crossings.clearRetainingCapacity();
            for (edges) |e| {
                const ey0 = e[1];
                const ey1 = e[3];
                if (ey0 == ey1) continue;
                const top = @min(ey0, ey1);
                const bot = @max(ey0, ey1);
                if (y < top or y >= bot) continue;
                const t = (y - ey0) / (ey1 - ey0);
                const x = e[0] + (e[2] - e[0]) * t;
                try crossings.append(alloc, .{ .x = x, .dir = if (ey1 > ey0) 1 else -1 });
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
                    var xa = span_start - x0;
                    var xb = cr.x - x0;
                    xa = @max(0.0, xa);
                    xb = @min(@as(f64, @floatFromInt(w)), xb);
                    if (xb <= xa) continue;
                    const ia: usize = @intFromFloat(@floor(xa));
                    const ib: usize = @intFromFloat(@ceil(xb));
                    var px = ia;
                    while (px < ib and px < wu) : (px += 1) {
                        const l = @max(xa, @as(f64, @floatFromInt(px)));
                        const r = @min(xb, @as(f64, @floatFromInt(px + 1)));
                        if (r > l) acc[px] += @floatCast((r - l) / samples);
                    }
                }
            }
        }
        for (acc, 0..) |v, i| {
            alpha[row * wu + i] = @intFromFloat(@min(255.0, @max(0.0, v * 255.0)));
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
}
