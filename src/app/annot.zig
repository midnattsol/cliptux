//! The annotations of a capture on disk, so a capture kept in the history
//! can be reopened in the editor with its shapes still editable.
//!
//! Plain text, one record per line, ASCII only (text is hex encoded):
//!
//!     shotlet-doc 1
//!     sel X Y W H                    selection, in source.png pixels
//!     beautify ON BG PADDING ROUNDED SHADOW
//!     shape TOOL AARRGGBB THICK X0 Y0 X1 Y1 NUMBER FLAGS BOX_W TEXT POINTS
//!
//! TEXT is the UTF-8 text in hex ("-" when empty); POINTS is x,y;x,y;...
//! ("-" when none); FLAGS: 1 filled, 2 rounded, 4 pill. Unknown record
//! kinds are skipped so later versions can add some.

const std = @import("std");
const shapes = @import("../ui/shapes.zig");
const doc_mod = @import("../ui/doc.zig");

pub const Shape = shapes.Shape;
pub const Rect = shapes.Rect;

pub const Doc = struct {
    sel: ?Rect = null,
    beautify: doc_mod.Beautify = .{},
    shapes: std.ArrayList(Shape) = .empty,

    pub fn deinit(self: *Doc, alloc: std.mem.Allocator) void {
        for (self.shapes.items) |*s| s.deinit(alloc);
        self.shapes.deinit(alloc);
    }
};

/// The most a document may hold (a hostile file cannot exhaust memory).
const max_shapes = 10_000;
const max_points = 200_000;

pub fn write(alloc: std.mem.Allocator, sel: ?Rect, beautify: doc_mod.Beautify, list: []const Shape) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "shotlet-doc 1\n");
    if (sel) |r| try out.print(alloc, "sel {d} {d} {d} {d}\n", .{ r.x, r.y, r.w, r.h });
    const b = beautify;
    try out.print(alloc, "beautify {d} {d} {d} {d} {d}\n", .{ @intFromBool(b.enabled), b.bg, b.padding, @intFromBool(b.rounded), @intFromBool(b.shadow) });
    for (list) |*s| {
        const flags: u8 = @as(u8, @intFromBool(s.filled)) | @as(u8, @intFromBool(s.rounded)) << 1 | @as(u8, @intFromBool(s.pill)) << 2;
        try out.print(alloc, "shape {t} {X:0>8} {d} {d} {d} {d} {d} {d} {d} {d} ", .{
            s.tool, s.color, s.thickness, s.p0.x, s.p0.y, s.p1.x, s.p1.y, s.number, flags, s.box_w,
        });
        if (s.str.items.len == 0) try out.append(alloc, '-') else for (s.str.items) |c| try out.print(alloc, "{x:0>2}", .{c});
        try out.append(alloc, ' ');
        if (s.points.items.len == 0) try out.append(alloc, '-');
        for (s.points.items, 0..) |p, i| {
            if (i > 0) try out.append(alloc, ';');
            try out.print(alloc, "{d},{d}", .{ p.x, p.y });
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) !Doc {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const head = std.mem.trimEnd(u8, lines.next() orelse return error.BadDocument, "\r");
    if (!std.mem.eql(u8, head, "shotlet-doc 1")) return error.BadDocument;
    var d: Doc = .{};
    errdefer d.deinit(alloc);
    var n_points: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = f.next() orelse continue;
        if (std.mem.eql(u8, kind, "sel")) {
            d.sel = .{ .x = try int(&f), .y = try int(&f), .w = try int(&f), .h = try int(&f) };
        } else if (std.mem.eql(u8, kind, "beautify")) {
            d.beautify = .{
                .enabled = try int(&f) != 0,
                .bg = @intCast(std.math.clamp(try int(&f), 0, doc_mod.backgrounds.len - 1)),
                .padding = @intCast(std.math.clamp(try int(&f), 0, 3)),
                .rounded = try int(&f) != 0,
                .shadow = try int(&f) != 0,
            };
        } else if (std.mem.eql(u8, kind, "shape")) {
            if (d.shapes.items.len >= max_shapes) return error.BadDocument;
            const tool = std.meta.stringToEnum(shapes.Tool, f.next() orelse return error.BadDocument) orelse return error.BadDocument;
            const color = std.fmt.parseInt(u32, f.next() orelse return error.BadDocument, 16) catch return error.BadDocument;
            var s: Shape = .{ .tool = tool, .color = color, .thickness = std.math.clamp(try int(&f), 1, 512) };
            errdefer s.deinit(alloc);
            s.p0 = .{ .x = try int(&f), .y = try int(&f) };
            s.p1 = .{ .x = try int(&f), .y = try int(&f) };
            s.number = @intCast(std.math.clamp(try int(&f), 0, 1_000_000));
            const flags = try int(&f);
            s.filled = flags & 1 != 0;
            s.rounded = flags & 2 != 0;
            s.pill = flags & 4 != 0;
            s.box_w = @max(0, try int(&f));
            const text = f.next() orelse return error.BadDocument;
            if (!std.mem.eql(u8, text, "-")) {
                if (text.len % 2 != 0) return error.BadDocument;
                try s.str.ensureTotalCapacity(alloc, text.len / 2);
                var i: usize = 0;
                while (i < text.len) : (i += 2) {
                    s.str.appendAssumeCapacity(std.fmt.parseInt(u8, text[i..][0..2], 16) catch return error.BadDocument);
                }
                if (!std.unicode.utf8ValidateSlice(s.str.items)) return error.BadDocument;
            }
            const pts = f.next() orelse return error.BadDocument;
            if (!std.mem.eql(u8, pts, "-")) {
                var it = std.mem.splitScalar(u8, pts, ';');
                while (it.next()) |pair| {
                    n_points += 1;
                    if (n_points > max_points) return error.BadDocument;
                    const comma = std.mem.indexOfScalar(u8, pair, ',') orelse return error.BadDocument;
                    try s.points.append(alloc, .{ .x = try coord(pair[0..comma]), .y = try coord(pair[comma + 1 ..]) });
                }
            }
            try d.shapes.append(alloc, s);
        }
    }
    return d;
}

