//! Layout and drawing of the trim window (trimui.zig), in logical
//! pixels: the preview, the filmstrip with its start and end handles and
//! the playhead, and a row with play/pause, the times and the buttons.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const fui = @import("../floatui.zig");
const theme = @import("../theme.zig");
const glyphs = @import("glyphs.zig");
const Rect = @import("../shapes.zig").Rect;

pub const width = 720;
pub const height = 372;
/// Save: the accent, dark enough for its white label
const save_fill = theme.accentFill(theme.default_accent);
const save_fill_hover = theme.mix(save_fill, 0xFF000000, 0.12);
const margin = 16;
pub const preview: Rect = .{ .x = margin, .y = margin, .w = width - 2 * margin, .h = 236 };
pub const strip: Rect = .{ .x = margin + 10, .y = 268, .w = width - 2 * margin - 20, .h = 44 };
const row_y = 324;

pub const Part = enum { play, cancel, save, start, end, strip };

pub fn partRect(p: Part) Rect {
    return switch (p) {
        .play => .{ .x = margin, .y = row_y, .w = 36, .h = 32 },
        .save => .{ .x = width - margin - 132, .y = row_y, .w = 132, .h = 32 },
        .cancel => .{ .x = width - margin - 132 - 8 - 90, .y = row_y, .w = 90, .h = 32 },
        .strip, .start, .end => strip,
    };
}

pub const State = struct {
    duration_ms: i64,
    start_ms: i64,
    end_ms: i64,
    pos_ms: i64,
    playing: bool = false,
    hover: ?Part = null,
    busy: []const u8 = "",
    pic: []const u32 = &.{},
    pic_w: u32 = 0,
    pic_h: u32 = 0,
    strip_px: []const u32 = &.{},
    strip_w: u32 = 0,
    strip_h: u32 = 0,
};

pub fn xOf(ms: i64, duration: i64) i32 {
    const d = @max(1, duration);
    return strip.x + @as(i32, @intCast(@divTrunc(std.math.clamp(ms, 0, d) * strip.w, d)));
}

pub fn msAt(x: i32, duration: i64) i64 {
    const rel = std.math.clamp(x - strip.x, 0, strip.w);
    return @divTrunc(@as(i64, rel) * duration, strip.w);
}

pub fn hit(x: i32, y: i32, st: *const State) ?Part {
    for ([_]Part{ .play, .cancel, .save }) |p| {
        const r = partRect(p);
        if (x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h) return p;
    }
    if (y < strip.y - 6 or y >= strip.y + strip.h + 6) return null;
    const sx = xOf(st.start_ms, st.duration_ms);
    const ex = xOf(st.end_ms, st.duration_ms);
    if (@abs(x - sx) <= 10) return .start;
    if (@abs(x - ex) <= 10) return .end;
    if (x >= strip.x - 10 and x < strip.x + strip.w + 10) return .strip;
    return null;
}

fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

fn scr(r: Rect, k: f64) Rect {
    return .{ .x = sc(r.x, k), .y = sc(r.y, k), .w = sc(r.w, k), .h = sc(r.h, k) };
}

const bg: u32 = 0xFF1C1C1F;
const fg: u32 = 0xFFF5F5F7;
const muted: u32 = 0xFFA1A1AA;
const handle: u32 = 0xFFFFCC00;

pub fn paint(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State) void {
    @memset(cv.px, bg);
    paintPreview(gpa, cv, k, st);
    paintStrip(gpa, cv, k, st);
    paintRow(cv, k, st);
}

fn paintPreview(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State) void {
    const r = scr(preview, k);
    if (st.pic_w == 0) return;
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    const buf = gpa.alloc(u32, @as(usize, w) * h) catch return;
    defer gpa.free(buf);
    fitInto(buf, w, h, st.pic, st.pic_w, st.pic_h);
    for (0..h) |y| @memcpy(cv.px[(@as(usize, @intCast(r.y)) + y) * @as(usize, @intCast(cv.w)) + @as(usize, @intCast(r.x)) ..][0..w], buf[y * w ..][0..w]);
}

/// Letterboxed (never cropped), smooth enough for a preview.
fn fitInto(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32) void {
    @memset(dst, 0xFF000000);
    const s = @min(@as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(sw)), @as(f64, @floatFromInt(dh)) / @as(f64, @floatFromInt(sh)));
    const tw: u32 = @intFromFloat(@as(f64, @floatFromInt(sw)) * s);
    const th: u32 = @intFromFloat(@as(f64, @floatFromInt(sh)) * s);
    const ox = (dw - tw) / 2;
    const oy = (dh - th) / 2;
    for (0..th) |y| for (0..tw) |x| {
        const fx = (@as(f64, @floatFromInt(x)) + 0.5) / s - 0.5;
        const fy = (@as(f64, @floatFromInt(y)) + 0.5) / s - 0.5;
        dst[(oy + y) * dw + ox + x] = fui.sampleBilinear(src, sw, sh, fx, fy) | 0xFF000000;
    };
}

