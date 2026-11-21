//! Annotation shape model and rendering: geometry, tools, palette, the
//! shape painter, hit testing and handles.
//!
//! Shapes live in image pixels. `drawShape` paints one through an `Xform`
//! (image -> canvas), so the same code renders the native-resolution
//! export layer and the scaled on-screen preview.

const std = @import("std");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const bidi = @import("../gfx/bidi.zig");
const utf8 = @import("../gfx/utf8.zig");
const textbox = @import("textbox.zig");

const Canvas = render.Canvas;

pub const Tool = enum {
    select,
    pen,
    line,
    arrow,
    rect,
    ellipse,
    highlight,
    blur,
    pixelate,
    redact,
    counter,
    text,

    /// Tools that hide what is under them.
    pub fn isRedaction(self: Tool) bool {
        return self == .blur or self == .pixelate or self == .redact;
    }
};

pub const Point = struct { x: i32, y: i32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
    pub fn normalized(self: Rect) Rect {
        var r = self;
        if (r.w < 0) {
            r.x += r.w;
            r.w = -r.w;
        }
        if (r.h < 0) {
            r.y += r.h;
            r.h = -r.h;
        }
        return r;
    }
    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
    pub fn fromCorners(a: Point, b: Point) Rect {
        return (Rect{ .x = a.x, .y = a.y, .w = b.x - a.x, .h = b.y - a.y }).normalized();
    }
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    /// Bounding box of both; an empty rect is ignored.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.right(), b.right());
        const y1 = @max(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    pub fn expand(self: Rect, d: i32) Rect {
        return .{ .x = self.x - d, .y = self.y - d, .w = self.w + 2 * d, .h = self.h + 2 * d };
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

/// Maps shape (image) coordinates onto a canvas: c = p * scale + o.
pub const Xform = struct {
    scale: f64 = 1.0,
    ox: f64 = 0,
    oy: f64 = 0,

    pub fn fx(self: Xform, x: i32) f64 {
        return @as(f64, @floatFromInt(x)) * self.scale + self.ox;
    }
    pub fn fy(self: Xform, y: i32) f64 {
        return @as(f64, @floatFromInt(y)) * self.scale + self.oy;
    }
    pub fn pt(self: Xform, p: Point) Point {
        return .{ .x = @intFromFloat(@round(self.fx(p.x))), .y = @intFromFloat(@round(self.fy(p.y))) };
    }
    pub fn rect(self: Xform, r: Rect) Rect {
        const x0: i32 = @intFromFloat(@round(self.fx(r.x)));
        const y0: i32 = @intFromFloat(@round(self.fy(r.y)));
        const x1: i32 = @intFromFloat(@round(self.fx(r.x + r.w)));
        const y1: i32 = @intFromFloat(@round(self.fy(r.y + r.h)));
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

pub const Shape = struct {
    tool: Tool,
    color: u32,
    /// stroke width in image pixels; also sets text size, badge size and
    /// redaction strength
    thickness: i32,
    p0: Point = .{ .x = 0, .y = 0 },
    p1: Point = .{ .x = 0, .y = 0 },
    points: std.ArrayList(Point) = .empty,
    number: u32 = 0,
    str: std.ArrayList(u8) = .empty,
    /// rect/ellipse: solid fill instead of an outline
    filled: bool = false,
    /// rect: rounded corners
    rounded: bool = false,
    /// text: coloured rounded background behind the text
    pill: bool = false,
    /// text: fixed box width in image pixels, lines wrap to it; 0 = as
    /// wide as the longest line
    box_w: i32 = 0,

    pub fn deinit(self: *Shape, alloc: std.mem.Allocator) void {
        self.points.deinit(alloc);
        self.str.deinit(alloc);
    }

    pub fn clone(self: *const Shape, alloc: std.mem.Allocator) !Shape {
        var c = self.*;
        c.points = .empty;
        c.str = .empty;
        errdefer c.deinit(alloc);
        try c.points.appendSlice(alloc, self.points.items);
        try c.str.appendSlice(alloc, self.str.items);
        return c;
    }

    pub fn translate(self: *Shape, dx: i32, dy: i32) void {
        self.p0.x += dx;
        self.p0.y += dy;
        self.p1.x += dx;
        self.p1.y += dy;
        for (self.points.items) |*p| {
            p.x += dx;
            p.y += dy;
        }
    }

    fn th(self: *const Shape) f64 {
        return @floatFromInt(@max(1, self.thickness));
    }

    pub fn fontPx(self: *const Shape) f64 {
        return textFontPx(self.thickness);
    }

    pub fn counterRadius(self: *const Shape) f64 {
        return 8.0 + self.th() * 2.0;
    }

    fn arrowHead(self: *const Shape) f64 {
        return @max(10.0, self.th() * 3.5 + 4.0);
    }

    pub fn cornerRadius(self: *const Shape) f64 {
        return 6.0 + self.th() * 2.0;
    }

    pub fn blurRadius(self: *const Shape) u32 {
        return @intCast(@max(8, self.thickness * 3));
    }

    pub fn pixelBlock(self: *const Shape) i32 {
        return @max(8, 6 + self.thickness * 3);
    }

    fn pillPad(self: *const Shape) i32 {
        return @intFromFloat(@round(self.fontPx() * 0.3));
    }

    /// How far the text's frame extends past its text box.
    pub fn textPad(self: *const Shape) i32 {
        return if (self.pill) self.pillPad() else 0;
    }

    /// Whether the text box hugs the right edge (its first paragraph is
    /// right-to-left), so its width handle is on the left.
    pub fn textRtl(self: *const Shape) bool {
        const s = self.str.items;
        return textbox.paragraphRtl(s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len]);
    }

    /// The box handles edit: corners for boxes, the text block, the badge.
    pub fn frame(self: *const Shape) Rect {
        switch (self.tool) {
            .pen, .highlight => {
                if (self.points.items.len == 0) return .empty;
                var r = Rect{ .x = self.points.items[0].x, .y = self.points.items[0].y, .w = 0, .h = 0 };
                for (self.points.items[1..]) |p| {
                    const x1 = @max(r.right(), p.x);
                    const y1 = @max(r.bottom(), p.y);
                    r.x = @min(r.x, p.x);
                    r.y = @min(r.y, p.y);
                    r.w = x1 - r.x;
                    r.h = y1 - r.y;
                }
                return r;
            },
            .counter => {
                const r: i32 = @intFromFloat(@ceil(self.counterRadius()));
                return .{ .x = self.p0.x - r, .y = self.p0.y - r, .w = 2 * r, .h = 2 * r };
            },
            .text => {
                const wh = textbox.size(self.str.items, self.fontPx(), self.box_w);
                return (Rect{ .x = self.p0.x, .y = self.p0.y, .w = wh[0], .h = wh[1] }).expand(self.textPad());
            },
            else => return Rect.fromCorners(self.p0, self.p1),
        }
    }

    /// Every image pixel the shape may touch (stroke width included).
    pub fn bounds(self: *const Shape) Rect {
        const f = self.frame();
        const half: i32 = @as(i32, @intFromFloat(@ceil(self.th() / 2.0))) + 2;
        return switch (self.tool) {
            .pen, .line => f.expand(half),
            .highlight => f.expand(@as(i32, @intFromFloat(@ceil(self.th() * 1.5))) + 2),
            .arrow => f.expand(@as(i32, @intFromFloat(@ceil(self.arrowHead()))) + half),
            .rect, .ellipse => f.expand(2),
            .counter => f.expand(3),
            .text => f.expand(2),
            .blur, .pixelate, .redact, .select => f,
        };
    }

    /// How far outside `bounds` drawing this shape reads pixels.
    pub fn readMargin(self: *const Shape) i32 {
        return switch (self.tool) {
            .blur => @intCast(self.blurRadius() * 3 + 2),
            .pixelate => self.pixelBlock(),
            else => 0,
        };
    }

    /// Is image point `p` on the shape, within `tol` image pixels?
    pub fn hitTest(self: *const Shape, p: Point, tol: f64) bool {
        const half = self.th() / 2.0;
        switch (self.tool) {
            .pen, .highlight => {
                const w = if (self.tool == .highlight) half * 3.0 else half;
                const pts = self.points.items;
                if (pts.len == 0) return false;
                if (pts.len == 1) return segDist(p, pts[0], pts[0]) <= w + tol;
                var i: usize = 0;
                while (i + 1 < pts.len) : (i += 1) {
                    if (segDist(p, pts[i], pts[i + 1]) <= w + tol) return true;
                }
                return false;
            },
            .line, .arrow => return segDist(p, self.p0, self.p1) <= half + tol,
            .rect => {
                const r = self.frame();
                const t: i32 = @intFromFloat(@ceil(tol));
                if (!r.expand(t).contains(p.x, p.y)) return false;
                if (self.filled) return true;
                const inner = r.expand(-(@max(1, self.thickness) + t));
                return inner.isEmpty() or !inner.contains(p.x, p.y);
            },
            .ellipse => {
                const r = self.frame();
                const rx = @max(1.0, @as(f64, @floatFromInt(r.w)) / 2.0);
                const ry = @max(1.0, @as(f64, @floatFromInt(r.h)) / 2.0);
                const dx = @as(f64, @floatFromInt(p.x)) - (@as(f64, @floatFromInt(r.x)) + rx);
                const dy = @as(f64, @floatFromInt(p.y)) - (@as(f64, @floatFromInt(r.y)) + ry);
                const f = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) - 1.0;
                const gx = 2.0 * dx / (rx * rx);
                const gy = 2.0 * dy / (ry * ry);
                const g = @max(1e-9, @sqrt(gx * gx + gy * gy));
                const d = f / g;
                if (self.filled) return d <= tol;
                return @abs(d) <= half + tol;
            },
            .counter => {
                const dx: f64 = @floatFromInt(p.x - self.p0.x);
                const dy: f64 = @floatFromInt(p.y - self.p0.y);
                return @sqrt(dx * dx + dy * dy) <= self.counterRadius() + tol;
            },
            .text, .blur, .pixelate, .redact => {
                const t: i32 = @intFromFloat(@ceil(tol));
                return self.frame().expand(t).contains(p.x, p.y);
            },
            .select => return false,
        }
    }

    pub const HandleKind = enum { none, endpoints, box };

    pub fn handleKind(self: *const Shape) HandleKind {
        return switch (self.tool) {
            .line, .arrow => .endpoints,
            .counter, .text, .select => .none,
            else => .box,
        };
    }

    /// Fit the shape to `to`, scaling from `orig` (an unmodified copy).
    pub fn setFrame(self: *Shape, orig: *const Shape, to: Rect) void {
        const of = orig.frame();
        switch (self.tool) {
            .pen, .highlight => {
                for (self.points.items, orig.points.items) |*p, o| {
                    p.x = to.x + scaleOffset(o.x - of.x, of.w, to.w);
                    p.y = to.y + scaleOffset(o.y - of.y, of.h, to.h);
                }
            },
            else => {
                self.p0 = .{ .x = to.x, .y = to.y };
                self.p1 = .{ .x = to.x + to.w, .y = to.y + to.h };
            },
        }
    }
};

fn scaleOffset(v: i32, from: i32, to: i32) i32 {
    if (from == 0) return 0;
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(to)) / @as(f64, @floatFromInt(from))));
}

