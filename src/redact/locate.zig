//! Where on the picture the sensitive data is: each recognised line is
//! searched as text (detect.zig) and every match is mapped back to the
//! boxes of the words it covers (part of a word by its share of letters).

const std = @import("std");
const detect = @import("detect.zig");
const Word = @import("../ocr/page.zig").Word;
const Rect = @import("../ui/shapes.zig").Rect;

pub const Hit = struct { box: Rect, kind: detect.Kind };

/// Boxes to redact, in the words' coordinates, `pad` pixels around.
pub fn find(alloc: std.mem.Allocator, words: []const Word, pad: i32) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(alloc);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var spans: std.ArrayList([2]usize) = .empty;
    defer spans.deinit(alloc);
    var i: usize = 0;
    while (i < words.len) {
        var j = i;
        line.clearRetainingCapacity();
        spans.clearRetainingCapacity();
        while (j < words.len and sameLine(words[i], words[j])) : (j += 1) {
            if (j > i) try line.append(alloc, ' ');
            try spans.append(alloc, .{ line.items.len, line.items.len + words[j].text.len });
            try line.appendSlice(alloc, words[j].text);
        }
        const matches = try detect.find(alloc, line.items);
        defer alloc.free(matches);
        for (matches) |m| {
            if (cover(words[i..j], spans.items, m)) |box| try hits.append(alloc, .{ .box = box.expand(pad), .kind = m.kind });
        }
        i = j;
    }
    return hits.toOwnedSlice(alloc);
}

fn sameLine(a: Word, b: Word) bool {
    return a.block == b.block and a.par == b.par and a.line == b.line;
}

/// The part of the line's word boxes under bytes [m.start, m.end).
fn cover(words: []const Word, spans: []const [2]usize, m: detect.Match) ?Rect {
    var r = Rect.empty;
    for (words, spans) |w, sp| {
        const a = @max(sp[0], m.start);
        const b = @min(sp[1], m.end);
        if (a >= b) continue;
        const len: i32 = @intCast(sp[1] - sp[0]);
        const x0 = w.box.x + @divTrunc(w.box.w * @as(i32, @intCast(a - sp[0])), len);
        const x1 = w.box.x + @divTrunc(w.box.w * @as(i32, @intCast(b - sp[0])) + len - 1, len);
        r = Rect.unite(r, .{ .x = x0, .y = w.box.y, .w = x1 - x0, .h = w.box.h });
    }
    return if (r.isEmpty()) null else r;
}

test "matches map back to their words' boxes" {
    const words = [_]Word{
        .{ .block = 1, .par = 1, .line = 1, .box = .{ .x = 10, .y = 10, .w = 50, .h = 12 }, .conf = 90, .text = "Mail:" },
        .{ .block = 1, .par = 1, .line = 1, .box = .{ .x = 70, .y = 10, .w = 90, .h = 12 }, .conf = 90, .text = "bob@x.org" },
        .{ .block = 1, .par = 1, .line = 2, .box = .{ .x = 10, .y = 30, .w = 40, .h = 12 }, .conf = 90, .text = "Card" },
        .{ .block = 1, .par = 1, .line = 2, .box = .{ .x = 60, .y = 30, .w = 40, .h = 12 }, .conf = 90, .text = "4111" },
        .{ .block = 1, .par = 1, .line = 2, .box = .{ .x = 110, .y = 30, .w = 40, .h = 12 }, .conf = 90, .text = "1111" },
        .{ .block = 1, .par = 1, .line = 2, .box = .{ .x = 160, .y = 30, .w = 40, .h = 12 }, .conf = 90, .text = "1111" },
        .{ .block = 1, .par = 1, .line = 2, .box = .{ .x = 210, .y = 30, .w = 40, .h = 12 }, .conf = 90, .text = "1111" },
        // part of a word: the key after "key="
        .{ .block = 2, .par = 1, .line = 1, .box = .{ .x = 0, .y = 60, .w = 400, .h = 12 }, .conf = 90, .text = "key=AKIAIOSFODNN7EXAMPLEXYZW" },
    };
    const hits = try find(std.testing.allocator, &words, 2);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expect(hits[0].box.eql(.{ .x = 68, .y = 8, .w = 94, .h = 16 }));
    try std.testing.expectEqual(detect.Kind.email, hits[0].kind);
    try std.testing.expect(hits[1].box.eql(.{ .x = 58, .y = 28, .w = 194, .h = 16 }));
    try std.testing.expectEqual(detect.Kind.card, hits[1].kind);
    try std.testing.expectEqual(detect.Kind.api_key, hits[2].kind);
    // starts a sixth of the way in (4 of 27 bytes)
    try std.testing.expect(hits[2].box.x >= 55 and hits[2].box.x <= 60);
    try std.testing.expectEqual(@as(i32, 402), hits[2].box.right());
}