/// Coordinates stay far from overflow when shapes are moved or scaled.
const max_coord = 1 << 24;

fn coord(s: []const u8) !i32 {
    const v = std.fmt.parseInt(i32, s, 10) catch return error.BadDocument;
    if (v < -max_coord or v > max_coord) return error.BadDocument;
    return v;
}

fn int(f: *std.mem.TokenIterator(u8, .scalar)) !i32 {
    return coord(f.next() orelse return error.BadDocument);
}

/// Move every shape (and the selection) by dx, dy: documents are stored
/// relative to the cropped source image.
pub fn translate(d: *Doc, dx: i32, dy: i32) void {
    for (d.shapes.items) |*s| s.translate(dx, dy);
    if (d.sel) |*r| {
        r.x += dx;
        r.y += dy;
    }
}

test "documents round-trip shapes, text, points and the frame" {
    const t = std.testing;
    const alloc = t.allocator;
    var list: [3]Shape = .{
        .{ .tool = .arrow, .color = 0xFFE03131, .thickness = 4, .p0 = .{ .x = 10, .y = -5 }, .p1 = .{ .x = 200, .y = 90 } },
        .{ .tool = .text, .color = 0x80123456, .thickness = 3, .p0 = .{ .x = 1, .y = 2 }, .pill = true, .box_w = 120 },
        .{ .tool = .pen, .color = 0xFF000000, .thickness = 2, .filled = true, .rounded = true, .number = 7 },
    };
    defer for (&list) |*s| s.deinit(alloc);
    try list[1].str.appendSlice(alloc, "¿Qué? 漢字 a b\n2");
    try list[2].points.appendSlice(alloc, &.{ .{ .x = 0, .y = 0 }, .{ .x = -3, .y = 4 }, .{ .x = 5, .y = 6 } });
    const data = try write(alloc, .{ .x = 3, .y = 4, .w = 50, .h = 60 }, .{ .enabled = true, .bg = 3, .padding = 1, .rounded = false, .shadow = true }, &list);
    defer alloc.free(data);
    var d = try parse(alloc, data);
    defer d.deinit(alloc);
    try t.expectEqual(Rect{ .x = 3, .y = 4, .w = 50, .h = 60 }, d.sel.?);
    try t.expect(d.beautify.enabled and d.beautify.bg == 3 and d.beautify.padding == 1 and !d.beautify.rounded and d.beautify.shadow);
    try t.expectEqual(@as(usize, 3), d.shapes.items.len);
    for (list, d.shapes.items) |a, b| {
        try t.expectEqual(a.tool, b.tool);
        try t.expectEqual(a.color, b.color);
        try t.expectEqual(a.thickness, b.thickness);
        try t.expectEqual(a.p0, b.p0);
        try t.expectEqual(a.p1, b.p1);
        try t.expectEqual(a.number, b.number);
        try t.expectEqual(a.filled, b.filled);
        try t.expectEqual(a.rounded, b.rounded);
        try t.expectEqual(a.pill, b.pill);
        try t.expectEqual(a.box_w, b.box_w);
        try t.expectEqualStrings(a.str.items, b.str.items);
        try t.expectEqualSlices(shapes.Point, a.points.items, b.points.items);
    }
    translate(&d, -3, -4);
    try t.expectEqual(@as(i32, 0), d.sel.?.x);
    try t.expectEqual(@as(i32, 7), d.shapes.items[0].p0.x);
}

test "damaged documents are refused, not half loaded" {
    const alloc = std.testing.allocator;
    const bad = [_][]const u8{
        "",
        "shotlet-doc 2\n",
        "shotlet-doc 1\nsel 1 2 3\n",
        "shotlet-doc 1\nshape wand FF000000 1 0 0 0 0 0 0 0 - -\n",
        "shotlet-doc 1\nshape pen FF000000 1 0 0 0 0 0 0 0 - 1,2;3\n",
        "shotlet-doc 1\nshape text FF000000 1 0 0 0 0 0 0 0 abc -\n",
        "shotlet-doc 1\nshape text FF000000 1 0 0 0 0 0 0 0 ff -\n", // not UTF-8
        "shotlet-doc 1\nshape line FF000000 1 0 0 99999999999 0 0 0 0 - -\n",
    };
    for (bad) |b| try std.testing.expectError(error.BadDocument, parse(alloc, b));
    // unknown records are skipped
    var d = try parse(alloc, "shotlet-doc 1\nfuture stuff here\n\nshape rect FF000000 3 1 1 9 9 0 1 0 - -\n");
    defer d.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), d.shapes.items.len);
    try std.testing.expect(d.shapes.items[0].filled);
}