pub fn textFontPx(thickness: i32) f64 {
    return @as(f64, @floatFromInt(@max(1, thickness))) * 7.0 + 12.0;
}

fn segDist(p: Point, a: Point, b: Point) f64 {
    const px: f64 = @floatFromInt(p.x);
    const py: f64 = @floatFromInt(p.y);
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const abx = @as(f64, @floatFromInt(b.x)) - ax;
    const aby = @as(f64, @floatFromInt(b.y)) - ay;
    const ab2 = abx * abx + aby * aby;
    const t = if (ab2 == 0) 0.0 else std.math.clamp(((px - ax) * abx + (py - ay) * aby) / ab2, 0.0, 1.0);
    const dx = px - (ax + abx * t);
    const dy = py - (ay + aby * t);
    return @sqrt(dx * dx + dy * dy);
}

/// Annotation colours. The first eight are the 1-8 keys (and the config's
/// default_color), in their historical order; the rest only show in the
/// colour popover.
pub const palette = [11]u32{
    0xFFFF453A, // red
    0xFFFF9F0A, // orange
    0xFFFFD60A, // yellow
    0xFF30D158, // green
    0xFF0A84FF, // blue
    0xFFBF5AF2, // magenta (purple)
    0xFFFFFFFF, // white
    0xFF1C1C1E, // black
    0xFFFF375F, // pink
    0xFF64D2FF, // cyan
    0xFF8E8E93, // grey
};

