//! A tiny SVG path renderer for UI icons: parses path data (M L H V C S Q
//! T A Z, absolute and relative), flattens curves and arcs to line
//! segments, and strokes them (round caps and joins) into an 8-bit
//! coverage mask. Icons are drawn in a 24x24 unit box, like the usual
//! stroke icon sets, and scaled to any pixel size.

const std = @import("std");

pub const Seg = [4]f32; // x0, y0, x1, y1

pub const max_segs = 768;

/// A flattened path: line segments in path units.
pub const Flat = struct {
    segs: [max_segs]Seg = undefined,
    n: usize = 0,

    fn add(self: *Flat, x0: f32, y0: f32, x1: f32, y1: f32) void {
        if (self.n == max_segs) return;
        self.segs[self.n] = .{ x0, y0, x1, y1 };
        self.n += 1;
    }

    pub fn slice(self: *const Flat) []const Seg {
        return self.segs[0..self.n];
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(self: *Parser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', ',', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// True when a number (not a command letter) comes next.
    fn atNumber(self: *Parser) bool {
        self.skipSep();
        if (self.i >= self.s.len) return false;
        const c = self.s[self.i];
        return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
    }

    fn number(self: *Parser) !f32 {
        self.skipSep();
        const start = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
        var dot = false;
        var digits = false;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c >= '0' and c <= '9') {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (self.i < self.s.len and (self.s[self.i] == 'e' or self.s[self.i] == 'E')) {
            self.i += 1;
            if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
            while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        }
        if (!digits) return error.BadPath;
        return std.fmt.parseFloat(f32, self.s[start..self.i]) catch error.BadPath;
    }

    /// Arc flags may be written without separators ("a1 1 0 011 1").
    fn flag(self: *Parser) !bool {
        self.skipSep();
        if (self.i >= self.s.len) return error.BadPath;
        const c = self.s[self.i];
        if (c != '0' and c != '1') return error.BadPath;
        self.i += 1;
        return c == '1';
    }
};

/// Flatten path data `d`, mapping path units by `scale` and offsetting
/// by (ox, oy). `tol` is the flattening tolerance in output units.
pub fn flatten(d: []const u8, scale: f32, ox: f32, oy: f32, out: *Flat) !void {
    var p: Parser = .{ .s = d };
    var cx: f32 = 0; // current point (path units)
    var cy: f32 = 0;
    var sx: f32 = 0; // subpath start
    var sy: f32 = 0;
    var last_ctrl: ?[2]f32 = null; // for S/T reflection
    var last_cmd: u8 = 0;
    var cmd: u8 = 0;
    const T = struct {
        fn line(o: *Flat, k: f32, ax: f32, ay: f32, x0: f32, y0: f32, x1: f32, y1: f32) void {
            o.add(ax + x0 * k, ay + y0 * k, ax + x1 * k, ay + y1 * k);
        }
    };
    while (true) {
        p.skipSep();
        if (p.i >= p.s.len) break;
        const c = p.s[p.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            p.i += 1;
        } else if (cmd == 0) return error.BadPath;
        // implicit repeats: M becomes L, m becomes l
        const rel = std.ascii.isLower(cmd);
        const up = std.ascii.toUpper(cmd);
        const bx: f32 = if (rel) cx else 0;
        const by: f32 = if (rel) cy else 0;
        var ctrl: ?[2]f32 = null;
        switch (up) {
            'M' => {
                cx = bx + try p.number();
                cy = by + try p.number();
                sx = cx;
                sy = cy;
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = bx + try p.number();
                const y = by + try p.number();
                T.line(out, scale, ox, oy, cx, cy, x, y);
                cx = x;
                cy = y;
            },
            'H' => {
                const x = bx + try p.number();
                T.line(out, scale, ox, oy, cx, cy, x, cy);
                cx = x;
            },
            'V' => {
                const y = by + try p.number();
                T.line(out, scale, ox, oy, cx, cy, cx, y);
                cy = y;
            },
            'Z' => {
                T.line(out, scale, ox, oy, cx, cy, sx, sy);
                cx = sx;
                cy = sy;
                cmd = 0;
                last_cmd = 'Z';
                last_ctrl = null;
                // a number right after Z would be an error; a command is fine
                continue;
            },
            'C', 'S' => {
                var x1: f32 = undefined;
                var y1: f32 = undefined;
                if (up == 'C') {
                    x1 = bx + try p.number();
                    y1 = by + try p.number();
                } else if (last_ctrl != null and (last_cmd == 'C' or last_cmd == 'S')) {
                    x1 = 2 * cx - last_ctrl.?[0];
                    y1 = 2 * cy - last_ctrl.?[1];
                } else {
                    x1 = cx;
                    y1 = cy;
                }
                const x2 = bx + try p.number();
                const y2 = by + try p.number();
                const x = bx + try p.number();
                const y = by + try p.number();
                cubic(out, scale, ox, oy, cx, cy, x1, y1, x2, y2, x, y);
                ctrl = .{ x2, y2 };
                cx = x;
                cy = y;
            },
            'Q', 'T' => {
                var x1: f32 = undefined;
                var y1: f32 = undefined;
                if (up == 'Q') {
                    x1 = bx + try p.number();
                    y1 = by + try p.number();
                } else if (last_ctrl != null and (last_cmd == 'Q' or last_cmd == 'T')) {
                    x1 = 2 * cx - last_ctrl.?[0];
                    y1 = 2 * cy - last_ctrl.?[1];
                } else {
                    x1 = cx;
                    y1 = cy;
                }
                const x = bx + try p.number();
                const y = by + try p.number();
                // a quadratic is a cubic with these control points
                cubic(out, scale, ox, oy, cx, cy, cx + (x1 - cx) * 2 / 3, cy + (y1 - cy) * 2 / 3, x + (x1 - x) * 2 / 3, y + (y1 - y) * 2 / 3, x, y);
                ctrl = .{ x1, y1 };
                cx = x;
                cy = y;
            },
            'A' => {
                const rx = try p.number();
                const ry = try p.number();
                const rot = try p.number();
                const large = try p.flag();
                const sweep = try p.flag();
                const x = bx + try p.number();
                const y = by + try p.number();
                arc(out, scale, ox, oy, cx, cy, rx, ry, rot, large, sweep, x, y);
                cx = x;
                cy = y;
            },
            else => return error.BadPath,
        }
        last_cmd = up;
        last_ctrl = ctrl;
        if (!p.atNumber()) {
            // the next token is a command letter (or the end)
            p.skipSep();
            if (p.i < p.s.len and !std.ascii.isAlphabetic(p.s[p.i])) return error.BadPath;
        }
    }
}

fn cubic(out: *Flat, k: f32, ox: f32, oy: f32, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) void {
    // segments from the control polygon's length in output pixels
    const len = (dist(x0, y0, x1, y1) + dist(x1, y1, x2, y2) + dist(x2, y2, x3, y3)) * k;
    const n: usize = @intFromFloat(std.math.clamp(@ceil(len / 1.5), 2, 48));
    var px = x0;
    var py = y0;
    for (1..n + 1) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const u = 1 - t;
        const x = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3;
        const y = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3;
        out.add(ox + px * k, oy + py * k, ox + x * k, oy + y * k);
        px = x;
        py = y;
    }
}

fn dist(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    return @sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
}

/// SVG elliptical arc, endpoint parameterization (SVG 1.1 F.6.5).
fn arc(out: *Flat, k: f32, ox: f32, oy: f32, x0: f32, y0: f32, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, x1: f32, y1: f32) void {
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if ((x0 == x1 and y0 == y1)) return;
    if (rx == 0 or ry == 0) return out.add(ox + x0 * k, oy + y0 * k, ox + x1 * k, oy + y1 * k);
    const phi = rot_deg * std.math.pi / 180.0;
    const cphi = @cos(phi);
    const sphi = @sin(phi);
    const dx = (x0 - x1) / 2;
    const dy = (y0 - y1) / 2;
    const x1p = cphi * dx + sphi * dy;
    const y1p = -sphi * dx + cphi * dy;
    // scale up radii that cannot reach
    const lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) {
        rx *= @sqrt(lam);
        ry *= @sqrt(lam);
    }
    const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = if (den == 0) 0 else @sqrt(@max(0, num / den));
    if (large == sweep) co = -co;
    const cxp = co * rx * y1p / ry;
    const cyp = -co * ry * x1p / rx;
    const ccx = cphi * cxp - sphi * cyp + (x0 + x1) / 2;
    const ccy = sphi * cxp + cphi * cyp + (y0 + y1) / 2;
    const ang = struct {
        fn f(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
            return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        }
    }.f;
    const th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and dth > 0) dth -= 2 * std.math.pi;
    if (sweep and dth < 0) dth += 2 * std.math.pi;
    const len = @abs(dth) * @max(rx, ry) * k;
    const n: usize = @intFromFloat(std.math.clamp(@ceil(len / 1.5), 2, 64));
    var px = x0;
    var py = y0;
    for (1..n + 1) |i| {
        const t = th1 + dth * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        var x = ccx + rx * @cos(t) * cphi - ry * @sin(t) * sphi;
        var y = ccy + rx * @cos(t) * sphi + ry * @sin(t) * cphi;
        if (i == n) {
            x = x1;
            y = y1;
        }
        out.add(ox + px * k, oy + py * k, ox + x * k, oy + y * k);
        px = x;
        py = y;
    }
}

