//! The editor's document, in image pixels and free of any window: the
//! annotations, the selected region, undo/redo, the native-resolution
//! composite layer and export (crop + optional "beautify" frame).

const std = @import("std");
const shapes = @import("shapes.zig");
const render = @import("../gfx/render.zig");
const effects = @import("../gfx/effects.zig");

pub const Shape = shapes.Shape;
pub const Rect = shapes.Rect;
pub const Point = shapes.Point;

const max_undo = 200;

pub const Document = struct {
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    shapes: std.ArrayList(Shape) = .empty,
    /// selected region in image pixels (normalized except mid-drag)
    sel: ?Rect = null,
    undo_stack: std.ArrayList([]Shape) = .empty,
    redo_stack: std.ArrayList([]Shape) = .empty,

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) Document {
        return .{ .alloc = alloc, .width = width, .height = height };
    }

    pub fn deinit(self: *Document) void {
        freeShapes(self.alloc, self.shapes.items);
        self.shapes.deinit(self.alloc);
        for (self.undo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.undo_stack.deinit(self.alloc);
        for (self.redo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.redo_stack.deinit(self.alloc);
    }

    pub fn imageRect(self: *const Document) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    /// What gets exported: the selection clipped to the image, or exactly
    /// the image when nothing (or nothing visible) is selected.
    pub fn exportRect(self: *const Document) Rect {
        const img = self.imageRect();
        const s = self.sel orelse return img;
        return Rect.intersect(s.normalized(), img) orelse img;
    }

    // --- undo ---

    fn snapshot(self: *Document) ![]Shape {
        const snap = try self.alloc.alloc(Shape, self.shapes.items.len);
        var n: usize = 0;
        errdefer {
            freeShapes(self.alloc, snap[0..n]);
            self.alloc.free(snap);
        }
        for (self.shapes.items) |*s| {
            snap[n] = try s.clone(self.alloc);
            n += 1;
        }
        return snap;
    }

    /// Record the current shapes so the next change can be undone.
    pub fn checkpoint(self: *Document) !void {
        const snap = try self.snapshot();
        errdefer freeSnapshot(self.alloc, snap);
        if (self.undo_stack.items.len >= max_undo) {
            freeSnapshot(self.alloc, self.undo_stack.orderedRemove(0));
        }
        try self.undo_stack.append(self.alloc, snap);
        for (self.redo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Forget the last checkpoint (the change it guarded never happened).
    pub fn dropCheckpoint(self: *Document) void {
        if (self.undo_stack.pop()) |s| freeSnapshot(self.alloc, s);
    }

    fn swapIn(self: *Document, snap: []Shape) void {
        freeShapes(self.alloc, self.shapes.items);
        self.shapes.clearRetainingCapacity();
        // capacity was reserved by the caller
        self.shapes.appendSliceAssumeCapacity(snap);
        self.alloc.free(snap);
    }

    pub fn undo(self: *Document) !bool {
        if (self.undo_stack.items.len == 0) return false;
        const cur = try self.snapshot();
        errdefer freeSnapshot(self.alloc, cur);
        try self.redo_stack.ensureUnusedCapacity(self.alloc, 1);
        const snap = self.undo_stack.items[self.undo_stack.items.len - 1];
        try self.shapes.ensureTotalCapacity(self.alloc, snap.len);
        _ = self.undo_stack.pop();
        self.swapIn(snap);
        self.redo_stack.appendAssumeCapacity(cur);
        return true;
    }

    pub fn redo(self: *Document) !bool {
        if (self.redo_stack.items.len == 0) return false;
        const cur = try self.snapshot();
        errdefer freeSnapshot(self.alloc, cur);
        try self.undo_stack.ensureUnusedCapacity(self.alloc, 1);
        const snap = self.redo_stack.items[self.redo_stack.items.len - 1];
        try self.shapes.ensureTotalCapacity(self.alloc, snap.len);
        _ = self.redo_stack.pop();
        self.swapIn(snap);
        self.undo_stack.appendAssumeCapacity(cur);
        return true;
    }

    /// Drop the changes since the last checkpoint (and the checkpoint).
    pub fn revert(self: *Document) !void {
        if (self.undo_stack.items.len == 0) return;
        const snap = self.undo_stack.items[self.undo_stack.items.len - 1];
        try self.shapes.ensureTotalCapacity(self.alloc, snap.len);
        _ = self.undo_stack.pop();
        self.swapIn(snap);
    }

    // --- shape edits (callers checkpoint first) ---

    /// Take ownership of `s` and put it on top.
    pub fn add(self: *Document, s: Shape) !usize {
        var owned = s;
        errdefer owned.deinit(self.alloc);
        try self.shapes.append(self.alloc, owned);
        return self.shapes.items.len - 1;
    }

    pub fn remove(self: *Document, i: usize) void {
        var s = self.shapes.orderedRemove(i);
        s.deinit(self.alloc);
    }

    /// Copy shape `i` on top, offset by (dx, dy); returns the new index.
    pub fn duplicate(self: *Document, i: usize, dx: i32, dy: i32) !usize {
        var c = try self.shapes.items[i].clone(self.alloc);
        c.translate(dx, dy);
        if (c.tool == .counter) c.number = self.nextNumber();
        return self.add(c);
    }

    pub fn bringToFront(self: *Document, i: usize) usize {
        const s = self.shapes.orderedRemove(i);
        self.shapes.appendAssumeCapacity(s);
        return self.shapes.items.len - 1;
    }

    /// Topmost shape at image point `p` (within `tol` image pixels).
    pub fn hit(self: *const Document, p: Point, tol: f64) ?usize {
        var i = self.shapes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.shapes.items[i].hitTest(p, tol)) return i;
        }
        return null;
    }

    /// Number for the next counter badge.
    pub fn nextNumber(self: *const Document) u32 {
        var n: u32 = 0;
        for (self.shapes.items) |s| {
            if (s.tool == .counter) n = @max(n, s.number);
        }
        return n + 1;
    }

    // --- selection ---

    /// Move the selection by (dx, dy), kept inside the image.
    pub fn moveSelection(self: *Document, dx: i32, dy: i32) void {
        const s = (self.sel orelse return).normalized();
        const iw: i32 = @intCast(self.width);
        const ih: i32 = @intCast(self.height);
        self.sel = .{
            .x = std.math.clamp(s.x + dx, 0, @max(0, iw - s.w)),
            .y = std.math.clamp(s.y + dy, 0, @max(0, ih - s.h)),
            .w = s.w,
            .h = s.h,
        };
    }

    /// Grow or shrink the selection's right/bottom edges, kept inside the
    /// image and at least 1×1.
    pub fn resizeSelection(self: *Document, dw: i32, dh: i32) void {
        const s = (self.sel orelse return).normalized();
        const iw: i32 = @intCast(self.width);
        const ih: i32 = @intCast(self.height);
        self.sel = .{
            .x = s.x,
            .y = s.y,
            .w = std.math.clamp(s.w + dw, 1, @max(1, iw - s.x)),
            .h = std.math.clamp(s.h + dh, 1, @max(1, ih - s.y)),
        };
    }
};

fn freeShapes(alloc: std.mem.Allocator, list: []Shape) void {
    for (list) |*s| s.deinit(alloc);
}

fn freeSnapshot(alloc: std.mem.Allocator, snap: []Shape) void {
    freeShapes(alloc, snap);
    alloc.free(snap);
}

// --- composite layer ---

/// Recompose `region` of `layer` (the image with every shape painted on
/// it, at native resolution) from `img`, skipping shape `skip`. Effects
/// that read their surroundings (blur, pixelate) see enough margin that
/// the result matches a full redraw.
pub fn composeRegion(
    alloc: std.mem.Allocator,
    layer: []u32,
    img: []const u32,
    w: u32,
    h: u32,
    list: []const Shape,
    skip: ?usize,
    region: Rect,
) !void {
    const full: Rect = .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
    const r = Rect.intersect(region, full) orelse return;
    var margin: i32 = 0;
    for (list, 0..) |*s, i| {
        if (skip == i) continue;
        // effects read what earlier effects wrote, so their reach adds up
        margin += s.readMargin();
    }
    const e = Rect.intersect(r.expand(margin), full).?;
    const in_place = e.eql(full);
    const ew: usize = @intCast(e.w);
    const eh: usize = @intCast(e.h);
    const tmp = if (in_place) layer else try alloc.alloc(u32, ew * eh);
    defer if (!in_place) alloc.free(tmp);
    const mask = try alloc.alloc(u8, ew * eh);
    defer alloc.free(mask);
    @memset(mask, 0);
    for (0..eh) |y| {
        const src = (@as(usize, @intCast(e.y)) + y) * w + @as(usize, @intCast(e.x));
        @memcpy(tmp[y * ew ..][0..ew], img[src..][0..ew]);
    }
    var canvas = render.Canvas.init(tmp, @intCast(ew), @intCast(eh));
    canvas.mask = mask;
    const xf: shapes.Xform = .{ .ox = @floatFromInt(-e.x), .oy = @floatFromInt(-e.y) };
    for (list, 0..) |*s, i| {
        if (skip == i) continue;
        if (Rect.intersect(s.bounds().expand(s.readMargin()), e) == null) continue;
        shapes.drawShape(&canvas, alloc, s, xf, null);
    }
    if (in_place) return;
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |ry| {
        const ty: usize = @as(usize, @intCast(r.y - e.y)) + ry;
        const tx: usize = @intCast(r.x - e.x);
        const dst = (@as(usize, @intCast(r.y)) + ry) * w + @as(usize, @intCast(r.x));
        @memcpy(layer[dst..][0..rw], tmp[ty * ew + tx ..][0..rw]);
    }
}

/// Paint `s` over the layer as the new topmost shape: no recompose of
/// what lies under it, so committing a stroke costs only the stroke.
pub fn paintOnTop(alloc: std.mem.Allocator, layer: []u32, w: u32, h: u32, s: *const Shape) !void {
    const full: Rect = .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
    const r = Rect.intersect(s.bounds(), full) orelse return;
    const e = Rect.intersect(r.expand(s.readMargin()), full).?;
    const ew: usize = @intCast(e.w);
    const eh: usize = @intCast(e.h);
    const tmp = try alloc.alloc(u32, ew * eh);
    defer alloc.free(tmp);
    const mask = try alloc.alloc(u8, ew * eh);
    defer alloc.free(mask);
    @memset(mask, 0);
    for (0..eh) |y| {
        const src = (@as(usize, @intCast(e.y)) + y) * w + @as(usize, @intCast(e.x));
        @memcpy(tmp[y * ew ..][0..ew], layer[src..][0..ew]);
    }
    var canvas = render.Canvas.init(tmp, @intCast(ew), @intCast(eh));
    canvas.mask = mask;
    shapes.drawShape(&canvas, alloc, s, .{ .ox = @floatFromInt(-e.x), .oy = @floatFromInt(-e.y) }, null);
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |ry| {
        const t = (@as(usize, @intCast(r.y - e.y)) + ry) * ew + @as(usize, @intCast(r.x - e.x));
        const dst = (@as(usize, @intCast(r.y)) + ry) * w + @as(usize, @intCast(r.x));
        @memcpy(layer[dst..][0..rw], tmp[t..][0..rw]);
    }
}

// --- beautify and export ---

pub const Background = struct { from: u32, to: u32, name: []const u8 };

pub const backgrounds = [_]Background{
    .{ .from = 0xFF8EC5FC, .to = 0xFFE0C3FC, .name = "Lavender" },
    .{ .from = 0xFFFF9A8B, .to = 0xFFFF6A88, .name = "Coral" },
    .{ .from = 0xFF4FACFE, .to = 0xFF00F2FE, .name = "Ocean" },
    .{ .from = 0xFF43E97B, .to = 0xFF38F9D7, .name = "Mint" },
    .{ .from = 0xFFFA709A, .to = 0xFFFEE140, .name = "Sunset" },
    .{ .from = 0xFF30343F, .to = 0xFF1B1D24, .name = "Graphite" },
    .{ .from = 0xFFF1F3F5, .to = 0xFFF1F3F5, .name = "Paper" },
};

/// Padding as a percentage of the shot's longer side, per level.
pub const padding_pct = [4]u8{ 0, 4, 7, 12 };

pub const Beautify = struct {
    enabled: bool = false,
    bg: u8 = 0,
    /// padding: 0 none, 1 small, 2 medium, 3 large (see padding_pct)
    padding: u2 = 2,
    rounded: bool = true,
    shadow: bool = true,

    pub const Geometry = struct {
        out_w: u32,
        out_h: u32,
        pad: u32,
        radius: u32,
        shadow_blur: u32,
        shadow_dy: i32,
    };

    /// Output layout for a `w`×`h` shot, in the shot's own pixels.
    pub fn geometry(self: Beautify, w: u32, h: u32) Geometry {
        if (!self.enabled) return .{ .out_w = w, .out_h = h, .pad = 0, .radius = 0, .shadow_blur = 0, .shadow_dy = 0 };
        const long: f64 = @floatFromInt(@max(w, h));
        const pct = padding_pct[self.padding];
        const pad: u32 = if (pct == 0) 0 else @max(16, @as(u32, @intFromFloat(@round(long * @as(f64, @floatFromInt(pct)) / 100.0))));
        const radius: u32 = if (self.rounded) @min(@min(w, h) / 2, @max(4, @as(u32, @intFromFloat(@round(long * 0.012))))) else 0;
        const blur: u32 = if (self.shadow and pad > 0) @max(4, pad / 2) else 0;
        return .{
            .out_w = w + 2 * pad,
            .out_h = h + 2 * pad,
            .pad = pad,
            .radius = radius,
            .shadow_blur = blur,
            .shadow_dy = @intCast(blur / 3),
        };
    }

    pub fn background(self: Beautify) Background {
        return backgrounds[self.bg % backgrounds.len];
    }

    /// Paint the frame (background, shadow) into `dst` and place `shot`
    /// at (pad, pad) with rounded corners. `dst` is out_w×out_h.
    pub fn paint(self: Beautify, alloc: std.mem.Allocator, dst: []u32, shot: []const u32, w: u32, h: u32) void {
        _ = alloc;
        const g = self.geometry(w, h);
        const bg = self.background();
        const full: effects.Rect = .{ .x = 0, .y = 0, .w = @intCast(g.out_w), .h = @intCast(g.out_h) };
        effects.gradient(dst, g.out_w, g.out_h, full, bg.from, bg.to);
        const inner: effects.Rect = .{ .x = @intCast(g.pad), .y = @intCast(g.pad), .w = @intCast(w), .h = @intCast(h) };
        if (g.shadow_blur > 0) effects.dropShadow(dst, g.out_w, g.out_h, inner, g.shadow_blur, g.shadow_dy, 0x70000000);
        effects.blitRounded(dst, g.out_w, g.out_h, shot, w, h, inner.x, inner.y, g.radius);
    }
};

pub const Exported = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// Crop `crop` (inside the image) from the native layer and frame it if
/// beautify is on. Caller owns the pixels.
pub fn exportImage(alloc: std.mem.Allocator, layer: []const u32, w: u32, h: u32, crop: Rect, b: Beautify) !Exported {
    const full: Rect = .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
    const c = Rect.intersect(crop, full) orelse full;
    const cw: u32 = @intCast(c.w);
    const ch: u32 = @intCast(c.h);
    const shot = try alloc.alloc(u32, @as(usize, cw) * ch);
    errdefer alloc.free(shot);
    for (0..ch) |y| {
        const src = (@as(usize, @intCast(c.y)) + y) * w + @as(usize, @intCast(c.x));
        @memcpy(shot[y * cw ..][0..cw], layer[src..][0..cw]);
    }
    if (!b.enabled) return .{ .pixels = shot, .width = cw, .height = ch };
    defer alloc.free(shot);
    const g = b.geometry(cw, ch);
    const out = try alloc.alloc(u32, @as(usize, g.out_w) * g.out_h);
    b.paint(alloc, out, shot, cw, ch);
    return .{ .pixels = out, .width = g.out_w, .height = g.out_h };
}

// --- tests ---

const testing = std.testing;

fn testImage(alloc: std.mem.Allocator, w: u32, h: u32) ![]u32 {
    const px = try alloc.alloc(u32, @as(usize, w) * h);
    for (px, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i & 0xFFFFFF));
    return px;
}

