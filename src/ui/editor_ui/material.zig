//! The floating "Glass" material: a blurred, tinted copy of what lies
//! behind (cached per surface), a soft box shadow, a hairline edge, and
//! a snapshot used to fade whatever is drawn over it.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const effects = @import("../../gfx/effects.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;

/// Per-pane caches of one floating surface: its blurred backdrop and its
/// shadow mask. Rebuilt only when what lies behind it (or its size) changes.
pub const Backdrop = struct {
    rect: Rect = Rect.empty,
    hash: u64 = 0,
    /// the material over the blurred backdrop, r.w x r.h
    px: []u32 = &.{},
    /// scratch: what lies behind, composed each frame to see if it changed
    src: []u32 = &.{},
    sh_key: [6]i32 = @splat(0),
    sh_mask: []u8 = &.{},
    /// the pane's content generation when `src` was last composed
    gen: u64 = 0,

    pub fn release(self: *Backdrop, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
        alloc.free(self.src);
        alloc.free(self.sh_mask);
        self.* = .{};
    }
};

pub const Slot = enum(u3) { bar, panel, popover, picker, help, notice };
pub const n_slots = @typeInfo(Slot).@"enum".field_names.len;

/// What a floating surface with `sh` covers: itself plus its shadow.
pub fn shadowFootprint(self: *const Editor, r: Rect, sh: theme.Shadow) Rect {
    const b = self.sc(sh.blur);
    const dy = self.sc(sh.dy);
    return .{ .x = r.x - b, .y = r.y - b + @min(0, dy), .w = r.w + 2 * b, .h = r.h + 2 * b + @as(i32, @intCast(@abs(dy))) };
}

/// Signed-distance coverage of pixel (x, y) by a rounded rectangle.
inline fn roundCov(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r: f64) f64 {
    const qx = @max(@max(x0 + r - px, px - (x1 - r)), 0.0);
    const qy = @max(@max(y0 + r - py, py - (y1 - r)), 0.0);
    const d = if (qx == 0 and qy == 0) @max(@max(x0 - px, px - x1), @max(y0 - py, py - y1)) else @sqrt(qx * qx + qy * qy) - r;
    return d;
}

/// The pixels behind `r`, blurred and a little more saturated; cached
/// while they stay the same.
fn backdrop(self: *Editor, slot: Slot, r: Rect) ?[]const u32 {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    const rad: i32 = @max(2, self.sc(theme.backdrop_blur));
    const scr = self.screenRect();
    const src = Rect.intersect(r.expand(rad * 2), scr) orelse return null;
    const need: usize = @intCast(r.w * r.h);
    // nothing behind changed since last time: no need to even look
    if (bd.gen == self.pn().gen and bd.hash != 0 and Rect.eql(bd.rect, r) and bd.px.len == need) return bd.px;
    bd.gen = self.pn().gen;
    const scratch = composeBehind(self, bd, src) orelse return null;
    const hash = behindHash(self, scratch, r, src);
    if (bd.hash == hash and bd.px.len == need and Rect.eql(bd.rect, r)) return bd.px;

    // blur at half resolution: cheaper, and nobody can tell
    const sw: usize = @intCast(@divTrunc(src.w + 1, 2));
    const sh: usize = @intCast(@divTrunc(src.h + 1, 2));
    const small = self.alloc.alloc(u32, sw * sh) catch return null;
    defer self.alloc.free(small);
    halve(scratch, @intCast(src.w), @intCast(src.h), small, sw, sh);
    effects.softBlur(self.alloc, small, @intCast(sw), @intCast(sh), .{ .x = 0, .y = 0, .w = @intCast(sw), .h = @intCast(sh) }, @intCast(@max(1, @divTrunc(rad, 2)))) catch return null;

    if (bd.px.len != need) {
        self.alloc.free(bd.px);
        bd.px = &.{};
        bd.px = self.alloc.alloc(u32, need) catch return null;
    }
    // saturate a little, like vibrancy, and tint with the material, at
    // the small size; then scale up
    for (small) |*p| p.* = Canvas.blendPixel(saturate(p.*), self.theme.material);
    upscale(small, sw, sh, bd.px, r, src);
    bd.rect = r;
    bd.hash = hash;
    return bd.px;
}