pub const palette_names = [palette.len][]const u8{ "red", "orange", "yellow", "green", "blue", "magenta", "white", "black", "pink", "cyan", "grey" };
pub const palette_labels = [palette.len][]const u8{ "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White", "Black", "Pink", "Cyan", "Grey" };

/// The popover's grid order: colours first, then the neutrals.
pub const swatch_order = [palette.len]u4{ 0, 1, 2, 3, 4, 5, 8, 9, 6, 10, 7 };

// --- shape drawing ---

/// Paint `s` through `xf`. `alloc` is scratch for transformed polylines
/// and blur; `cursor` marks the caret and selection of a text shape being
/// edited.
pub fn drawShape(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform, cursor: ?TextCursor) void {
    const tf = @max(1.0, s.th() * xf.scale);
    switch (s.tool) {
        .pen, .highlight => {
            const pts = alloc.alloc(Point, s.points.items.len) catch return;
            defer alloc.free(pts);
            for (pts, s.points.items) |*d, p| d.* = xf.pt(p);
            if (s.tool == .pen) {
                canvas.strokePolylineAA(pts, tf, s.color);
            } else {
                canvas.strokePolylineAA(pts, tf * 3.0, (s.color & 0x00FFFFFF) | 0x66000000);
            }
        },
        .line => {
            const seg = [_]Point{ xf.pt(s.p0), xf.pt(s.p1) };
            canvas.strokePolylineAA(seg[0..], tf, s.color);
        },
        .arrow => drawArrow(canvas, xf.fx(s.p0.x), xf.fy(s.p0.y), xf.fx(s.p1.x), xf.fy(s.p1.y), tf, s.arrowHead() * xf.scale, s.color),
        .rect => {
            const r = xf.rect(s.frame());
            const rad = if (s.rounded) s.cornerRadius() * xf.scale else 0;
            if (s.filled) {
                if (rad > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, s.color) else canvas.fillRect(r.x, r.y, r.w, r.h, s.color);
            } else if (rad > 0) {
                roundRectRing(canvas, r, rad, tf, s.color);
            } else {
                canvas.rectOutline(r.x, r.y, r.w, r.h, @intFromFloat(@round(tf)), s.color);
            }
        },
        .ellipse => {
            const r = xf.rect(s.frame());
            if (s.filled) fillEllipseAA(canvas, r, s.color) else canvas.ellipseRingAA(r.x, r.y, r.w, r.h, tf, s.color);
        },
        .blur => {
            const r = xf.rect(s.frame());
            const rad: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(s.blurRadius())) * xf.scale))));
            effects.blur(alloc, canvas.px, @intCast(canvas.w), @intCast(canvas.h), .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, rad) catch {};
        },
        .pixelate => {
            const r = xf.rect(s.frame());
            const blk: i32 = @max(2, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(s.pixelBlock())) * xf.scale))));
            pixelateAligned(canvas, r, blk);
        },
        .redact => {
            const r = xf.rect(s.frame());
            effects.redact(canvas.px, @intCast(canvas.w), @intCast(canvas.h), .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, s.color);
        },
        .counter => {
            const r = s.counterRadius() * xf.scale;
            const cx = xf.fx(s.p0.x);
            const cy = xf.fy(s.p0.y);
            canvas.fillCircleAA(cx, cy, r, s.color);
            canvas.ringAA(cx, cy, r, @max(1.0, r * 0.12), 0xFFFFFFFF);
            var buf: [12]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{s.number}) catch "?";
            const fs = r * (if (s.number >= 10) @as(f64, 0.95) else 1.15);
            text_mod.draw(
                canvas,
                @as(i32, @intFromFloat(@round(cx))) - @divTrunc(text_mod.width(fs, label), 2),
                @as(i32, @intFromFloat(@round(cy))) - @divTrunc(text_mod.height(fs), 2),
                fs,
                contrastColor(s.color),
                label,
            );
        },
        .text => drawText(canvas, alloc, s, xf, cursor),
        .select => {},
    }
}