/// Stroke `segs` (output pixels) `width` px wide with round caps and joins
/// into `mask` (w x h, row-major), keeping the larger coverage per pixel.
pub fn stroke(mask: []u8, w: usize, h: usize, segs: []const Seg, width: f32) void {
    const half = @max(0.35, width / 2);
    for (segs) |s| {
        const x0 = @min(s[0], s[2]) - half - 1;
        const x1 = @max(s[0], s[2]) + half + 1;
        const y0 = @min(s[1], s[3]) - half - 1;
        const y1 = @max(s[1], s[3]) + half + 1;
        const ya: usize = @intFromFloat(std.math.clamp(@floor(y0), 0, @as(f32, @floatFromInt(h))));
        const yb: usize = @intFromFloat(std.math.clamp(@ceil(y1), 0, @as(f32, @floatFromInt(h))));
        const xa: usize = @intFromFloat(std.math.clamp(@floor(x0), 0, @as(f32, @floatFromInt(w))));
        const xb: usize = @intFromFloat(std.math.clamp(@ceil(x1), 0, @as(f32, @floatFromInt(w))));
        const abx = s[2] - s[0];
        const aby = s[3] - s[1];
        const ab2 = abx * abx + aby * aby;
        var y = ya;
        while (y < yb) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var x = xa;
            while (x < xb) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                var t: f32 = if (ab2 == 0) 0 else ((px - s[0]) * abx + (py - s[1]) * aby) / ab2;
                t = std.math.clamp(t, 0, 1);
                const ddx = px - (s[0] + abx * t);
                const ddy = py - (s[1] + aby * t);
                const d = @sqrt(ddx * ddx + ddy * ddy);
                // a stroke thinner than a pixel covers it partially
                const cov = std.math.clamp(half - d + 0.5, 0, 1) * @min(1.0, width);
                const v: u8 = @intFromFloat(@round(cov * 255));
                const m = &mask[y * w + x];
                if (v > m.*) m.* = v;
            }
        }
    }
}

