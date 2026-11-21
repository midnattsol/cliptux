//! Outline sink shared by the glyf and CFF decoders.

const std = @import("std");

const max_edges = 100_000;

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