/// Caret (byte offset) and selected byte range of a text being edited.
pub const TextCursor = struct {
    caret: usize,
    sel: ?[2]usize = null,
    /// the caret sits at the end of the line above a soft break
    upstream: bool = false,
};

pub const selection_color: u32 = 0x804DABF7;

fn drawText(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform, cursor: ?TextCursor) void {
    const str = s.str.items;
    // line breaks come from the image-size layout, so the preview at any
    // zoom wraps exactly like the export
    var lay = textbox.Layout.init(alloc, str, s.fontPx(), s.box_w) catch return;
    defer lay.deinit(alloc);
    const fs = s.fontPx() * xf.scale;
    const lh = text_mod.height(fs);
    const fg = if (s.pill) contrastColor(s.color) else s.color;
    if (s.pill) {
        const r = xf.rect(s.frame());
        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, fs * 0.35, s.color);
    }
    const box_x: i32 = @intFromFloat(@round(xf.fx(s.p0.x)));
    const box_w: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(lay.w)) * xf.scale));
    var y: i32 = @intFromFloat(@round(xf.fy(s.p0.y)));
    const caret_line: ?usize = if (cursor) |c| lay.lineOf(.{ .off = c.caret, .upstream = c.upstream }) else null;
    for (lay.lines.items, 0..) |l, i| {
        // each line is a slice of its paragraph, shaped as a whole
        const para, const la, const lb = lay.paraOf(str, i);
        const ps = l.para_start;
        const dir = l.dir();
        const x0 = box_x + lay.indentAt(str, i, fs, box_w);
        if (cursor) |cur| if (cur.sel) |sel| {
            // the part of the selection on this line (+ a sliver for its
            // newline or hanging spaces)
            const a = @max(sel[0], l.start);
            const b = @min(sel[1], l.end + @intFromBool(!l.soft and l.end < str.len));
            if (a < b) {
                // the glyphs' own extents, so a range across both
                // directions highlights each part where it is drawn
                var spans: [16][2]i32 = undefined;
                const ns = text_mod.rangeSpansLine(fs, .regular, para, la, lb, @min(a, l.vis_end) - ps, @min(b, l.vis_end) - ps, dir, &spans);
                for (spans[0..ns]) |sp| canvas.fillRect(x0 + sp[0], y, sp[1] - sp[0], lh, selection_color);
                if (b > l.vis_end) {
                    // a sliver for the newline or the hanging spaces, at
                    // the paragraph's end side
                    const sliver: i32 = @intFromFloat(@round(fs * 0.25));
                    const ex = if (l.rtl) x0 - sliver else x0 + lay.lineWidth(str, i, fs);
                    canvas.fillRect(ex, y, sliver, lh, selection_color);
                }
            }
        };
        text_mod.drawRange(canvas, x0, y, fs, fg, .regular, para, la, lb, dir);
        if (caret_line == i) {
            const c = std.math.clamp(cursor.?.caret, l.start, l.vis_end);
            const cx = x0 + text_mod.xForOffsetRange(fs, .regular, para, la, lb, c - ps, dir);
            const cw: i32 = @max(1, @as(i32, @intFromFloat(@round(fs / 14.0))));
            canvas.fillRect(cx, y, cw, lh, fg);
        }
        y += lh;
    }
}