test "export is exactly the image without a selection" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 300, 200);
    defer d.deinit();
    try testing.expect(d.exportRect().eql(.{ .x = 0, .y = 0, .w = 300, .h = 200 }));
    // a selection entirely off the image falls back to the whole image
    d.sel = .{ .x = 400, .y = 0, .w = 10, .h = 10 };
    try testing.expect(d.exportRect().eql(d.imageRect()));
}

test "export intersects a selection hanging off the image" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 300, 200);
    defer d.deinit();
    d.sel = .{ .x = 250, .y = -20, .w = 100, .h = 70 };
    try testing.expect(d.exportRect().eql(.{ .x = 250, .y = 0, .w = 50, .h = 50 }));
    // unnormalized (mid-drag) selections work too
    d.sel = .{ .x = 50, .y = 60, .w = -60, .h = -10 };
    try testing.expect(d.exportRect().eql(.{ .x = 0, .y = 50, .w = 50, .h = 10 }));
}

test "export geometry is native, independent of the view scale" {
    const alloc = testing.allocator;
    const view_mod = @import("view.zig");
    const iw = 1920;
    const ih = 1080;
    const img = try testImage(alloc, iw, ih);
    defer alloc.free(img);
    // the same buffer-space drag at several fits selects the same image area
    const cases = [_]struct { area: Rect, max: f64 }{
        .{ .area = .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .max = 1 }, // fit < 1 (0.8333)
        .{ .area = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, .max = 1 }, // fit = 1
        .{ .area = .{ .x = 0, .y = 0, .w = 3840, .h = 2160 }, .max = 2 }, // fit > 1
        .{ .area = .{ .x = 0, .y = 0, .w = 1366, .h = 1000 }, .max = 1 }, // fractional, letterboxed
    };
    for (cases) |c| {
        const v = view_mod.View.fit(iw, ih, c.area, c.max);
        var d = Document.init(alloc, iw, ih);
        defer d.deinit();
        // the user drags the buffer rect showing image (100,100)-(740,460)
        const b = v.rectToBuf(.{ .x = 100, .y = 100, .w = 640, .h = 360 });
        const a = v.toImgEdge(.{ .x = b.x, .y = b.y });
        const z = v.toImgEdge(.{ .x = b.right(), .y = b.bottom() });
        d.sel = Rect.fromCorners(a, z);
        const r = d.exportRect();
        try testing.expect(@abs(r.x - 100) <= 1 and @abs(r.y - 100) <= 1);
        try testing.expect(@abs(r.w - 640) <= 2 and @abs(r.h - 360) <= 2);
        const out = try exportImage(alloc, img, iw, ih, r, .{});
        defer alloc.free(out.pixels);
        try testing.expectEqual(@as(u32, @intCast(r.w)), out.width);
        try testing.expectEqual(@as(u32, @intCast(r.h)), out.height);
        // pixels come straight from the native image: no letterbox, no scaling
        const ry: usize = @intCast(r.y);
        const rx: usize = @intCast(r.x);
        try testing.expectEqual(img[ry * iw + rx], out.pixels[0]);
        try testing.expectEqual(img[(ry + 5) * iw + rx + 7], out.pixels[5 * out.width + 7]);
        // whole-image export at this fit
        const whole = try exportImage(alloc, img, iw, ih, Document.init(alloc, iw, ih).exportRect(), .{});
        defer alloc.free(whole.pixels);
        try testing.expectEqual(@as(u32, iw), whole.width);
        try testing.expectEqual(@as(u32, ih), whole.height);
        try testing.expectEqualSlices(u32, img, whole.pixels);
    }
}