/// Compose what lies behind `src` into the pane's scratch buffer (grown
/// as needed).
fn composeBehind(self: *Editor, bd: *Backdrop, src: Rect) ?[]u32 {
    const n: usize = @intCast(src.w * src.h);
    if (bd.src.len < n) {
        self.alloc.free(bd.src);
        bd.src = &.{};
        bd.src = self.alloc.alloc(u32, n) catch return null;
    }
    const scratch = bd.src[0..n];
    self.composeRegionTo(scratch, @intCast(src.w), .{ .x = src.x, .y = src.y }, src);
    return scratch;
}

/// Identifies a backdrop: the pixels behind, the geometry and the tint.
fn behindHash(self: *const Editor, scratch: []const u32, r: Rect, src: Rect) u64 {
    var hasher = std.hash.Wyhash.init(0x5107);
    hasher.update(std.mem.sliceAsBytes(scratch));
    hasher.update(std.mem.asBytes(&r));
    hasher.update(std.mem.asBytes(&src));
    hasher.update(std.mem.asBytes(&self.theme.material));
    return hasher.final();
}

/// Box-filter `src` (srcw x srch) down to half size into `small`.
fn halve(src: []const u32, srcw: usize, srch: usize, small: []u32, sw: usize, sh: usize) void {
    for (0..sh) |y| for (0..sw) |x| {
        var acc: [3]u32 = .{ 0, 0, 0 };
        for (0..2) |dy| for (0..2) |dx| {
            const p = src[@min(srch - 1, y * 2 + dy) * srcw + @min(srcw - 1, x * 2 + dx)];
            acc[0] += (p >> 16) & 0xFF;
            acc[1] += (p >> 8) & 0xFF;
            acc[2] += p & 0xFF;
        };
        small[y * sw + x] = 0xFF000000 | ((acc[0] / 4) << 16) | ((acc[1] / 4) << 8) | (acc[2] / 4);
    };
}

/// Push a colour away from its luminance by 346/256, like vibrancy.
inline fn saturate(p: u32) u32 {
    const cr: i32 = @intCast((p >> 16) & 0xFF);
    const cg: i32 = @intCast((p >> 8) & 0xFF);
    const cb: i32 = @intCast(p & 0xFF);
    const lum = @divTrunc(54 * cr + 183 * cg + 19 * cb, 256);
    var out: u32 = 0xFF000000;
    inline for (.{ cr, cg, cb }, 0..) |cc, k| {
        const v = std.math.clamp(lum + @divTrunc((cc - lum) * 346, 256), 0, 255);
        out |= @as(u32, @intCast(v)) << @intCast(16 - 8 * k);
    }
    return out;
}

/// Scale the half-size `small` up into `out` (r.w x r.h, bilinear in
/// 8-bit fixed point); `src` is the area `small` was made from.
fn upscale(small: []const u32, sw: usize, sh: usize, out: []u32, r: Rect, src: Rect) void {
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |y| {
        // source position in 1/256ths of a small pixel
        const fy = std.math.clamp(@as(i32, @intCast(y)) * 128 + (r.y - src.y) * 128 - 64, 0, @as(i32, @intCast(sh - 1)) * 256);
        const y0: usize = @intCast(@divTrunc(fy, 256));
        const y1 = @min(sh - 1, y0 + 1);
        const ty: u32 = @intCast(@mod(fy, 256));
        const row0 = small[y0 * sw ..][0..sw];
        const row1 = small[y1 * sw ..][0..sw];
        for (0..rw) |x| {
            const fx = std.math.clamp(@as(i32, @intCast(x)) * 128 + (r.x - src.x) * 128 - 64, 0, @as(i32, @intCast(sw - 1)) * 256);
            const x0: usize = @intCast(@divTrunc(fx, 256));
            const x1 = @min(sw - 1, x0 + 1);
            const tx: u32 = @intCast(@mod(fx, 256));
            out[y * rw + x] = bilerp(row0[x0], row0[x1], row1[x0], row1[x1], tx, ty);
        }
    }
}