/// Arrow with a filled head whose tip lands exactly on (x1, y1).
pub fn drawArrow(canvas: *Canvas, x0: f64, y0: f64, x1: f64, y1: f64, width: f64, head_len: f64, color: u32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    const head = @min(head_len, len);
    const ux = dx / len;
    const uy = dy / len;
    const seg = [_]Point{
        .{ .x = @intFromFloat(@round(x0)), .y = @intFromFloat(@round(y0)) },
        .{ .x = @intFromFloat(@round(x1 - ux * head * 0.7)), .y = @intFromFloat(@round(y1 - uy * head * 0.7)) },
    };
    canvas.strokePolylineAA(seg[0..], width, color);
    const px = -uy;
    const py = ux;
    const hw = @max(head * 0.45, width);
    canvas.fillTriangleAA(x1, y1, x1 - ux * head + px * hw, y1 - uy * head + py * hw, x1 - ux * head - px * hw, y1 - uy * head - py * hw, color);
}

/// Anti-aliased rounded rectangle outline drawn inside `r`; touches only
/// the border band, so big rectangles stay cheap.
pub fn roundRectRing(canvas: *Canvas, r: Rect, radius: f64, width: f64, color: u32) void {
    if (r.w <= 0 or r.h <= 0) return;
    const fx0: f64 = @floatFromInt(r.x);
    const fy0: f64 = @floatFromInt(r.y);
    const fx1: f64 = @floatFromInt(r.right());
    const fy1: f64 = @floatFromInt(r.bottom());
    const ro = @min(radius, @min(@as(f64, @floatFromInt(r.w)), @as(f64, @floatFromInt(r.h))) / 2.0);
    const ri = @max(0.0, ro - width);
    const band: i32 = @as(i32, @intFromFloat(@ceil(@max(ro, width)))) + 2;
    var y: i32 = @max(r.y - 1, 0);
    const y_end = @min(r.bottom() + 1, canvas.h);
    while (y < y_end) : (y += 1) {
        const near_edge = y < r.y + band or y >= r.bottom() - band;
        var x: i32 = @max(r.x - 1, 0);
        const x_end = @min(r.right() + 1, canvas.w);
        while (x < x_end) : (x += 1) {
            if (!near_edge and x >= r.x + band and x < r.right() - band) {
                x = r.right() - band - 1;
                continue;
            }
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const d_o = rrDist(px, py, fx0, fy0, fx1, fy1, ro);
            const d_i = rrDist(px, py, fx0 + width, fy0 + width, fx1 - width, fy1 - width, ri);
            const cov = std.math.clamp(0.5 - d_o, 0.0, 1.0) - std.math.clamp(0.5 - d_i, 0.0, 1.0);
            canvas.blendCov(x, y, color, cov);
        }
    }
}

fn rrDist(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r: f64) f64 {
    if (x1 <= x0 or y1 <= y0) return 1e9;
    const rr = @min(r, @min(x1 - x0, y1 - y0) / 2.0);
    const qx = @max(x0 + rr - px, px - (x1 - rr));
    const qy = @max(y0 + rr - py, py - (y1 - rr));
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - rr;
}

pub fn fillEllipseAA(canvas: *Canvas, r: Rect, color: u32) void {
    if (r.w < 1 or r.h < 1) return;
    const rx = @as(f64, @floatFromInt(r.w)) / 2.0;
    const ry = @as(f64, @floatFromInt(r.h)) / 2.0;
    const cx = @as(f64, @floatFromInt(r.x)) + rx;
    const cy = @as(f64, @floatFromInt(r.y)) + ry;
    var y: i32 = @max(r.y - 1, 0);
    while (y < @min(r.bottom() + 1, canvas.h)) : (y += 1) {
        var x: i32 = @max(r.x - 1, 0);
        while (x < @min(r.right() + 1, canvas.w)) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const f = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) - 1.0;
            const gx = 2.0 * dx / (rx * rx);
            const gy = 2.0 * dy / (ry * ry);
            const g = @max(1e-9, @sqrt(gx * gx + gy * gy));
            canvas.blendCov(x, y, color, std.math.clamp(0.5 - f / g, 0.0, 1.0));
        }
    }
}