test "beautify sizes and framing" {
    const alloc = testing.allocator;
    const b: Beautify = .{ .enabled = true };
    const g = b.geometry(1000, 500);
    try testing.expectEqual(@as(u32, 70), g.pad);
    try testing.expectEqual(@as(u32, 1140), g.out_w);
    try testing.expectEqual(@as(u32, 640), g.out_h);
    try testing.expectEqual(@as(u32, 12), g.radius);
    // small shots still get a visible frame
    const gs = b.geometry(40, 20);
    try testing.expectEqual(@as(u32, 16), gs.pad);
    try testing.expect(gs.radius <= 10);
    // disabled: identity
    const off = (Beautify{}).geometry(40, 20);
    try testing.expectEqual(@as(u32, 40), off.out_w);
    // padding levels; none keeps the size (rounded corners only)
    try testing.expectEqual(@as(u32, 1000), (Beautify{ .enabled = true, .padding = 0 }).geometry(1000, 500).out_w);
    try testing.expectEqual(@as(u32, 1080), (Beautify{ .enabled = true, .padding = 1 }).geometry(1000, 500).out_w);
    try testing.expectEqual(@as(u32, 1240), (Beautify{ .enabled = true, .padding = 3 }).geometry(1000, 500).out_w);
    try testing.expectEqual(@as(u32, 0), (Beautify{ .enabled = true, .padding = 0 }).geometry(1000, 500).shadow_blur);
    try testing.expectEqual(@as(u32, 0), (Beautify{ .enabled = true, .rounded = false }).geometry(1000, 500).radius);

    const img = try testImage(alloc, 200, 100);
    defer alloc.free(img);
    const out = try exportImage(alloc, img, 200, 100, .{ .x = 10, .y = 10, .w = 100, .h = 50 }, b);
    defer alloc.free(out.pixels);
    const gg = b.geometry(100, 50);
    try testing.expectEqual(gg.out_w, out.width);
    try testing.expectEqual(gg.out_h, out.height);
    // centre of the shot is the image pixel, corners are background
    const cx = gg.pad + 50;
    const cy = gg.pad + 25;
    try testing.expectEqual(img[(10 + 25) * 200 + 10 + 50], out.pixels[cy * out.width + cx]);
    try testing.expectEqual(b.background().from, out.pixels[0]);
}

