//! glyf/loca: TrueType quadratic outlines, simple and composite, decoded
//! into a Path.

const std = @import("std");
const bytes = @import("bytes.zig");
const Path = @import("path.zig").Path;
const beU16 = bytes.beU16;
const beI16 = bytes.beI16;
const beU32 = bytes.beU32;

const max_depth = 6;

pub const OutlineError = error{ OutOfMemory, BadGlyph };

const Pt = struct { x: f64, y: f64, on: bool };

/// The glyf and loca tables of one face.
pub const Glyf = struct {
    alloc: std.mem.Allocator,
    glyf: []const u8,
    loca: []const u8,
    long_loca: bool,
    num_glyphs: u16,

    fn glyphData(self: Glyf, gid: u16) ?[]const u8 {
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

    /// Append the glyph outline (flattened, transformed) into `path`.
    /// Handles composites recursively with depth and component budgets.
    pub fn outline(self: Glyf, gid: u16, xform: [6]f64, depth: u8, budget: *u32, path: *Path) OutlineError!void {
        if (depth > max_depth) return error.BadGlyph;
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

    fn composite(self: Glyf, g: []const u8, xform: [6]f64, depth: u8, budget: *u32, path: *Path) OutlineError!void {
        var off: usize = 10;
        while (true) {
            const flags = beU16(g, off) catch return error.BadGlyph;
            const comp_gid = beU16(g, off + 2) catch return error.BadGlyph;
            off += 4;
            const d = try componentOffset(g, &off, flags);
            const s = try componentScale(g, &off, flags);
            try self.outline(comp_gid, compose(xform, s, d), depth + 1, budget, path);
            if (flags & 0x0020 == 0) break; // no more components
        }
    }

    fn simple(self: Glyf, g: []const u8, nc: usize, path: *Path) !void {
        const ends_base: usize = 10;
        const n_points = try pointCount(g, nc);
        var off: usize = ends_base + nc * 2;
        const ins_len = try beU16(g, off);
        off += 2 + @as(usize, ins_len);

        const flags = try self.alloc.alloc(u8, n_points);
        defer self.alloc.free(flags);
        try decodeFlags(g, &off, flags);

        const pts = try self.alloc.alloc(Pt, n_points);
        defer self.alloc.free(pts);
        var x: i32 = 0;
        for (flags, pts) |fl, *p| {
            x += try coordDelta(g, &off, fl, 0x02, 0x10);
            p.* = .{ .x = @floatFromInt(x), .y = 0, .on = fl & 0x01 != 0 };
        }
        var y: i32 = 0;
        for (flags, pts) |fl, *p| {
            y += try coordDelta(g, &off, fl, 0x04, 0x20);
            p.y = @floatFromInt(y);
        }

        var start: usize = 0;
        for (0..nc) |ci| {
            const contour_end: usize = try beU16(g, ends_base + ci * 2);
            const cpts = pts[start .. contour_end + 1];
            start = contour_end + 1;
            if (cpts.len < 2) continue;
            try emitContour(cpts, path);
        }
    }
};

/// Point count of a simple glyph; endPtsOfContours must increase strictly.
fn pointCount(g: []const u8, nc: usize) !usize {
    var prev: i32 = -1;
    for (0..nc) |ci| {
        const e: i32 = try beU16(g, 10 + ci * 2);
        if (e <= prev) return error.BadGlyph;
        prev = e;
    }
    return @as(usize, @intCast(prev)) + 1;
}

/// Expand the run-length coded flag array into `flags`.
fn decodeFlags(g: []const u8, off: *usize, flags: []u8) error{BadGlyph}!void {
    const n_points = flags.len;
    var fi: usize = 0;
    while (fi < n_points) {
        if (off.* >= g.len) return error.BadGlyph;
        const fl = g[off.*];
        off.* += 1;
        flags[fi] = fl;
        fi += 1;
        if (fl & 0x08 != 0) {
            if (off.* >= g.len) return error.BadGlyph;
            var rep = g[off.*];
            off.* += 1;
            while (rep > 0 and fi < n_points) : (rep -= 1) {
                flags[fi] = fl;
                fi += 1;
            }
        }
    }
}

/// One x or y delta: a signed byte (`short`; `same` is the sign), zero
/// (`same` without `short`), or a big-endian i16.
inline fn coordDelta(g: []const u8, off: *usize, fl: u8, comptime short: u8, comptime same: u8) !i32 {
    if (fl & short != 0) {
        if (off.* >= g.len) return error.BadGlyph;
        const v: i32 = g[off.*];
        off.* += 1;
        return if (fl & same != 0) v else -v;
    } else if (fl & same == 0) {
        const v = try beI16(g, off.*);
        off.* += 2;
        return v;
    }
    return 0;
}

/// A component's (dx, dy); point-matching anchors are unsupported (0, 0).
fn componentOffset(g: []const u8, off: *usize, flags: u16) error{BadGlyph}![2]f64 {
    var d: [2]f64 = .{ 0, 0 };
    if (flags & 0x0001 != 0) { // words
        const a = beI16(g, off.*) catch return error.BadGlyph;
        const b = beI16(g, off.* + 2) catch return error.BadGlyph;
        if (flags & 0x0002 != 0) { // xy values (else: point matching, unsupported)
            d = .{ @floatFromInt(a), @floatFromInt(b) };
        }
        off.* += 4;
    } else {
        const ab = bytes.sub(g, off.*, 2) orelse return error.BadGlyph;
        if (flags & 0x0002 != 0) {
            d = .{ @floatFromInt(@as(i8, @bitCast(ab[0]))), @floatFromInt(@as(i8, @bitCast(ab[1]))) };
        }
        off.* += 2;
    }
    return d;
}

/// A component's 2x2 matrix (a, b, c, d); identity when absent.
fn componentScale(g: []const u8, off: *usize, flags: u16) error{BadGlyph}![4]f64 {
    var s: [4]f64 = .{ 1, 0, 0, 1 };
    if (flags & 0x0008 != 0) { // single scale
        s[0] = try f2dot14(g, off.*);
        s[3] = s[0];
        off.* += 2;
    } else if (flags & 0x0040 != 0) { // x and y scale
        s[0] = try f2dot14(g, off.*);
        s[3] = try f2dot14(g, off.* + 2);
        off.* += 4;
    } else if (flags & 0x0080 != 0) { // 2x2
        s[0] = try f2dot14(g, off.*);
        s[1] = try f2dot14(g, off.* + 2);
        s[2] = try f2dot14(g, off.* + 4);
        s[3] = try f2dot14(g, off.* + 6);
        off.* += 8;
    }
    return s;
}

/// Compose child -> (a,b,c,d,dx,dy) -> xform.
fn compose(xform: [6]f64, s: [4]f64, d: [2]f64) [6]f64 {
    const a, const b, const c, const e = s;
    const dx, const dy = d;
    return .{
        xform[0] * a + xform[2] * b,
        xform[1] * a + xform[3] * b,
        xform[0] * c + xform[2] * e,
        xform[1] * c + xform[3] * e,
        xform[0] * dx + xform[2] * dy + xform[4],
        xform[1] * dx + xform[3] * dy + xform[5],
    };
}

fn f2dot14(d: []const u8, off: usize) error{BadGlyph}!f64 {
    const v = beI16(d, off) catch return error.BadGlyph;
    return @as(f64, @floatFromInt(v)) / 16384.0;
}

/// Flatten one contour (mix of on/off curve points) into the path.
fn emitContour(cpts: []const Pt, path: *Path) !void {
    const n = cpts.len;
    // find first on-curve point (or synthesize midpoint)
    var first: Pt = undefined;
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
    var pending_off: ?Pt = null;
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