fn paintStrip(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State) void {
    const r = scr(strip, k);
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    if (st.strip_w > 0) {
        const buf = gpa.alloc(u32, @as(usize, w) * h) catch return;
        defer gpa.free(buf);
        @import("../../encode/yuv.zig").downscale(st.strip_px, st.strip_w, st.strip_w, st.strip_h, buf, w, h);
        for (0..h) |y| @memcpy(cv.px[(@as(usize, @intCast(r.y)) + y) * @as(usize, @intCast(cv.w)) + @as(usize, @intCast(r.x)) ..][0..w], buf[y * w ..][0..w]);
    } else cv.fillRect(r.x, r.y, r.w, r.h, 0xFF2C2C30);
    const sx = sc(xOf(st.start_ms, st.duration_ms), k);
    const ex = sc(xOf(st.end_ms, st.duration_ms), k);
    // outside the range: dimmed
    cv.fillRect(r.x, r.y, sx - r.x, r.h, 0xB0000000);
    cv.fillRect(ex, r.y, r.x + r.w - ex, r.h, 0xB0000000);
    const bw = sc(3, k);
    cv.fillRect(sx, r.y - bw, ex - sx, bw, handle);
    cv.fillRect(sx, r.y + r.h, ex - sx, bw, handle);
    for ([_]i32{ sx, ex }, 0..) |x, i| {
        const hx = if (i == 0) x - sc(10, k) else x;
        cv.fillRoundRectAA(hx, r.y - bw, sc(10, k), r.h + 2 * bw, 3 * k, handle);
        cv.fillRect(hx + sc(4, k), r.y + @divTrunc(r.h, 2) - sc(7, k), sc(2, k), sc(14, k), 0xFF6B5300);
    }
    const px = sc(xOf(st.pos_ms, st.duration_ms), k);
    cv.fillRoundRectAA(px - sc(1, k), r.y - sc(6, k), sc(3, k), r.h + sc(12, k), 1.5 * k, fg);
}

fn paintRow(cv: *render.Canvas, k: f64, st: *const State) void {
    const p = scr(partRect(.play), k);
    if (st.hover == .play) cv.fillRoundRectAA(p.x, p.y, p.w, p.h, 8 * k, 0xFF34343A);
    glyphs.drawCentered(cv, if (st.playing) .pause else .play, p.x + @divTrunc(p.w, 2), p.y + @divTrunc(p.h, 2), sc(18, k), fg);
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var c: [80]u8 = undefined;
    const label = std.fmt.bufPrint(&c, "{s} \u{2013} {s}   \u{00B7}   {s}", .{ fmtMs(&a, st.start_ms), fmtMs(&b, st.end_ms), if (st.busy.len > 0) st.busy else lengthLabel(st) }) catch "";
    const fs = 13 * k;
    text.draw(cv, p.x + p.w + sc(12, k), p.y + @divTrunc(p.h - text.height(fs), 2), fs, muted, label);
    for ([_]Part{ .cancel, .save }) |part| {
        const r = scr(partRect(part), k);
        const save = part == .save;
        const col: u32 = if (save) (if (st.hover == part) save_fill_hover else save_fill) else (if (st.hover == part) 0xFF3A3A40 else 0xFF2C2C30);
        cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 8 * k, col);
        fui.textCentered(cv, r, 13 * k, fg, .bold, if (save) "Save trimmed" else "Cancel");
    }
}

var len_buf: [32]u8 = undefined;
fn lengthLabel(st: *const State) []const u8 {
    const ms = st.end_ms - st.start_ms;
    return std.fmt.bufPrint(&len_buf, "{d}.{d} s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) }) catch "";
}

pub fn fmtMs(buf: []u8, ms: i64) []const u8 {
    const t: u64 = @intCast(@max(0, ms));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d}", .{ t / 60000, t / 1000 % 60, t / 100 % 10 }) catch "";
}

test "timeline positions and hits" {
    const st: State = .{ .duration_ms = 4000, .start_ms = 1000, .end_ms = 3000, .pos_ms = 1000 };
    try std.testing.expectEqual(@as(i64, 1000), msAt(xOf(1000, 4000), 4000));
    try std.testing.expectEqual(@as(?Part, .start), hit(xOf(1000, 4000) + 3, strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .end), hit(xOf(3000, 4000) - 3, strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .strip), hit(xOf(2000, 4000), strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .save), hit(width - 30, row_y + 10, &st));
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1:02.5", fmtMs(&buf, 62_500));
}
