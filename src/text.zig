//! High-level text drawing: system TrueType font when available, bitmap
//! 5x7 fallback otherwise. Sizes are in pixels (already display-scaled).

const std = @import("std");
const ttf = @import("ttf.zig");
const render = @import("render.zig");

const Canvas = render.Canvas;

var font: ?ttf.Font = null;

const candidates = [_][]const u8{
    "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
};

/// Try to load a system font once at startup. Safe to call repeatedly.
pub fn init(alloc: std.mem.Allocator) void {
    if (font != null) return;
    for (candidates) |path| {
        font = ttf.Font.load(alloc, path) catch continue;
        return;
    }
    std.log.warn("no system TTF found; falling back to the bitmap font", .{});
}

pub fn deinit() void {
    if (font) |*f| f.deinit();
    font = null;
}

pub fn available() bool {
    return font != null;
}

/// Draw text with the top-left corner at (x, y).
pub fn draw(canvas: *Canvas, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    if (font) |*f| {
        drawTtf(canvas, f, x, y, size_px, color, s);
        return;
    }
    const scale = bitmapScale(size_px);
    canvas.text(x, y, scale, color, s);
}

pub fn width(size_px: f64, s: []const u8) i32 {
    if (font) |*f| {
        var total: f64 = 0;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| {
            const g = f.rasterize(f.glyphIndex(cp), size_px) catch continue;
            total += g.advance;
        }
        return @intFromFloat(@ceil(total));
    }
    return Canvas.textWidth(bitmapScale(size_px), s);
}

pub fn height(size_px: f64) i32 {
    if (font) |*f| {
        return @intFromFloat(@ceil(f.lineHeightPx(size_px)));
    }
    return Canvas.textHeight(bitmapScale(size_px));
}

fn bitmapScale(size_px: f64) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(size_px / 8.0))));
}

fn drawTtf(canvas: *Canvas, f: *ttf.Font, x: i32, y: i32, size_px: f64, color: u32, s: []const u8) void {
    const baseline = @as(f64, @floatFromInt(y)) + f.ascentPx(size_px);
    var pen: f64 = @floatFromInt(x);
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const g = f.rasterize(f.glyphIndex(cp), size_px) catch continue;
        if (g.w > 0) {
            const gx = @as(i32, @intFromFloat(@round(pen))) + g.bearing_x;
            const gy = @as(i32, @intFromFloat(@round(baseline))) + g.bearing_y;
            blitAlpha(canvas, gx, gy, g, color);
        }
        pen += g.advance;
    }
}

fn blitAlpha(canvas: *Canvas, x0: i32, y0: i32, g: *const ttf.Glyph, color: u32) void {
    const base_a: u32 = color >> 24;
    var gy: i32 = 0;
    while (gy < g.h) : (gy += 1) {
        var gx: i32 = 0;
        while (gx < g.w) : (gx += 1) {
            const cov = g.alpha[@intCast(gy * g.w + gx)];
            if (cov == 0) continue;
            const a = (base_a * cov) / 255;
            canvas.blend(x0 + gx, y0 + gy, (color & 0x00FFFFFF) | (a << 24));
        }
    }
}

test {
    _ = @import("ttf.zig");
}