inline fn bilerp(a: u32, b: u32, c: u32, d: u32, tx: u32, ty: u32) u32 {
    var out: u32 = 0xFF000000;
    inline for (.{ 16, 8, 0 }) |sh_| {
        const top = ((a >> sh_) & 0xFF) * (256 - tx) + ((b >> sh_) & 0xFF) * tx;
        const bot = ((c >> sh_) & 0xFF) * (256 - tx) + ((d >> sh_) & 0xFF) * tx;
        out |= (((top * (256 - ty) + bot * ty) >> 16) & 0xFF) << sh_;
    }
    return out;
}

/// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
fn erf(x: f64) f64 {
    const s: f64 = if (x < 0) -1 else 1;
    const a = @abs(x);
    const t = 1.0 / (1.0 + 0.3275911 * a);
    const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-a * a);
    return s * y;
}

/// A CSS-like box shadow around the rounded rect `r`, outside it only
/// (the material is translucent: no shadow shows through it).
fn drawShadow(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow, alpha: f64) void {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    const b = self.sc(sh.blur);
    const dy = self.sc(sh.dy);
    const fr = shadowFootprint(self, r, sh);
    const key = [6]i32{ r.w, r.h, @intFromFloat(radius * 16), b, dy, 1 };
    const n: usize = @intCast(fr.w * fr.h);
    if (!std.mem.eql(i32, &key, &bd.sh_key) or bd.sh_mask.len != n) {
        self.alloc.free(bd.sh_mask);
        bd.sh_mask = &.{};
        bd.sh_mask = self.alloc.alloc(u8, n) catch return;
        bd.sh_key = key;
        shadowMask(bd.sh_mask, r, fr, radius, @max(0.5, ff(b) / 2.0), dy);
    }
    const ca: u32 = @intFromFloat(@round(ff(@intCast(sh.color >> 24)) * alpha));
    blendShadow(canvas, bd.sh_mask, fr, ca, sh.color & 0x00FFFFFF);
}

/// The shadow's coverage over its footprint `fr`: a Gaussian (sigma)
/// falloff of the rect offset by `dy`, zero inside the rect itself.
fn shadowMask(mask: []u8, r: Rect, fr: Rect, radius: f64, sigma: f64, dy: i32) void {
    // in mask coordinates
    const x0 = ff(r.x - fr.x);
    const y0 = ff(r.y - fr.y);
    const x1 = x0 + ff(r.w);
    const y1 = y0 + ff(r.h);
    const fdy = ff(dy);
    const inv = 1.0 / (sigma * std.math.sqrt2);
    for (0..@intCast(fr.h)) |yy| for (0..@intCast(fr.w)) |xx| {
        const px = ff(@intCast(xx)) + 0.5;
        const py = ff(@intCast(yy)) + 0.5;
        const inside = roundCov(px, py, x0, y0, x1, y1, radius);
        if (inside < -0.5) {
            mask[yy * @as(usize, @intCast(fr.w)) + xx] = 0;
            continue;
        }
        const d = roundCov(px, py - fdy, x0, y0, x1, y1, radius);
        var a = 0.5 * (1.0 - erf(d * inv));
        // fade into the edge of the material itself
        if (inside < 0.5) a *= inside + 0.5;
        mask[yy * @as(usize, @intCast(fr.w)) + xx] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
    };
}

