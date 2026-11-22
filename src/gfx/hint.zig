//! Grid fitting for stroked icons: the stroke becomes a whole number of
//! pixels (or keeps a soft edge around a whole-pixel core when it is
//! wide) and every horizontal and vertical stroke moves (by less than a
//! pixel) so that its edges fall on pixel boundaries. Everything between
//! those lines is stretched to follow, so curves and diagonals stay
//! joined and keep their anti-aliasing. A 1.3 px stroke at x = 4.6 drew
//! two half-grey columns; fitted, it is one solid column.
//!
//! Stable API:
//!   strokeWidth(width_px)          the fitted stroke width
//!   fit(segs, width_px)            move `segs` (output pixels) in place

const std = @import("std");
const Seg = @import("path.zig").Seg;

/// The stroke width: thin strokes round to whole pixels (at least one);
/// from 2.5 px on the fraction is kept as a soft edge around a solid
/// core, so large icons keep their weight.
pub fn strokeWidth(w: f32) f32 {
    return if (w < 2.5) @max(1, @round(w)) else w;
}

/// Where a stroke centred at `c` lands: with an odd number of solid
/// pixels it centres on a pixel, with an even number on a boundary.
fn snap(c: f32, width: f32) f32 {
    const core = @max(1, @floor(width + 1e-3));
    const odd = @mod(core, 2) == 1;
    return if (odd) @floor(c) + 0.5 else @round(c);
}

const max_hints = 64;

/// The positions of one axis that strokes sit on, and where they go.
const Hints = struct {
    from: [max_hints]f32 = undefined,
    to: [max_hints]f32 = undefined,
    n: usize = 0,

    fn add(h: *Hints, c: f32, width: f32) void {
        for (h.from[0..h.n]) |f| if (@abs(f - c) < 1e-3) return;
        if (h.n == max_hints) return;
        // keep sorted by `from`
        var i = h.n;
        while (i > 0 and h.from[i - 1] > c) : (i -= 1) {
            h.from[i] = h.from[i - 1];
            h.to[i] = h.to[i - 1];
        }
        h.from[i] = c;
        h.to[i] = snap(c, width);
        h.n += 1;
    }

    /// `c` moved like the hints around it: linearly between two, by the
    /// nearest one's offset outside them.
    fn map(h: *const Hints, c: f32) f32 {
        if (h.n == 0) return c;
        for (h.from[0..h.n], h.to[0..h.n]) |f, t| if (@abs(f - c) < 1e-3) return t;
        if (c <= h.from[0]) return c + h.to[0] - h.from[0];
        const last = h.n - 1;
        if (c >= h.from[last]) return c + h.to[last] - h.from[last];
        var i: usize = 1;
        while (h.from[i] < c) i += 1;
        const t = (c - h.from[i - 1]) / (h.from[i] - h.from[i - 1]);
        return h.to[i - 1] + t * (h.to[i] - h.to[i - 1]);
    }
};

/// Fit `segs` (output pixels) for a stroke `width` px wide (already
/// fitted with strokeWidth).
pub fn fit(segs: []Seg, width: f32) void {
    var hx: Hints = .{};
    var hy: Hints = .{};
    for (segs) |s| {
        if (@abs(s[0] - s[2]) < 1e-3) hx.add(s[0], width);
        if (@abs(s[1] - s[3]) < 1e-3) hy.add(s[1], width);
    }
    for (segs) |*s| {
        s[0] = hx.map(s[0]);
        s[2] = hx.map(s[2]);
        s[1] = hy.map(s[1]);
        s[3] = hy.map(s[3]);
    }
}

const testing = std.testing;

test "strokes land on whole pixels and stay joined" {
    // a box from 4.6 to 13.3 and a diagonal from its corner
    var segs = [_]Seg{
        .{ 4.6, 4.6, 13.3, 4.6 },
        .{ 13.3, 4.6, 13.3, 13.3 },
        .{ 4.6, 4.6, 9.0, 13.3 },
    };
    fit(&segs, 1);
    // a 1 px stroke is centred in a pixel
    try testing.expectEqual(@as(f32, 4.5), segs[0][1]);
    try testing.expectEqual(@as(f32, 13.5), segs[1][0]);
    // the diagonal still starts where the edges meet
    try testing.expectEqual(segs[0][0], segs[2][0]);
    try testing.expectEqual(segs[0][1], segs[2][1]);
    // a 2 px stroke is centred on a pixel boundary
    var two = [_]Seg{.{ 3, 7.4, 20, 7.4 }};
    fit(&two, 2);
    try testing.expectEqual(@as(f32, 7), two[0][1]);
    try testing.expectEqual(@as(f32, 1), strokeWidth(1.31));
    try testing.expectEqual(@as(f32, 2.62), strokeWidth(2.62));
    // 2.62 px: a solid 2 px core on a boundary, soft edges either side
    var wide = [_]Seg{.{ 3, 7.4, 20, 7.4 }};
    fit(&wide, 2.62);
    try testing.expectEqual(@as(f32, 7), wide[0][1]);
    try testing.expectEqual(@as(f32, 1), strokeWidth(0.4));
}

test "between hints, points move in proportion" {
    var h: Hints = .{};
    h.add(2.2, 1); // to 2.5
    h.add(10.8, 1); // to 10.5
    try testing.expectApproxEqAbs(@as(f32, 6.5), h.map(6.5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.3), h.map(0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 11.7), h.map(12), 1e-4);
}
