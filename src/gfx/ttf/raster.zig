//! Scanline rasterizer: fills flattened outline edges into an 8-bit
//! coverage bitmap.

const std = @import("std");

/// Coverage bitmap placed relative to the pen position and baseline.
pub const Bitmap = struct {
    alpha: []u8,
    w: i32,
    h: i32,
    bearing_x: i32,
    bearing_y: i32,
};

/// Fill `edges` (pixel space, y down) into a bitmap; null when there is
/// nothing to draw or the bounds are out of range (`lim` pixels from the
/// origin, or 4096 pixels per side).
pub fn render(alloc: std.mem.Allocator, edges: []const [4]f64, lim: f64) !?Bitmap {
    if (edges.len == 0) return null;
    const minx, const miny, const maxx, const maxy = bounds(edges);
    if (!(minx > -lim and miny > -lim and maxx < lim and maxy < lim)) return null;
    const x0 = @floor(minx);
    const y0 = @floor(miny);
    const w: i32 = @intFromFloat(@ceil(maxx) - x0 + 1);
    const h: i32 = @intFromFloat(@ceil(maxy) - y0 + 1);
    if (!(w > 0 and h > 0 and w < 4096 and h < 4096)) return null;
    return .{
        .w = w,
        .h = h,
        .bearing_x = @intFromFloat(x0),
        .bearing_y = @intFromFloat(y0),
        .alpha = try fillEdges(alloc, edges, x0, y0, w, h),
    };
}

/// (minx, miny, maxx, maxy) over all edge endpoints.
fn bounds(edges: []const [4]f64) [4]f64 {
    var minx: f64 = std.math.floatMax(f64);
    var miny: f64 = std.math.floatMax(f64);
    var maxx: f64 = -std.math.floatMax(f64);
    var maxy: f64 = -std.math.floatMax(f64);
    for (edges) |e| {
        minx = @min(minx, @min(e[0], e[2]));
        maxx = @max(maxx, @max(e[0], e[2]));
        miny = @min(miny, @min(e[1], e[3]));
        maxy = @max(maxy, @max(e[1], e[3]));
    }
    return .{ minx, miny, maxx, maxy };
}

const samples = 4;

const Crossing = struct { x: f64, dir: i32 };

const Edge = struct { top: f64, bot: f64, e: [4]f64 };

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

    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(alloc);

    const sorted_buf = try alloc.alloc(Edge, edges.len);
    defer alloc.free(sorted_buf);
    const sorted = sortEdges(sorted_buf, edges);

    var row: usize = 0;
    while (row < hu) : (row += 1) {
        @memset(acc, 0);
        var s: usize = 0;
        while (s < samples) : (s += 1) {
            const y = y0 + @as(f64, @floatFromInt(row)) + (@as(f64, @floatFromInt(s)) + 0.5) / samples;
            try collectCrossings(alloc, &crossings, sorted, y);
            if (crossings.items.len < 2) continue;
            std.mem.sort(Crossing, crossings.items, {}, struct {
                fn lt(_: void, a: Crossing, b: Crossing) bool {
                    return a.x < b.x;
                }
            }.lt);
            fillSpans(acc, crossings.items, x0, w);
        }
        for (acc, 0..) |v, i| {
            alpha[row * wu + i] = @intFromFloat(@min(255.0, @max(0.0, v * 255.0 + 0.5)));
        }
    }
    return alpha;
}

/// Non-horizontal edges sorted by top y, so each scanline stops at the
/// first edge below it. Returns the used prefix of `buf`.
fn sortEdges(buf: []Edge, edges: []const [4]f64) []Edge {
    var n_edges: usize = 0;
    for (edges) |e| {
        if (e[1] == e[3]) continue;
        buf[n_edges] = .{ .top = @min(e[1], e[3]), .bot = @max(e[1], e[3]), .e = e };
        n_edges += 1;
    }
    const sorted = buf[0..n_edges];
    std.mem.sort(Edge, sorted, {}, struct {
        fn lt(_: void, a: Edge, b: Edge) bool {
            return a.top < b.top;
        }
    }.lt);
    return sorted;
}

/// Replace `crossings` with where the edges cross the scanline `y`.
inline fn collectCrossings(alloc: std.mem.Allocator, crossings: *std.ArrayList(Crossing), sorted: []const Edge, y: f64) !void {
    crossings.clearRetainingCapacity();
    for (sorted) |se| {
        if (se.top > y) break;
        if (y >= se.bot) continue;
        const e = se.e;
        const t = (y - e[1]) / (e[3] - e[1]);
        const x = e[0] + (e[2] - e[0]) * t;
        try crossings.append(alloc, .{ .x = x, .dir = if (e[3] > e[1]) 1 else -1 });
    }
}

/// Add one sample's nonzero-winding spans (x-sorted crossings) to `acc`.
inline fn fillSpans(acc: []f32, crossings: []const Crossing, x0: f64, w: i32) void {
    const wu = acc.len;
    var winding: i32 = 0;
    var span_start: f64 = 0;
    for (crossings) |cr| {
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