test "undo and redo cover add, move, recolour, delete, duplicate and z-order" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    try d.checkpoint();
    _ = try d.add(.{ .tool = .rect, .color = 1, .thickness = 2, .p1 = .{ .x = 10, .y = 10 } });
    try d.checkpoint();
    _ = try d.add(.{ .tool = .counter, .color = 2, .thickness = 2, .number = d.nextNumber() });
    try testing.expectEqual(@as(u32, 1), d.shapes.items[1].number);
    try d.checkpoint();
    d.shapes.items[0].translate(5, 5);
    d.shapes.items[0].color = 9;
    try d.checkpoint();
    const dup = try d.duplicate(1, 10, 10);
    try testing.expectEqual(@as(u32, 2), d.shapes.items[dup].number);
    try d.checkpoint();
    _ = d.bringToFront(0);
    try testing.expectEqual(shapes.Tool.rect, d.shapes.items[2].tool);
    try d.checkpoint();
    d.remove(2);
    try testing.expectEqual(@as(usize, 2), d.shapes.items.len);

    try testing.expect(try d.undo()); // delete
    try testing.expectEqual(@as(usize, 3), d.shapes.items.len);
    try testing.expect(try d.undo()); // z-order
    try testing.expectEqual(shapes.Tool.rect, d.shapes.items[0].tool);
    try testing.expect(try d.undo()); // duplicate
    try testing.expectEqual(@as(usize, 2), d.shapes.items.len);
    try testing.expect(try d.undo()); // move + recolour
    try testing.expectEqual(@as(i32, 0), d.shapes.items[0].p0.x);
    try testing.expectEqual(@as(u32, 1), d.shapes.items[0].color);
    try testing.expect(try d.redo());
    try testing.expectEqual(@as(u32, 9), d.shapes.items[0].color);
    try testing.expect(try d.undo());
    try testing.expect(try d.undo());
    try testing.expect(try d.undo());
    try testing.expectEqual(@as(usize, 0), d.shapes.items.len);
    try testing.expect(!try d.undo());
    // a new change clears redo
    try d.checkpoint();
    _ = try d.add(.{ .tool = .line, .color = 1, .thickness = 1 });
    try testing.expect(!try d.redo());
    d.dropCheckpoint();
    try testing.expect(!try d.undo());
}

