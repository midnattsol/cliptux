//! The annotation shape model: tools, a shape's geometry (frame, bounds,
//! hit testing, resizing) and the colour palette.

const std = @import("std");
const geometry = @import("geometry.zig");
const textbox = @import("../textbox.zig");
const ruler = @import("../tools/ruler.zig");
const spotlight = @import("../tools/spotlight.zig");

const Rect = geometry.Rect;
const Point = geometry.Point;

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
    /// everything around it dimmed (tools/spotlight.zig)
    spotlight,
    /// a measurement (tools/ruler.zig)
    ruler,

    /// Tools that hide what is under them.
    pub fn isRedaction(self: Tool) bool {
        return self == .blur or self == .pixelate or self == .redact;
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

    /// Stroke width as a float, at least 1.
    pub fn th(self: *const Shape) f64 {
        return @floatFromInt(@max(1, self.thickness));
    }

    pub fn fontPx(self: *const Shape) f64 {
        return textFontPx(self.thickness);
    }

    pub fn counterRadius(self: *const Shape) f64 {
        return 8.0 + self.th() * 2.0;
    }

    pub fn arrowHead(self: *const Shape) f64 {
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
            .pen, .highlight => return pointsFrame(self.points.items),
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
            .ruler => ruler.bounds(self),
            .spotlight => spotlight.bounds(),
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
                return hitPolyline(self.points.items, p, w + tol);
            },
            .line, .arrow, .ruler => return segDist(p, self.p0, self.p1) <= half + tol,
            .spotlight => return spotlight.hitTest(self, p, tol),
            .rect => return self.hitRect(p, tol),
            .ellipse => return self.hitEllipse(p, half, tol),
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

    /// A rectangle: its outline band, or all of it when filled.
    fn hitRect(self: *const Shape, p: Point, tol: f64) bool {
        const r = self.frame();
        const t: i32 = @intFromFloat(@ceil(tol));
        if (!r.expand(t).contains(p.x, p.y)) return false;
        if (self.filled) return true;
        const inner = r.expand(-(@max(1, self.thickness) + t));
        return inner.isEmpty() or !inner.contains(p.x, p.y);
    }

    /// An ellipse, by its first-order distance estimate f / |grad f|.
    fn hitEllipse(self: *const Shape, p: Point, half: f64, tol: f64) bool {
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
    }

    pub const HandleKind = enum { none, endpoints, box };

    pub fn handleKind(self: *const Shape) HandleKind {
        return switch (self.tool) {
            .line, .arrow, .ruler => .endpoints,
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

/// Bounding box of a polyline's points (empty for none).
fn pointsFrame(pts: []const Point) Rect {
    if (pts.len == 0) return .empty;
    var r = Rect{ .x = pts[0].x, .y = pts[0].y, .w = 0, .h = 0 };
    for (pts[1..]) |p| {
        const x1 = @max(r.right(), p.x);
        const y1 = @max(r.bottom(), p.y);
        r.x = @min(r.x, p.x);
        r.y = @min(r.y, p.y);
        r.w = x1 - r.x;
        r.h = y1 - r.y;
    }
    return r;
}

/// Is `p` within `reach` of any segment of the polyline `pts`?
fn hitPolyline(pts: []const Point, p: Point, reach: f64) bool {
    if (pts.len == 0) return false;
    if (pts.len == 1) return segDist(p, pts[0], pts[0]) <= reach;
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (segDist(p, pts[i], pts[i + 1]) <= reach) return true;
    }
    return false;
}

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
