//! Drawing a text shape: optional pill background, the wrapped lines,
//! and while editing the selection highlight and the caret.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const textbox = @import("../textbox.zig");
const geometry = @import("geometry.zig");
const model = @import("model.zig");
const raster = @import("raster.zig");

const Canvas = render.Canvas;
const Xform = geometry.Xform;
const Shape = model.Shape;
const drawShape = @import("draw.zig").drawShape;

/// Caret (byte offset) and selected byte range of a text being edited.
pub const TextCursor = struct {
    caret: usize,
    sel: ?[2]usize = null,
    /// the caret sits at the end of the line above a soft break
    upstream: bool = false,
};

pub const selection_color: u32 = 0x804DABF7;

/// One laid-out line being drawn: its layout, index and canvas origin.
const LineCtx = struct {
    lay: *const textbox.Layout,
    str: []const u8,
    i: usize,
    fs: f64,
    lh: i32,
    x0: i32,
    y: i32,
};

pub fn drawText(canvas: *Canvas, alloc: std.mem.Allocator, s: *const Shape, xf: Xform, cursor: ?TextCursor) void {
    const str = s.str.items;
    // line breaks come from the image-size layout, so the preview at any
    // zoom wraps exactly like the export
    var lay = textbox.Layout.init(alloc, str, s.fontPx(), s.box_w) catch return;
    defer lay.deinit(alloc);
    const fs = s.fontPx() * xf.scale;
    const lh = text_mod.height(fs);
    const fg = if (s.pill) raster.contrastColor(s.color) else s.color;
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
        const lc: LineCtx = .{ .lay = &lay, .str = str, .i = i, .fs = fs, .lh = lh, .x0 = box_x + lay.indentAt(str, i, fs, box_w), .y = y };
        if (cursor) |cur| if (cur.sel) |sel| drawLineSelection(canvas, lc, sel);
        text_mod.drawRange(canvas, lc.x0, y, fs, fg, .regular, para, la, lb, l.dir());
        if (caret_line == i) drawCaret(canvas, lc, cursor.?.caret, fg);
        y += lh;
    }
}

/// The part of the selection `sel` on this line (+ a sliver for its
/// newline or hanging spaces).
fn drawLineSelection(canvas: *Canvas, lc: LineCtx, sel: [2]usize) void {
    const l = lc.lay.lines.items[lc.i];
    const para, const la, const lb = lc.lay.paraOf(lc.str, lc.i);
    const ps = l.para_start;
    const a = @max(sel[0], l.start);
    const b = @min(sel[1], l.end + @intFromBool(!l.soft and l.end < lc.str.len));
    if (a >= b) return;
    // the glyphs' own extents, so a range across both directions
    // highlights each part where it is drawn
    var spans: [16][2]i32 = undefined;
    const ns = text_mod.rangeSpansLine(lc.fs, .regular, para, la, lb, @min(a, l.vis_end) - ps, @min(b, l.vis_end) - ps, l.dir(), &spans);
    for (spans[0..ns]) |sp| canvas.fillRect(lc.x0 + sp[0], lc.y, sp[1] - sp[0], lc.lh, selection_color);
    if (b > l.vis_end) {
        // a sliver for the newline or the hanging spaces, at the
        // paragraph's end side
        const sliver: i32 = @intFromFloat(@round(lc.fs * 0.25));
        const ex = if (l.rtl) lc.x0 - sliver else lc.x0 + lc.lay.lineWidth(lc.str, lc.i, lc.fs);
        canvas.fillRect(ex, lc.y, sliver, lc.lh, selection_color);
    }
}

fn drawCaret(canvas: *Canvas, lc: LineCtx, caret: usize, fg: u32) void {
    const l = lc.lay.lines.items[lc.i];
    const para, const la, const lb = lc.lay.paraOf(lc.str, lc.i);
    const c = std.math.clamp(caret, l.start, l.vis_end);
    const cx = lc.x0 + text_mod.xForOffsetRange(lc.fs, .regular, para, la, lb, c - l.para_start, l.dir());
    const cw: i32 = @max(1, @as(i32, @intFromFloat(@round(lc.fs / 14.0))));
    canvas.fillRect(cx, lc.y, cw, lc.lh, fg);
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
