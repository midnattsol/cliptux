//! Stroke icons for the UI, drawn from SVG path data in a 24-unit box
//! (1.75 stroke, round caps and joins), grid-fitted to the pixel size
//! (gfx/hint.zig) and cached as coverage masks per (icon, pixel size,
//! stroke), so any colour and any scale stay crisp.
//!
//! Stable API:
//!   Icon                   the catalogue (paths below)
//!   draw(canvas, icon, x, y, size_px, color)        default stroke
//!   drawStroke(canvas, icon, x, y, size_px, stroke_units, color)
//!   drawCentered(canvas, icon, cx, cy, size_px, color)   centre in px
//!   deinit()               free the cache (optional; process exit)
//! Sizes are physical pixels: pass round(logical * scale).

const std = @import("std");
const render = @import("../gfx/render.zig");
const path = @import("../gfx/path.zig");
const theme = @import("theme.zig");

pub const Icon = enum {
    // tools
    select,
    pen,
    arrow,
    rect,
    ellipse,
    line,
    highlight,
    blur,
    pixelate,
    redact,
    counter,
    text,
    spotlight,
    ruler,
    eyedropper,
    crop,
    // toolbar and menus
    chevron_down,
    undo,
    redo,
    save,
    save_as,
    more,
    copy,
    close,
    pin,
    check,
    beautify,
    keyboard,
    // beautify panel
    background,
    padding,
    corners,
    shadow,
    // text box width
    width_fit,
    width_fixed,
    // windows
    gear,
    folder,
    plus,
    search,
    trash,
    // editor tools in the More menu
    scan_text,
    shield,
    // capture modes
    capture_window,
    capture_scroll,
    timer,
};

/// Path data, 24x24 units. The first block is the "Glass" mockup's set.
pub fn data(icon: Icon) []const u8 {
    return switch (icon) {
        .select => "M6 3l12 7-5.5 1.5L10 17z",
        .pen => "M4 20l4-1 11-11-3-3L5 16zM14 6l3 3",
        .arrow => "M5 19L19 5M9 5h10v10",
        .rect => "M4 6h16v12H4z",
        .ellipse => "M12 5c4.4 0 8 3.1 8 7s-3.6 7-8 7-8-3.1-8-7 3.6-7 8-7z",
        .line => "M5 19L19 5",
        .highlight => "M15 4l5 5-8 8H8v-4zM4 21h16",
        .blur => "M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z",
        .counter => "M12 4a8 8 0 1 0 0 16a8 8 0 1 0 0-16zM11 9.5l2-1.5v8",
        .text => "M5 7V5h14v2M12 5v14M9 19h6",
        .chevron_down => "M6 9l6 6 6-6",
        .undo => "M9 14L4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3",
        .redo => "M15 14l5-5-5-5M20 9H10a6 6 0 0 0 0 12h3",
        .save => "M12 4v11M7 10l5 5 5-5M5 20h14",
        .more => "M6 12h.01M12 12h.01M18 12h.01",
        .copy => "M9 9h10v10H9zM5 15V5h10",
        .close => "M7 7l10 10M17 7L7 17",
        .pin => "M12 16v5M8 3h8l-1 6 3 3H6l3-3z",
        .gear => "M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6zM12 2v3M12 19v3M2 12h3M19 12h3",
        .keyboard => "M3 7h18v10H3zM7 11h.01M11 11h.01M15 11h.01M8 14h8",
        .folder => "M3 7h6l2 2h10v10H3z",
        .plus => "M12 5v14M5 12h14",
        .search => "M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14zM20 20l-4-4",
        // same style, for what the mockup does not show
        .pixelate => "M4 4h16v16H4zM9.33 4v16M14.67 4v16M4 9.33h16M4 14.67h16",
        .redact => "M4 7h16v10H4zM8 10.5h8M8 13.5h5",
        .save_as => "M3 7h6l2 2h10v10H3zM12 11.5v5M9.5 14l2.5 2.5 2.5-2.5",
        .check => "M5 12.5l4.5 4.5L19 7.5",
        .beautify => "M12 3l1.8 4.2L18 9l-4.2 1.8L12 15l-1.8-4.2L6 9l4.2-1.8zM18.5 15l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z",
        .background => "M4 5h16v14H4zM4 15l5-5 4 4 2.5-2.5L20 16",
        .padding => "M4 4h16v16H4zM9 9h6v6H9z",
        .corners => "M4 20v-9a7 7 0 0 1 7-7h9",
        .shadow => "M4 4h12v12H4zM8 20h12V8",
        .width_fit => "M4 12h16M7.5 8.5L4 12l3.5 3.5M16.5 8.5L20 12l-3.5 3.5",
        .width_fixed => "M4 6h12M4 11h12M4 16h8M20 4v16",
        .trash => "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
        .spotlight => "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8zM4 4h16v16H4z",
        .ruler => "M3 16L16 3l5 5L8 21zM7 12l2 2M10 9l2 2M13 6l2 2",
        .eyedropper => "M14 6l4 4M16 4l4 4-3 3-4-4zM13 9l-8 8v2h2l8-8",
        .crop => "M6 2v16h16M2 6h16v16",
        .scan_text => "M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4M8 10h8M8 14h5",
        .shield => "M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6zM9 12l2 2 4-4",
        .capture_window => "M3 5h18v14H3zM3 9h18",
        .capture_scroll => "M7 3h10v18H7zM12 8v8M9 13l3 3 3-3",
        .timer => "M12 6c4.4 0 8 3.6 8 8s-3.6 8-8 8-8-3.6-8-8 3.6-8 8-8zM12 10v4l2.5 1.5M10 2h4",
    };
}

