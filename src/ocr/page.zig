//! What Tesseract read on a picture: its words with their boxes and where
//! they sit in Tesseract's layout (block, paragraph, line), parsed from
//! its TSV output. Also the picture prepared for it: small screen text is
//! read far better enlarged, and light-on-dark text inverted.

const std = @import("std");
const Rect = @import("../ui/shapes.zig").Rect;

pub const Word = struct {
    block: u32,
    par: u32,
    line: u32,
    box: Rect,
    conf: f32,
    /// a slice of Page.text_buf
    text: []const u8,
};

pub const Page = struct {
    words: []Word,
    text_buf: []u8,

    pub fn deinit(self: *Page, alloc: std.mem.Allocator) void {
        alloc.free(self.words);
        alloc.free(self.text_buf);
        self.* = undefined;
    }

    /// Boxes in the picture's pixels: divided by the enlargement and
    /// moved by the region's corner.
    pub fn mapBoxes(self: *Page, scale: u32, ox: i32, oy: i32) void {
        const k: i32 = @intCast(@max(1, scale));
        for (self.words) |*w| {
            const x0 = @divFloor(w.box.x, k);
            const y0 = @divFloor(w.box.y, k);
            const x1 = @divFloor(w.box.right() + k - 1, k);
            const y1 = @divFloor(w.box.bottom() + k - 1, k);
            w.box = .{ .x = x0 + ox, .y = y0 + oy, .w = x1 - x0, .h = y1 - y0 };
        }
    }
};

/// The word rows (level 5) of Tesseract's TSV: level page block par line
/// word left top width height conf text. Empty words are dropped.
pub fn parseTsv(alloc: std.mem.Allocator, tsv: []const u8) !Page {
    var words: std.ArrayList(Word) = .empty;
    defer words.deinit(alloc);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var spans: std.ArrayList([2]usize) = .empty;
    defer spans.deinit(alloc);
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.splitScalar(u8, line, '\t');
        var v: [11]i64 = undefined;
        var ok = true;
        for (&v, 0..) |*x, i| {
            const field = f.next() orelse {
                ok = false;
                break;
            };
            x.* = if (i == 10)
                @intFromFloat(std.fmt.parseFloat(f64, field) catch -1)
            else
                std.fmt.parseInt(i64, field, 10) catch {
                    ok = false;
                    break;
                };
        }
        if (!ok or v[0] != 5) continue;
        const word = std.mem.trim(u8, f.rest(), " \t");
        if (word.len == 0 or v[8] <= 0 or v[9] <= 0) continue;
        try spans.append(alloc, .{ text.items.len, text.items.len + word.len });
        try text.appendSlice(alloc, word);
        try words.append(alloc, .{
            .block = @intCast(@max(0, v[2])),
            .par = @intCast(@max(0, v[3])),
            .line = @intCast(@max(0, v[4])),
            .box = .{ .x = @intCast(v[6]), .y = @intCast(v[7]), .w = @intCast(v[8]), .h = @intCast(v[9]) },
            .conf = @floatFromInt(v[10]),
            .text = "",
        });
    }
    const buf = try text.toOwnedSlice(alloc);
    errdefer alloc.free(buf);
    for (words.items, spans.items) |*w, sp| w.text = buf[sp[0]..sp[1]];
    return .{ .words = try words.toOwnedSlice(alloc), .text_buf = buf };
}

/// How much to enlarge a region before reading it: screen text is small
/// (about 13 px); Tesseract wants capitals 20 to 30 px tall.
pub fn scaleFor(w: u32, h: u32) u32 {
    const area = @as(u64, w) * h;
    if (area <= 2_000_000) return 3;
    if (area <= 6_000_000) return 2;
    return 1;
}

/// The region `r` of `px` (`pw` wide), enlarged `scale` times (nearest),
/// as dark text on a light ground (light-on-dark is inverted). Owned.
pub fn prepare(alloc: std.mem.Allocator, px: []const u32, pw: u32, r: Rect, scale: u32) ![]u32 {
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    const out = try alloc.alloc(u32, w * h * scale * scale);
    var lum_sum: u64 = 0;
    for (0..h * scale) |y| for (0..w * scale) |x| {
        const p = px[(@as(usize, @intCast(r.y)) + y / scale) * pw + @as(usize, @intCast(r.x)) + x / scale];
        out[y * w * scale + x] = p;
        if (x % scale == 0 and y % scale == 0) lum_sum += luma(p);
    };
    if (lum_sum / @max(1, w * h) < 110) {
        for (out) |*p| p.* = (p.* & 0xFF000000) | (~p.* & 0x00FFFFFF);
    }
    return out;
}

fn luma(p: u32) u32 {
    return (((p >> 16) & 0xFF) * 299 + ((p >> 8) & 0xFF) * 587 + (p & 0xFF) * 114) / 1000;
}

const testing = std.testing;

test "tsv words with their layout" {
    const tsv =
        "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" ++
        "1\t1\t0\t0\t0\t0\t0\t0\t800\t600\t-1\t\n" ++
        "4\t1\t1\t1\t1\t0\t10\t10\t200\t20\t-1\t\n" ++
        "5\t1\t1\t1\t1\t1\t10\t10\t60\t20\t96.5\tHello\n" ++
        "5\t1\t1\t1\t1\t2\t80\t10\t70\t20\t95.1\twörld\r\n" ++
        "5\t1\t1\t1\t1\t3\t160\t10\t10\t20\t95\t \n" ++
        "5\t1\t2\t1\t1\t1\t10\t50\t60\t20\t91\tnext\n" ++
        "5\tbroken\n";
    var p = try parseTsv(testing.allocator, tsv);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), p.words.len);
    try testing.expectEqualStrings("Hello", p.words[0].text);
    try testing.expectEqualStrings("wörld", p.words[1].text);
    try testing.expectEqual(@as(u32, 2), p.words[2].block);
    try testing.expect(p.words[1].box.eql(.{ .x = 80, .y = 10, .w = 70, .h = 20 }));
    p.mapBoxes(2, 100, 200);
    try testing.expect(p.words[1].box.eql(.{ .x = 140, .y = 205, .w = 35, .h = 10 }));
}

test "regions are enlarged, dark ones inverted" {
    const px = [_]u32{ 0xFF000000, 0xFF101010, 0xFFFFFFFF, 0xFF000000 };
    const out = try prepare(testing.allocator, &px, 2, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, 2);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 16), out.len);
    // mostly dark: inverted, black becomes white
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), out[0]);
    try testing.expectEqual(out[0], out[5]);
    try testing.expectEqual(@as(u32, 0xFF000000), out[2 * 4]);
    try testing.expectEqual(@as(u32, 3), scaleFor(800, 600));
    try testing.expectEqual(@as(u32, 1), scaleFor(5000, 3000));
}