/// Mosaic `r` with `blk`-sized cells aligned to the rectangle's own
/// corner, so a clipped redraw produces the same cells as a full one.
pub fn pixelateAligned(canvas: *Canvas, r: Rect, blk: i32) void {
    const clip = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    var by = r.y + @divFloor(clip.y - r.y, blk) * blk;
    while (by < clip.bottom()) : (by += blk) {
        var bx = r.x + @divFloor(clip.x - r.x, blk) * blk;
        while (bx < clip.right()) : (bx += blk) {
            const cell = Rect.intersect(.{ .x = bx, .y = by, .w = blk, .h = blk }, clip) orelse continue;
            var acc: [3]u64 = .{ 0, 0, 0 };
            var y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                for (canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)]) |p| {
                    acc[0] += (p >> 16) & 0xFF;
                    acc[1] += (p >> 8) & 0xFF;
                    acc[2] += p & 0xFF;
                }
            }
            const n: u64 = @intCast(cell.w * cell.h);
            const avg: u32 = 0xFF000000 | @as(u32, @intCast(acc[0] / n)) << 16 | @as(u32, @intCast(acc[1] / n)) << 8 | @as(u32, @intCast(acc[2] / n));
            y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                @memset(canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)], avg);
            }
        }
    }
}

pub fn contrastColor(c: u32) u32 {
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    const lum = (r * 299 + g * 587 + b * 114) / 1000;
    return if (lum > 140) 0xFF1A1A1A else 0xFFFFFFFF;
}

// --- drag constraints (Shift: square / 45 degrees, Alt: from the centre) ---

/// Corners of a box dragged from `anchor` to `p`: Shift makes it a
/// square (circle), Alt grows it around the anchor.
pub fn dragCorners(anchor: Point, p: Point, square: bool, center: bool) [2]Point {
    var q = p;
    if (square) {
        const dx = p.x - anchor.x;
        const dy = p.y - anchor.y;
        const m: i32 = @intCast(@max(@abs(dx), @abs(dy)));
        q = .{ .x = anchor.x + (if (dx < 0) -m else m), .y = anchor.y + (if (dy < 0) -m else m) };
    }
    if (center) return .{ .{ .x = 2 * anchor.x - q.x, .y = 2 * anchor.y - q.y }, q };
    return .{ anchor, q };
}

/// `p` moved onto the nearest 45-degree ray from `anchor`, keeping its
/// distance along that ray.
pub fn snapAngle(anchor: Point, p: Point) Point {
    const dx: f64 = @floatFromInt(p.x - anchor.x);
    const dy: f64 = @floatFromInt(p.y - anchor.y);
    if (dx == 0 and dy == 0) return p;
    const step = std.math.pi / 4.0;
    const ang = @round(std.math.atan2(dy, dx) / step) * step;
    const len = dx * @cos(ang) + dy * @sin(ang);
    return .{
        .x = anchor.x + @as(i32, @intFromFloat(@round(len * @cos(ang)))),
        .y = anchor.y + @as(i32, @intFromFloat(@round(len * @sin(ang)))),
    };
}

test "shift and alt drag constraints" {
    const a = Point{ .x = 100, .y = 100 };
    const sq = dragCorners(a, .{ .x = 130, .y = 90 }, true, false);
    try std.testing.expectEqual(Point{ .x = 130, .y = 70 }, sq[1]);
    const c = dragCorners(a, .{ .x = 120, .y = 110 }, false, true);
    try std.testing.expectEqual(Point{ .x = 80, .y = 90 }, c[0]);
    try std.testing.expectEqual(Point{ .x = 120, .y = 110 }, c[1]);
    const both = dragCorners(a, .{ .x = 90, .y = 130 }, true, true);
    try std.testing.expect(Rect.fromCorners(both[0], both[1]).eql(.{ .x = 70, .y = 70, .w = 60, .h = 60 }));
    try std.testing.expectEqual(Point{ .x = 150, .y = 100 }, snapAngle(a, .{ .x = 150, .y = 108 }));
    try std.testing.expectEqual(Point{ .x = 100, .y = 40 }, snapAngle(a, .{ .x = 95, .y = 40 }));
    const d = snapAngle(a, .{ .x = 140, .y = 136 });
    try std.testing.expectEqual(d.x - a.x, d.y - a.y);
}

// --- selection handles ---

pub fn handlePoints(s: Rect) [8]Point {
    const mx = s.x + @divTrunc(s.w, 2);
    const my = s.y + @divTrunc(s.h, 2);
    return .{
        .{ .x = s.x, .y = s.y }, // 0 nw
        .{ .x = mx, .y = s.y }, // 1 n
        .{ .x = s.x + s.w, .y = s.y }, // 2 ne
        .{ .x = s.x + s.w, .y = my }, // 3 e
        .{ .x = s.x + s.w, .y = s.y + s.h }, // 4 se
        .{ .x = mx, .y = s.y + s.h }, // 5 s
        .{ .x = s.x, .y = s.y + s.h }, // 6 sw
        .{ .x = s.x, .y = my }, // 7 w
    };
}