/// Blend colour `rgb` at alpha `ca` through `mask` onto the canvas.
fn blendShadow(canvas: *Canvas, mask: []const u8, fr: Rect, ca: u32, rgb: u32) void {
    const fw: usize = @intCast(fr.w);
    const xa: usize = @intCast(@max(0, -fr.x));
    const xb: usize = @intCast(std.math.clamp(canvas.w - fr.x, 0, fr.w));
    const cw: usize = @intCast(canvas.w);
    for (0..@intCast(fr.h)) |yy| {
        const y = fr.y + @as(i32, @intCast(yy));
        if (y < 0 or y >= canvas.h) continue;
        const row = canvas.px[@as(usize, @intCast(y)) * cw ..];
        const mrow = mask[yy * fw ..][0..fw];
        if (rgb == 0) {
            // black: darken by the coverage, two multiplies a pixel
            for (xa..xb) |xx| {
                const m: u32 = mrow[xx];
                if (m == 0) continue;
                const keep = 256 - ((ca * m + 127) >> 8);
                const i: usize = @intCast(fr.x + @as(i32, @intCast(xx)));
                const p = row[i];
                row[i] = 0xFF000000 | (((p & 0xFF00FF) * keep >> 8) & 0xFF00FF) | (((p & 0x00FF00) * keep >> 8) & 0x00FF00);
            }
            continue;
        }
        for (xa..xb) |xx| {
            const m: u32 = mrow[xx];
            if (m == 0) continue;
            const a = (ca * m + 127) / 255;
            if (a == 0) continue;
            const i: usize = @intCast(fr.x + @as(i32, @intCast(xx)));
            row[i] = Canvas.blendPixel(row[i], rgb | (a << 24));
        }
    }
}

/// The floating material: shadow, the tinted blurred backdrop clipped to
/// the rounded rect, and a hairline edge.
pub fn drawMaterial(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow) void {
    if (r.w <= 0 or r.h <= 0) return;
    const th = self.theme;
    drawShadow(self, canvas, slot, r, radius, sh, 1);
    if (backdrop(self, slot, r)) |bdp| {
        blitRoundRect(canvas, bdp, r, radius);
    } else canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, th.material);
    // 0.5 px hairline: one pixel at half strength on a 1x screen
    hairline(canvas, r, radius, theme.fade(th.hairline, @min(1.0, 0.5 * self.uf())));
}

/// Copy `src` (r.w x r.h) into `r` with rounded, anti-aliased corners.
fn blitRoundRect(canvas: *Canvas, src: []const u32, r: Rect, radius: f64) void {
    const c = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    const rw: usize = @intCast(r.w);
    const cw: usize = @intCast(canvas.w);
    const band: i32 = @intFromFloat(@ceil(radius));
    const x0 = ff(r.x);
    const y0 = ff(r.y);
    const x1 = x0 + ff(r.w);
    const y1 = y0 + ff(r.h);
    var y = c.y;
    while (y < c.bottom()) : (y += 1) {
        const sy: usize = @intCast(y - r.y);
        const srow = src[sy * rw ..][0..rw];
        const drow = canvas.px[@as(usize, @intCast(y)) * cw ..][0..cw];
        const corner_row = y < r.y + band or y >= r.bottom() - band;
        // the straight middle: a plain copy
        const ma = if (corner_row) @max(c.x, r.x + band) else c.x;
        const mb = if (corner_row) @min(c.right(), r.right() - band) else c.right();
        if (mb > ma) @memcpy(drow[@intCast(ma)..@intCast(mb)], srow[@intCast(ma - r.x)..@intCast(mb - r.x)]);
        if (!corner_row) continue;
        for ([2][2]i32{ .{ c.x, @min(ma, c.right()) }, .{ @max(mb, c.x), c.right() } }) |span| {
            var x = span[0];
            while (x < span[1]) : (x += 1) {
                const d = roundCov(ff(x) + 0.5, ff(y) + 0.5, x0, y0, x1, y1, radius);
                const cov = std.math.clamp(0.5 - d, 0, 1);
                if (cov <= 0) continue;
                const a: u32 = @intFromFloat(@round(cov * 255));
                const p = srow[@intCast(x - r.x)];
                drow[@intCast(x)] = Canvas.blendPixel(drow[@intCast(x)], (p & 0x00FFFFFF) | (a << 24));
            }
        }
    }
}

