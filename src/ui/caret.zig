//! Where a click lands in a text annotation.

const std = @import("std");
const shapes = @import("shapes.zig");
const textbox = @import("textbox.zig");
const text_mod = @import("../gfx/text.zig");
const Shape = shapes.Shape;
const Point = shapes.Point;

/// Caret in text shape `s` nearest to image point `p` (bidi-aware and
/// across wrapped lines).
pub fn caretAt(s: *const Shape, p: Point) textbox.Hit {
    var buf: [8192]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&buf, std.heap.page_allocator);
    const a = bfa.allocator();
    var lay = textbox.Layout.init(a, s.str.items, s.fontPx(), s.box_w) catch return .{ .off = s.str.items.len };
    defer lay.deinit(a);
    return lay.hit(s.str.items, p.x - s.p0.x, p.y - s.p0.y);
}

test "caret lands on the nearest character" {
    const alloc = std.testing.allocator;
    var s = Shape{ .tool = .text, .color = 0xFFFFFFFF, .thickness = 4, .p0 = .{ .x = 100, .y = 100 } };
    defer s.deinit(alloc);
    try s.str.appendSlice(alloc, "abc\ndefgh");
    try std.testing.expectEqual(@as(usize, 0), caretAt(&s, .{ .x = 0, .y = 0 }).off);
    try std.testing.expectEqual(@as(usize, 3), caretAt(&s, .{ .x = 10000, .y = 100 }).off);
    const lh = text_mod.height(s.fontPx());
    try std.testing.expectEqual(@as(usize, 9), caretAt(&s, .{ .x = 10000, .y = 100 + lh + 1 }).off);
    try std.testing.expectEqual(@as(usize, 9), caretAt(&s, .{ .x = 10000, .y = 100000 }).off);
    try std.testing.expectEqual(@as(usize, 4), caretAt(&s, .{ .x = 100, .y = 100 + lh + 1 }).off);
}

test "caret across wrapped lines of a fixed-width text" {
    const alloc = std.testing.allocator;
    text_mod.init(alloc);
    defer text_mod.deinit();
    var s = Shape{ .tool = .text, .color = 0xFFFFFFFF, .thickness = 4, .p0 = .{ .x = 100, .y = 100 } };
    defer s.deinit(alloc);
    try s.str.appendSlice(alloc, "alpha beta gamma");
    const fs = s.fontPx();
    s.box_w = text_mod.width(fs, "alpha beta") + 2;
    const lh = text_mod.height(fs);
    // second visual line starts at "gamma"
    try std.testing.expectEqual(@as(usize, 11), caretAt(&s, .{ .x = 0, .y = 100 + lh + 1 }).off);
    try std.testing.expectEqual(@as(usize, 16), caretAt(&s, .{ .x = 10000, .y = 100 + lh + 1 }).off);
    // right of the first line: before its hanging space
    try std.testing.expectEqual(@as(usize, 10), caretAt(&s, .{ .x = 10000, .y = 101 }).off);
}