/// Handle of `s` under `m` within `radius`. On a selection too small to
/// hold the handles and still be grabbed, its inside always moves it and
/// the handles answer only from the outside.
pub fn handleAt(s: Rect, m: Point, radius: i32) ?u3 {
    const small = s.w < 4 * radius or s.h < 4 * radius;
    if (small and s.contains(m.x, m.y)) return null;
    var best: ?u3 = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (handlePoints(s), 0..) |p, i| {
        // on small rects the edge handles crowd the corners; skip them
        if (small and i % 2 == 1) continue;
        const d = @max(@abs(m.x - p.x), @abs(m.y - p.y));
        if (d <= radius and d < best_d) {
            best = @intCast(i);
            best_d = d;
        }
    }
    return best;
}

pub fn resizeWithHandle(orig: Rect, handle: u3, m: Point) Rect {
    var x0 = orig.x;
    var y0 = orig.y;
    var x1 = orig.x + orig.w;
    var y1 = orig.y + orig.h;
    switch (handle) {
        0 => {
            x0 = m.x;
            y0 = m.y;
        },
        1 => y0 = m.y,
        2 => {
            x1 = m.x;
            y0 = m.y;
        },
        3 => x1 = m.x,
        4 => {
            x1 = m.x;
            y1 = m.y;
        },
        5 => y1 = m.y,
        6 => {
            x0 = m.x;
            y1 = m.y;
        },
        7 => x0 = m.x,
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "rect normalization" {
    const r = (Rect{ .x = 100, .y = 50, .w = -30, .h = -20 }).normalized();
    try std.testing.expectEqual(@as(i32, 70), r.x);
    try std.testing.expectEqual(@as(i32, 30), r.y);
    try std.testing.expectEqual(@as(i32, 30), r.w);
    try std.testing.expectEqual(@as(i32, 20), r.h);
    try std.testing.expect(r.contains(70, 30));
    try std.testing.expect(!r.contains(100, 50));
}

test "rect intersect and unite" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = -5, .w = 10, .h = 10 };
    const i = Rect.intersect(a, b).?;
    try std.testing.expect(i.eql(.{ .x = 5, .y = 0, .w = 5, .h = 5 }));
    try std.testing.expect(Rect.unite(a, b).eql(.{ .x = 0, .y = -5, .w = 15, .h = 15 }));
    try std.testing.expect(Rect.unite(Rect.empty, b).eql(b));
    try std.testing.expectEqual(@as(?Rect, null), Rect.intersect(a, .{ .x = 10, .y = 0, .w = 5, .h = 5 }));
}

test "selection handle resolution" {
    const s = Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(?u3, 0), handleAt(s, .{ .x = 10, .y = 10 }, 11)); // nw
    try std.testing.expectEqual(@as(?u3, 4), handleAt(s, .{ .x = 110, .y = 110 }, 11)); // se
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 60, .y = 60 }, 11)); // center
    const grown = resizeWithHandle(s, 4, .{ .x = 150, .y = 130 });
    try std.testing.expectEqual(@as(i32, 140), grown.w);
    try std.testing.expectEqual(@as(i32, 120), grown.h);
}

test "handles scale with radius and never block moving a small selection" {
    const s = Rect{ .x = 100, .y = 100, .w = 20, .h = 16 };
    // inside a small selection: always a move, even right at a corner
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 101, .y = 101 }, 11));
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 110, .y = 108 }, 11));
    // just outside a corner: that corner
    try std.testing.expectEqual(@as(?u3, 4), handleAt(s, .{ .x = 124, .y = 119 }, 11));
    try std.testing.expectEqual(@as(?u3, 0), handleAt(s, .{ .x = 96, .y = 97 }, 11));
    // a bigger radius (HiDPI) reaches further
    const big = Rect{ .x = 0, .y = 0, .w = 400, .h = 400 };
    try std.testing.expectEqual(@as(?u3, null), handleAt(big, .{ .x = 18, .y = 18 }, 11));
    try std.testing.expectEqual(@as(?u3, 0), handleAt(big, .{ .x = 18, .y = 18 }, 22));
}