test "hit picks the topmost shape" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    _ = try d.add(.{ .tool = .redact, .color = 1, .thickness = 2, .p1 = .{ .x = 50, .y = 50 } });
    _ = try d.add(.{ .tool = .redact, .color = 2, .thickness = 2, .p0 = .{ .x = 20, .y = 20 }, .p1 = .{ .x = 60, .y = 60 } });
    try testing.expectEqual(@as(?usize, 1), d.hit(.{ .x = 30, .y = 30 }, 1));
    try testing.expectEqual(@as(?usize, 0), d.hit(.{ .x = 5, .y = 5 }, 1));
    try testing.expectEqual(@as(?usize, null), d.hit(.{ .x = 90, .y = 90 }, 1));
}

test "keyboard selection moves stay inside the image" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 80);
    defer d.deinit();
    d.sel = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    d.moveSelection(-50, 0);
    try testing.expectEqual(@as(i32, 0), d.sel.?.x);
    d.moveSelection(500, 500);
    try testing.expect(d.sel.?.eql(.{ .x = 80, .y = 60, .w = 20, .h = 20 }));
    d.resizeSelection(10, -100);
    try testing.expect(d.sel.?.eql(.{ .x = 80, .y = 60, .w = 20, .h = 1 }));
}

test "region recompose matches a full redraw" {
    const alloc = testing.allocator;
    const w = 120;
    const h = 90;
    const img = try testImage(alloc, w, h);
    defer alloc.free(img);
    var d = Document.init(alloc, w, h);
    defer d.deinit();
    _ = try d.add(.{ .tool = .pixelate, .color = 0, .thickness = 2, .p0 = .{ .x = 5, .y = 5 }, .p1 = .{ .x = 100, .y = 70 } });
    _ = try d.add(.{ .tool = .rect, .color = 0xFFFF0000, .thickness = 3, .p0 = .{ .x = 20, .y = 20 }, .p1 = .{ .x = 60, .y = 50 } });
    _ = try d.add(.{ .tool = .blur, .color = 0, .thickness = 1, .p0 = .{ .x = 30, .y = 40 }, .p1 = .{ .x = 110, .y = 85 } });
    const full = try alloc.alloc(u32, w * h);
    defer alloc.free(full);
    try composeRegion(alloc, full, img, w, h, d.shapes.items, null, d.imageRect());
    const part = try alloc.dupe(u32, img);
    defer alloc.free(part);
    // compose in four tiles
    const tiles = [_]Rect{
        .{ .x = 0, .y = 0, .w = 60, .h = 45 },  .{ .x = 60, .y = 0, .w = 60, .h = 45 },
        .{ .x = 0, .y = 45, .w = 60, .h = 45 }, .{ .x = 60, .y = 45, .w = 60, .h = 45 },
    };
    for (tiles) |t| try composeRegion(alloc, part, img, w, h, d.shapes.items, null, t);
    try testing.expectEqualSlices(u32, full, part);
    // painting the top shape over a layer of the others matches too
    try composeRegion(alloc, part, img, w, h, d.shapes.items[0..2], null, d.imageRect());
    try paintOnTop(alloc, part, w, h, &d.shapes.items[2]);
    try testing.expectEqualSlices(u32, full, part);
    // skipping a shape leaves its pixels as the image underneath
    try composeRegion(alloc, part, img, w, h, d.shapes.items[1..2], 0, d.imageRect());
    try testing.expectEqualSlices(u32, img, part);
}
