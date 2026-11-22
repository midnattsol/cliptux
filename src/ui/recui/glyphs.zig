//! The recorder's own line icons (same 24-unit style as icons.zig):
//! microphone, speaker, a click, film, scissors, play.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const path = @import("../../gfx/path.zig");

pub const Glyph = enum { mic, speaker, click, film, scissors, play, pause };

fn data(g: Glyph) []const u8 {
    return switch (g) {
        .mic => "M12 3a3 3 0 0 0-3 3v5a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM6 11a6 6 0 0 0 12 0M12 17v4M9 21h6",
        .speaker => "M4 9h4l5-4v14l-5-4H4zM16.5 9a4 4 0 0 1 0 6M19 6.5a7.5 7.5 0 0 1 0 11",
        .click => "M9 9l11 4-5 2-2 5zM5 5l2 2M9 3v2.5M3 9h2.5",
        .film => "M4 5h16v14H4zM8 5v14M16 5v14M4 9h4M4 15h4M16 9h4M16 15h4",
        .scissors => "M6 4a2.5 2.5 0 1 0 0 5a2.5 2.5 0 1 0 0-5zM6 15a2.5 2.5 0 1 0 0 5a2.5 2.5 0 1 0 0-5zM8 8l12 9M8 16l12-9",
        .play => "M8 5l11 7-11 7z",
        .pause => "M8 5v14M16 5v14",
    };
}

/// Draw `g` with its top-left at x, y, `size` px square.
pub fn draw(canvas: *render.Canvas, g: Glyph, x: i32, y: i32, size: i32, color: u32) void {
    if (size <= 0 or size > 256) return;
    const n: usize = @intCast(size);
    var mask: [256 * 256]u8 = undefined;
    path.rasterizeFitted(mask[0 .. n * n], n, data(g), 24, if (g == .pause) 2.5 else 1.75) catch return;
    const ca: u32 = color >> 24;
    const rgb = color & 0x00FFFFFF;
    for (0..n) |row| for (0..n) |col| {
        const cv: u32 = mask[row * n + col];
        if (cv == 0) continue;
        canvas.blend(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), rgb | (((ca * cv + 127) / 255) << 24));
    };
}

pub fn drawCentered(canvas: *render.Canvas, g: Glyph, cx: i32, cy: i32, size: i32, color: u32) void {
    draw(canvas, g, cx - @divFloor(size, 2), cy - @divFloor(size, 2), size, color);
}

test "every glyph draws" {
    var px: [32 * 32]u32 = undefined;
    var c = render.Canvas.init(&px, 32, 32);
    inline for (@typeInfo(Glyph).@"enum".field_names) |name| {
        @memset(&px, 0xFF000000);
        draw(&c, @field(Glyph, name), 4, 4, 24, 0xFFFFFFFF);
        var lit: usize = 0;
        for (px) |p| lit += @intFromBool(p != 0xFF000000);
        try std.testing.expect(lit > 4);
    }
}