test "shape hit testing and frames" {
    const alloc = std.testing.allocator;
    const line = Shape{ .tool = .line, .color = 0xFFFF0000, .thickness = 4, .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 100, .y = 0 } };
    try std.testing.expect(line.hitTest(.{ .x = 50, .y = 3 }, 2));
    try std.testing.expect(!line.hitTest(.{ .x = 50, .y = 10 }, 2));

    var rect = Shape{ .tool = .rect, .color = 0xFFFF0000, .thickness = 4, .p0 = .{ .x = 100, .y = 100 }, .p1 = .{ .x = 10, .y = 10 } };
    try std.testing.expect(rect.frame().eql(.{ .x = 10, .y = 10, .w = 90, .h = 90 }));
    try std.testing.expect(rect.hitTest(.{ .x = 11, .y = 50 }, 2));
    try std.testing.expect(!rect.hitTest(.{ .x = 50, .y = 50 }, 2)); // hollow
    rect.filled = true;
    try std.testing.expect(rect.hitTest(.{ .x = 50, .y = 50 }, 2));

    var pen = Shape{ .tool = .pen, .color = 0xFFFF0000, .thickness = 2 };
    defer pen.deinit(alloc);
    try pen.points.appendSlice(alloc, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 0 } });
    try std.testing.expect(pen.frame().eql(.{ .x = 0, .y = 0, .w = 20, .h = 10 }));
    var copy = try pen.clone(alloc);
    defer copy.deinit(alloc);
    copy.setFrame(&pen, .{ .x = 100, .y = 100, .w = 40, .h = 20 });
    try std.testing.expectEqual(Point{ .x = 120, .y = 120 }, copy.points.items[1]);
    try std.testing.expectEqual(Point{ .x = 140, .y = 100 }, copy.points.items[2]);
    copy.translate(-100, -100);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, copy.points.items[0]);
    try std.testing.expect(pen.hitTest(.{ .x = 5, .y = 6 }, 1));
    try std.testing.expect(!pen.hitTest(.{ .x = 10, .y = 0 }, 1));
}

test "pixelate cells stay aligned when clipped" {
    // a full render and a render through an offset canvas give the same cells
    var full: [32 * 8]u32 = undefined;
    for (&full, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast((i * 2654435761) % 0xFFFFFF));
    var part: [16 * 8]u32 = undefined;
    for (0..8) |y| @memcpy(part[y * 16 ..][0..16], full[y * 32 + 16 ..][0..16]);
    var cf = Canvas.init(&full, 32, 8);
    pixelateAligned(&cf, .{ .x = 2, .y = 0, .w = 28, .h = 8 }, 4);
    var cp = Canvas.init(&part, 16, 8);
    pixelateAligned(&cp, .{ .x = 2 - 16, .y = 0, .w = 28, .h = 8 }, 4);
    // cells fully inside the partial canvas match
    for (0..8) |y| {
        for (2..14) |x| try std.testing.expectEqual(full[y * 32 + 16 + x], part[y * 16 + x]);
    }
}

test "drawing through a transform scales shapes" {
    const alloc = std.testing.allocator;
    var px: [40 * 40]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 40, 40);
    const s = Shape{ .tool = .redact, .color = 0xFFFFFFFF, .thickness = 2, .p0 = .{ .x = 10, .y = 10 }, .p1 = .{ .x = 30, .y = 30 } };
    drawShape(&c, alloc, &s, .{ .scale = 0.5, .ox = 5, .oy = 5 }, null);
    // image (10..30) -> canvas (10..20)
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 40 + 10]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[19 * 40 + 19]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[20 * 40 + 20]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[9 * 40 + 9]);
}

test "fixed-width text wraps: frame, drawing and preview match the export" {
    const alloc = std.testing.allocator;
    text_mod.init(alloc);
    defer text_mod.deinit();
    var s = Shape{ .tool = .text, .color = 0xFFFF0000, .thickness = 2, .p0 = .{ .x = 10, .y = 10 } };
    defer s.deinit(alloc);
    try s.str.appendSlice(alloc, "one two three four five six\n\u{5E9}\u{5DC}\u{5D5}\u{5DD} \u{5E2}\u{5D5}\u{5DC}\u{5DD} \u{645}\u{631}\u{62D}\u{628}\u{627}");
    const fs = s.fontPx();
    const lh = text_mod.height(fs);
    const auto = s.frame();
    try std.testing.expectEqual(2 * lh, auto.h);
    s.box_w = text_mod.width(fs, "one two three") + 1;
    const f = s.frame();
    try std.testing.expectEqual(s.box_w, f.w);
    try std.testing.expect(f.h >= 4 * lh);
    // too narrow for anything: clamped, still draws
    s.box_w = 1;
    try std.testing.expectEqual(textbox.minWidth(fs), s.frame().w);
    s.box_w = text_mod.width(fs, "one two three") + 1;
    // drawing with a cursor and a selection across lines and directions,
    // at export scale and zoomed out
    var px: [400 * 300]u32 = @splat(0xFF000000);
    var c = Canvas.init(&px, 400, 300);
    for ([_]f64{ 1.0, 0.5 }) |sc| {
        drawShape(&c, alloc, &s, .{ .scale = sc }, .{ .caret = 14, .sel = .{ 4, 40 } });
        drawShape(&c, alloc, &s, .{ .scale = sc }, .{ .caret = 8, .upstream = true });
    }
    // RTL text puts its width handle on the left
    try std.testing.expect(!s.textRtl());
    var r = Shape{ .tool = .text, .color = 0xFFFF0000, .thickness = 2 };
    defer r.deinit(alloc);
    try r.str.appendSlice(alloc, "123 \u{5D0}\u{5D1}");
    try std.testing.expect(r.textRtl());
}