/// Render path data `d` (in a `box`-unit square) stroked `stroke_units`
/// wide into a `size`x`size` mask.
pub fn rasterize(mask: []u8, size: usize, d: []const u8, box: f32, stroke_units: f32) !void {
    @memset(mask[0 .. size * size], 0);
    var flat: Flat = .{};
    const k = @as(f32, @floatFromInt(size)) / box;
    try flatten(d, k, 0, 0, &flat);
    stroke(mask, size, size, flat.slice(), stroke_units * k);
}

test "path commands, relative and absolute, flatten to the same lines" {
    var a: Flat = .{};
    var b: Flat = .{};
    try flatten("M4 6h16v12H4z", 1, 0, 0, &a);
    try flatten("M4 6L20 6L20 18L4 18Z", 1, 0, 0, &b);
    try std.testing.expectEqual(a.n, b.n);
    for (a.slice(), b.slice()) |x, y| for (x, y) |u, v| try std.testing.expectApproxEqAbs(u, v, 1e-4);
    // implicit lineto after moveto, packed numbers
    var c: Flat = .{};
    try flatten("m1 1 2 0-1.5.5", 1, 0, 0, &c);
    try std.testing.expectEqual(@as(usize, 2), c.n);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), c.segs[1][2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), c.segs[1][3], 1e-4);
    try std.testing.expectError(error.BadPath, flatten("M1 1 Q", 1, 0, 0, &c));
}

test "arcs end where they say and stay on the circle" {
    var f: Flat = .{};
    // two half circles of radius 8 around (12, 12)
    try flatten("M12 4a8 8 0 1 0 0 16a8 8 0 1 0 0-16z", 1, 0, 0, &f);
    try std.testing.expect(f.n > 8);
    for (f.slice()) |s| {
        const r = dist(12, 12, s[0], s[1]);
        try std.testing.expectApproxEqAbs(@as(f32, 8), r, 0.05);
    }
}

test "a stroked line covers its middle and not far off it" {
    var m: [24 * 24]u8 = undefined;
    try rasterize(&m, 24, "M4 12h16", 24, 2);
    try std.testing.expectEqual(@as(u8, 255), m[12 * 24 + 12]);
    try std.testing.expectEqual(@as(u8, 0), m[4 * 24 + 12]);
    // the dot of "h.01" with a round cap
    try rasterize(&m, 24, "M12 12h.01", 24, 3);
    try std.testing.expect(m[12 * 24 + 12] > 200);
}
