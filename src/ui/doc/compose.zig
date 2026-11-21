//! The document's native-resolution composite layer (the image with every
//! shape painted on it) and export: crop plus the optional beautify frame.

const std = @import("std");
const shapes = @import("../shapes.zig");
const render = @import("../../gfx/render.zig");
const doc = @import("../doc.zig");
const Shape = shapes.Shape;
const Rect = shapes.Rect;
const Beautify = doc.Beautify;
const Document = doc.Document;

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

test "export geometry is native, independent of the view scale" {
    const alloc = testing.allocator;
    const view_mod = @import("../view.zig");
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