/// A one-pixel line just inside the rounded rect `r`.
fn hairline(canvas: *Canvas, r: Rect, radius: f64, color: u32) void {
    const rad: i32 = @intFromFloat(@ceil(radius));
    canvas.fillRect(r.x + rad, r.y, r.w - 2 * rad, 1, color);
    canvas.fillRect(r.x + rad, r.bottom() - 1, r.w - 2 * rad, 1, color);
    canvas.fillRect(r.x, r.y + rad, 1, r.h - 2 * rad, color);
    canvas.fillRect(r.right() - 1, r.y + rad, 1, r.h - 2 * rad, color);
    // the corners: a ring of radius - 0.5 around each corner's centre
    const corners = [4][4]f64{
        .{ ff(r.x) + radius, ff(r.y) + radius, -1, -1 },
        .{ ff(r.right()) - radius, ff(r.y) + radius, 1, -1 },
        .{ ff(r.x) + radius, ff(r.bottom()) - radius, -1, 1 },
        .{ ff(r.right()) - radius, ff(r.bottom()) - radius, 1, 1 },
    };
    const ca = ff(@intCast(color >> 24));
    for (corners) |k| {
        const bx: i32 = if (k[2] < 0) r.x else r.right() - rad;
        const by: i32 = if (k[3] < 0) r.y else r.bottom() - rad;
        var y = by;
        while (y < by + rad) : (y += 1) {
            var x = bx;
            while (x < bx + rad) : (x += 1) {
                const dx = ff(x) + 0.5 - k[0];
                const dy = ff(y) + 0.5 - k[1];
                const d = @sqrt(dx * dx + dy * dy);
                const cov = std.math.clamp(1.0 - @abs(d - (radius - 0.5)), 0, 1);
                if (cov <= 0) continue;
                canvas.blend(x, y, (color & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(ca * cov))) << 24));
            }
        }
    }
}

/// Opacity for whatever is drawn between snapshot and restore: keeps a
/// copy of `r`, and mixes it back in afterwards.
pub const Snapshot = struct {
    r: Rect,
    px: []u32,
    pub fn take(alloc: std.mem.Allocator, canvas: *Canvas, r_in: Rect) ?Snapshot {
        const r = Rect.intersect(r_in, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return null;
        const px = alloc.alloc(u32, @intCast(r.w * r.h)) catch return null;
        const rw: usize = @intCast(r.w);
        for (0..@intCast(r.h)) |yy| {
            const off = @as(usize, @intCast(r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(r.x));
            @memcpy(px[yy * rw ..][0..rw], canvas.px[off..][0..rw]);
        }
        return .{ .r = r, .px = px };
    }
    pub fn restore(self: Snapshot, alloc: std.mem.Allocator, canvas: *Canvas, alpha: f64) void {
        defer alloc.free(self.px);
        if (alpha >= 1) return;
        const k: u32 = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 256));
        const rw: usize = @intCast(self.r.w);
        for (0..@intCast(self.r.h)) |yy| {
            const off = @as(usize, @intCast(self.r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(self.r.x));
            for (canvas.px[off..][0..rw], self.px[yy * rw ..][0..rw]) |*d, old| {
                const rb = ((d.* & 0xFF00FF) * k + (old & 0xFF00FF) * (256 - k)) >> 8;
                const g = ((d.* & 0x00FF00) * k + (old & 0x00FF00) * (256 - k)) >> 8;
                d.* = 0xFF000000 | (rb & 0xFF00FF) | (g & 0x00FF00);
            }
        }
    }
};