/// Stroke in icon units: the mockup draws the dots heavier.
pub fn defaultStroke(icon: Icon) f64 {
    return switch (icon) {
        .more => 2.5,
        .chevron_down, .copy, .close => 2,
        else => theme.icon_stroke,
    };
}

const Entry = struct {
    icon: Icon,
    size: u16,
    stroke_milli: u16,
    mask: []u8,
};

var cache: std.ArrayList(Entry) = .empty;
const cache_alloc = std.heap.page_allocator;
const max_entries = 256;

fn maskFor(icon: Icon, size: usize, stroke_units: f64) ?[]const u8 {
    if (size == 0 or size > 512) return null;
    const sm: u16 = @intFromFloat(@round(std.math.clamp(stroke_units, 0, 60) * 1000));
    for (cache.items) |e| {
        if (e.icon == icon and e.size == size and e.stroke_milli == sm) return e.mask;
    }
    const m = cache_alloc.alloc(u8, size * size) catch return null;
    path.rasterizeFitted(m, size, data(icon), 24, @floatCast(stroke_units)) catch {
        cache_alloc.free(m);
        return null;
    };
    if (cache.items.len >= max_entries) {
        // a bounded cache: drop the oldest
        cache_alloc.free(cache.items[0].mask);
        _ = cache.orderedRemove(0);
    }
    cache.append(cache_alloc, .{ .icon = icon, .size = @intCast(size), .stroke_milli = sm, .mask = m }) catch {
        cache_alloc.free(m);
        return null;
    };
    return m;
}

pub fn deinit() void {
    for (cache.items) |e| cache_alloc.free(e.mask);
    cache.deinit(cache_alloc);
    cache = .empty;
}

/// Draw `icon` with its top-left corner at (x, y), `size_px` square.
pub fn draw(canvas: *render.Canvas, icon: Icon, x: i32, y: i32, size_px: i32, color: u32) void {
    drawStroke(canvas, icon, x, y, size_px, defaultStroke(icon), color);
}

/// Draw `icon` centred on (cx, cy).
pub fn drawCentered(canvas: *render.Canvas, icon: Icon, cx: i32, cy: i32, size_px: i32, color: u32) void {
    draw(canvas, icon, cx - @divFloor(size_px, 2), cy - @divFloor(size_px, 2), size_px, color);
}

pub fn drawStroke(canvas: *render.Canvas, icon: Icon, x: i32, y: i32, size_px: i32, stroke_units: f64, color: u32) void {
    if (size_px <= 0) return;
    const size: usize = @intCast(size_px);
    const m = maskFor(icon, size, stroke_units) orelse return;
    const ca: u32 = color >> 24;
    const rgb = color & 0x00FFFFFF;
    for (0..size) |row| {
        const py = y + @as(i32, @intCast(row));
        if (py < 0 or py >= canvas.h) continue;
        for (0..size) |col| {
            const cv: u32 = m[row * size + col];
            if (cv == 0) continue;
            const px = x + @as(i32, @intCast(col));
            canvas.blend(px, py, rgb | (((ca * cv + 127) / 255) << 24));
        }
    }
}

test "every icon's path parses and draws something" {
    defer deinit();
    var px: [32 * 32]u32 = @splat(0xFF000000);
    var c = render.Canvas.init(&px, 32, 32);
    inline for (@typeInfo(Icon).@"enum".field_names) |name| {
        const icon = @field(Icon, name);
        var flat: path.Flat = .{};
        try path.flatten(data(icon), 1, 0, 0, &flat);
        try std.testing.expect(flat.n > 0);
        @memset(&px, 0xFF000000);
        draw(&c, icon, 4, 4, 24, 0xFFFFFFFF);
        var lit: usize = 0;
        for (px) |p| lit += @intFromBool(p != 0xFF000000);
        try std.testing.expect(lit > 4);
    }
}
