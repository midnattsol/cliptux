//! Annotation shape model and rendering: geometry, tools, palette, the
//! shape display list painter, selection handles and the text-input keymap.

const std = @import("std");
const render = @import("render.zig");
const text_mod = @import("text.zig");

const Canvas = render.Canvas;

pub const Tool = enum {
    select,
    pen,
    line,
    arrow,
    rect,
    ellipse,
    highlight,
    pixelate,
    counter,
    text,
};

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

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
};

pub const Shape = struct {
    tool: Tool,
    color: u32,
    thickness: i32,
    p0: Point = .{ .x = 0, .y = 0 },
    p1: Point = .{ .x = 0, .y = 0 },
    points: std.ArrayList(Point) = .empty,
    number: u32 = 0,
    str: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Shape, alloc: std.mem.Allocator) void {
        self.points.deinit(alloc);
        self.str.deinit(alloc);
    }
};

pub const palette = [8]u32{
    0xFFE03131, // red
    0xFFFF922B, // orange
    0xFFFFD43B, // yellow
    0xFF51CF66, // green
    0xFF339AF0, // blue
    0xFFCC5DE8, // magenta
    0xFFFFFFFF, // white
    0xFF1A1A1A, // black
};

// --- shape drawing ---

pub fn drawShape(canvas: *Canvas, s: *const Shape, with_caret: bool) void {
    const tf: f64 = @floatFromInt(@max(1, s.thickness));
    switch (s.tool) {
        .pen => canvas.strokePolylineAA(s.points.items, tf, s.color),
        .highlight => {
            const hl = (s.color & 0x00FFFFFF) | 0x59000000;
            canvas.strokePolylineAA(s.points.items, tf * 3.0, hl);
        },
        .line => {
            const seg = [_]Point{ s.p0, s.p1 };
            canvas.strokePolylineAA(seg[0..], tf, s.color);
        },
        .arrow => canvas.arrowAA(s.p0.x, s.p0.y, s.p1.x, s.p1.y, s.thickness, s.color),
        .rect => {
            const r = (Rect{ .x = s.p0.x, .y = s.p0.y, .w = s.p1.x - s.p0.x, .h = s.p1.y - s.p0.y }).normalized();
            canvas.rectOutline(r.x, r.y, r.w, r.h, s.thickness, s.color);
        },
        .ellipse => {
            const r = (Rect{ .x = s.p0.x, .y = s.p0.y, .w = s.p1.x - s.p0.x, .h = s.p1.y - s.p0.y }).normalized();
            canvas.ellipseRingAA(r.x, r.y, r.w, r.h, tf, s.color);
        },
        .pixelate => {
            const r = (Rect{ .x = s.p0.x, .y = s.p0.y, .w = s.p1.x - s.p0.x, .h = s.p1.y - s.p0.y }).normalized();
            canvas.pixelate(r.x, r.y, r.w, r.h, 6 + s.thickness * 2);
        },
        .counter => {
            const r: f64 = @floatFromInt(12 + s.thickness);
            const cx: f64 = @floatFromInt(s.p0.x);
            const cy: f64 = @floatFromInt(s.p0.y);
            canvas.fillCircleAA(cx, cy, r, s.color);
            canvas.ringAA(cx, cy, r, 2.0, 0xFFFFFFFF);
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{s.number}) catch "?";
            const fs = r * 1.15;
            text_mod.draw(canvas, s.p0.x - @divTrunc(text_mod.width(fs, label), 2), s.p0.y - @divTrunc(text_mod.height(fs), 2), fs, contrastColor(s.color), label);
        },
        .text => {
            const fs = 14.0 + @as(f64, @floatFromInt(s.thickness)) * 3.0;
            text_mod.draw(canvas, s.p0.x, s.p0.y, fs, s.color, s.str.items);
            if (with_caret) {
                const cx = s.p0.x + text_mod.width(fs, s.str.items) + 2;
                canvas.fillRect(cx, s.p0.y, 2, text_mod.height(fs), s.color);
            }
        },
        .select => {},
    }
}

pub fn contrastColor(c: u32) u32 {
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    const lum = (r * 299 + g * 587 + b * 114) / 1000;
    return if (lum > 140) 0xFF1A1A1A else 0xFFFFFFFF;
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

pub fn handleAt(s: Rect, m: Point) ?u3 {
    for (handlePoints(s), 0..) |p, i| {
        if (@abs(m.x - p.x) <= 11 and @abs(m.y - p.y) <= 11) return @intCast(i);
    }
    return null;
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

// --- keyboard text input (US-ish layout approximation) ---

pub fn evdevToChar(code: u32, shift: bool) ?u8 {
    const lower = "1234567890";
    const upper = "!@#$%^&*()";
    if (code >= 2 and code <= 11) {
        const i = code - 2;
        return if (shift) upper[i] else lower[i];
    }
    const row1 = "qwertyuiop";
    if (code >= 16 and code <= 25) {
        const c = row1[code - 16];
        return if (shift) c - 32 else c;
    }
    const row2 = "asdfghjkl";
    if (code >= 30 and code <= 38) {
        const c = row2[code - 30];
        return if (shift) c - 32 else c;
    }
    const row3 = "zxcvbnm";
    if (code >= 44 and code <= 50) {
        const c = row3[code - 44];
        return if (shift) c - 32 else c;
    }
    return switch (code) {
        57 => ' ',
        12 => if (shift) @as(u8, '_') else '-',
        13 => if (shift) @as(u8, '+') else '=',
        26 => if (shift) @as(u8, '{') else '[',
        27 => if (shift) @as(u8, '}') else ']',
        39 => if (shift) @as(u8, ':') else ';',
        40 => if (shift) @as(u8, '"') else '\'',
        41 => if (shift) @as(u8, '~') else '`',
        43 => if (shift) @as(u8, '|') else '\\',
        51 => if (shift) @as(u8, '<') else ',',
        52 => if (shift) @as(u8, '>') else '.',
        53 => if (shift) @as(u8, '?') else '/',
        else => null,
    };
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

test "evdev to char mapping" {
    try std.testing.expectEqual(@as(?u8, 'a'), evdevToChar(30, false));
    try std.testing.expectEqual(@as(?u8, 'A'), evdevToChar(30, true));
    try std.testing.expectEqual(@as(?u8, '1'), evdevToChar(2, false));
    try std.testing.expectEqual(@as(?u8, '!'), evdevToChar(2, true));
    try std.testing.expectEqual(@as(?u8, ' '), evdevToChar(57, false));
    try std.testing.expectEqual(@as(?u8, null), evdevToChar(1, false)); // Esc
}

test "selection handle resolution" {
    const s = Rect{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expectEqual(@as(?u3, 0), handleAt(s, .{ .x = 10, .y = 10 })); // nw
    try std.testing.expectEqual(@as(?u3, 4), handleAt(s, .{ .x = 110, .y = 110 })); // se
    try std.testing.expectEqual(@as(?u3, null), handleAt(s, .{ .x = 60, .y = 60 })); // center
    const grown = resizeWithHandle(s, 4, .{ .x = 150, .y = 130 });
    try std.testing.expectEqual(@as(i32, 140), grown.w);
    try std.testing.expectEqual(@as(i32, 120), grown.h);
}
