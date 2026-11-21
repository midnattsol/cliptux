//! Scrolling capture: stitch successive frames of one screen region into
//! a tall image.
//!
//! Each frame is the same region after the content scrolled by some
//! unknown number of pixels. Rows are hashed (leaving out a strip on the
//! right, where scroll bars move); between two frames:
//!
//! - static bands: rows at the top and bottom that did not change at the
//!   same positions are a sticky header and footer. They are left out of
//!   the matching and drawn once (the header from the first frame, the
//!   footer from the last);
//! - the offset: the scroll distance d at which the new frame's body rows
//!   line up with the previous body shifted up by d. Candidates must
//!   agree on almost every overlapping row; among several (repeated rows),
//!   the one nearest the previous step wins, else the one lining up the
//!   most rows that occur only once. The winner is verified pixel by
//!   pixel, so a hash collision cannot pass;
//! - the new rows (the bottom d rows of the body) are appended.
//!
//! An unchanged frame means the content stopped moving (the end of the
//! page); no offset means it moved too far between two frames.

const std = @import("std");

pub const default_max_height: u32 = 20_000;

pub const Frame = struct {
    /// 0xAARRGGBB, width * height
    pixels: []const u32,
    width: u32,
    height: u32,

    fn row(self: Frame, y: usize) []const u32 {
        return self.pixels[y * self.width ..][0..self.width];
    }
};

/// Pixels hashed per row: the right edge (scroll bars) is left out.
pub fn hashWidth(w: u32) u32 {
    if (w < 8) return w;
    const margin = @min(w / 4, @max(16, w / 32));
    return w - margin;
}

pub fn rowHashes(f: Frame, out: []u64) void {
    const hw = hashWidth(f.width);
    for (out, 0..) |*h, y| h.* = std.hash.Wyhash.hash(0x5c011, std.mem.sliceAsBytes(f.row(y)[0..hw]));
}

pub const Bands = struct { top: u32 = 0, bottom: u32 = 0 };

/// Rows that stayed put between two frames: a sticky header and footer,
/// each at most a third of the height. Nothing when nothing moved.
pub fn staticBands(a: []const u64, b: []const u64) Bands {
    const h = a.len;
    var top: usize = 0;
    while (top < h and a[top] == b[top]) top += 1;
    if (top == h) return .{};
    var bottom: usize = 0;
    while (bottom < h - top and a[h - 1 - bottom] == b[h - 1 - bottom]) bottom += 1;
    const cap = h / 3;
    return .{ .top = @intCast(@min(top, cap)), .bottom = @intCast(@min(bottom, cap)) };
}

/// The scroll distance that lines `cur` up under `prev` (both body rows):
/// cur[i] == prev[i + d]. Null when no distance fits.
pub fn findOffset(gpa: std.mem.Allocator, prev: []const u64, cur: []const u64, expected: ?u32) !?u32 {
    const n = prev.len;
    if (n < 2 or cur.len != n) return null;
    const min_overlap = @max(4, n / 10);
    if (n <= min_overlap) return null;

    // how often each row occurs: unique rows anchor a match
    var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer counts.deinit(gpa);
    for (prev) |h| {
        const e = try counts.getOrPut(gpa, h);
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }

    var best: ?u32 = null;
    var best_key: i64 = std.math.minInt(i64);
    var d: usize = 1;
    while (d <= n - min_overlap) : (d += 1) {
        const anchors = matchAnchors(prev, cur, d, &counts) orelse continue;
        const key = candidateKey(@intCast(d), anchors, expected);
        if (key > best_key) {
            best_key = key;
            best = @intCast(d);
        }
    }
    return best;
}

/// Unique rows lined up at distance d, or null when more than 2% of the
/// overlap disagrees.
fn matchAnchors(prev: []const u64, cur: []const u64, d: usize, counts: *const std.AutoHashMapUnmanaged(u64, u32)) ?u32 {
    const overlap = prev.len - d;
    const limit = overlap / 50;
    var mism: usize = 0;
    var anchors: u32 = 0;
    for (0..overlap) |i| {
        if (cur[i] != prev[i + d]) {
            mism += 1;
            if (mism > limit) return null;
        } else if (counts.get(cur[i]) == 1) anchors += 1;
    }
    return anchors;
}

/// Higher is better: nearest the expected step, else the most anchors,
/// then the shorter distance.
fn candidateKey(d: u32, anchors: u32, expected: ?u32) i64 {
    if (expected) |e| {
        const dist: i64 = @intCast(@abs(@as(i64, d) - e));
        return -dist * (1 << 24) + anchors;
    }
    return @as(i64, anchors) * (1 << 20) - d;
}

/// Rows `cur[i]` and `prev[i + d]` are the same pixels (the hashed part).
fn verify(prev: Frame, cur: Frame, top: u32, body_h: u32, d: u32) bool {
    const hw = hashWidth(prev.width);
    const overlap = body_h - d;
    const step = @max(1, overlap / 32);
    var i: u32 = 0;
    while (i < overlap) : (i += step) {
        const a = prev.row(top + i + d)[0..hw];
        const b = cur.row(top + i)[0..hw];
        if (!std.mem.eql(u32, a, b)) return false;
    }
    return true;
}

pub const Push = union(enum) {
    /// the content moved by this many rows, appended
    appended: u32,
    /// nothing moved
    unchanged,
    /// it moved too far (or changed): no overlap with the previous frame
    no_overlap,
    /// the maximum height is reached: stop
    full,
};

pub const Stitcher = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    max_height: u32,
    /// the header rows (from the first frame); fixed at the first move
    bands: ?Bands = null,
    first: []u32,
    /// body rows appended so far (the first frame's body first)
    body: std.ArrayList(u32) = .empty,
    /// the last frame that moved the content, and its row hashes
    prev: []u32,
    prev_hash: []u64,
    cur_hash: []u64,
    last_step: ?u32 = null,

    pub fn init(gpa: std.mem.Allocator, first: Frame, max_height: u32) !Stitcher {
        if (first.width == 0 or first.height < 8) return error.RegionTooSmall;
        const n = @as(usize, first.width) * first.height;
        const copy = try gpa.dupe(u32, first.pixels[0..n]);
        errdefer gpa.free(copy);
        const prev = try gpa.dupe(u32, first.pixels[0..n]);
        errdefer gpa.free(prev);
        const ph = try gpa.alloc(u64, first.height);
        errdefer gpa.free(ph);
        const ch = try gpa.alloc(u64, first.height);
        rowHashes(first, ph);
        return .{ .gpa = gpa, .width = first.width, .height = first.height, .max_height = @max(first.height, max_height), .first = copy, .prev = prev, .prev_hash = ph, .cur_hash = ch };
    }

    pub fn deinit(self: *Stitcher) void {
        self.gpa.free(self.first);
        self.gpa.free(self.prev);
        self.gpa.free(self.prev_hash);
        self.gpa.free(self.cur_hash);
        self.body.deinit(self.gpa);
    }

    /// Height of the image so far.
    pub fn totalHeight(self: *const Stitcher) u32 {
        const b = self.bands orelse return self.height;
        return b.top + @as(u32, @intCast(self.body.items.len / self.width)) + b.bottom;
    }

    /// Row y of the image so far (y < totalHeight()), without building it.
    pub fn row(self: *const Stitcher, y: u32) []const u32 {
        const w = self.width;
        const b = self.bands orelse return self.first[@as(usize, y) * w ..][0..w];
        if (y < b.top) return self.first[@as(usize, y) * w ..][0..w];
        const body_rows: u32 = @intCast(self.body.items.len / w);
        if (y < b.top + body_rows) return self.body.items[@as(usize, y - b.top) * w ..][0..w];
        const fy = self.height - (self.totalHeight() - y);
        return self.prev[@as(usize, fy) * w ..][0..w];
    }

    fn prevFrame(self: *const Stitcher) Frame {
        return .{ .pixels = self.prev, .width = self.width, .height = self.height };
    }

    pub fn push(self: *Stitcher, f: Frame) !Push {
        if (f.width != self.width or f.height != self.height) return error.FrameSizeChanged;
        if (self.totalHeight() >= self.max_height) return .full;
        rowHashes(f, self.cur_hash);
        const moved = staticBands(self.prev_hash, self.cur_hash);
        if (moved.top == 0 and moved.bottom == 0 and std.mem.eql(u64, self.prev_hash, self.cur_hash)) return .unchanged;
        const b = self.bands orelse moved;
        const body_h = self.height - b.top - b.bottom;
        const prev_body = self.prev_hash[b.top..][0..body_h];
        const cur_body = self.cur_hash[b.top..][0..body_h];
        const d = (try findOffset(self.gpa, prev_body, cur_body, self.last_step)) orelse return .no_overlap;
        if (!verify(self.prevFrame(), f, b.top, body_h, d)) return .no_overlap;
        if (self.bands == null) try self.startBody(b);
        const room = self.max_height - self.totalHeight();
        const add = @min(d, room);
        try self.appendRows(f, b.top + body_h - d, add);
        self.last_step = d;
        @memcpy(self.prev, f.pixels[0..self.prev.len]);
        @memcpy(self.prev_hash, self.cur_hash);
        return if (add < d or add == room) .full else .{ .appended = d };
    }

    /// The first move fixes the bands; the first frame's body starts the
    /// image.
    fn startBody(self: *Stitcher, b: Bands) !void {
        self.bands = b;
        const w = self.width;
        try self.body.appendSlice(self.gpa, self.first[@as(usize, b.top) * w .. @as(usize, self.height - b.bottom) * w]);
    }

    fn appendRows(self: *Stitcher, f: Frame, from: u32, count: u32) !void {
        const w = self.width;
        try self.body.appendSlice(self.gpa, f.pixels[@as(usize, from) * w ..][0 .. @as(usize, count) * w]);
    }

    /// The stitched image: header, body, footer (from the last frame).
    /// Caller owns the pixels.
    pub fn result(self: *const Stitcher) !Frame {
        const w = self.width;
        const b = self.bands orelse return .{ .pixels = try self.gpa.dupe(u32, self.first), .width = w, .height = self.height };
        const h = self.totalHeight();
        const out = try self.gpa.alloc(u32, @as(usize, w) * h);
        const top_n = @as(usize, b.top) * w;
        @memcpy(out[0..top_n], self.first[0..top_n]);
        @memcpy(out[top_n..][0..self.body.items.len], self.body.items);
        const foot_n = @as(usize, b.bottom) * w;
        @memcpy(out[top_n + self.body.items.len ..][0..foot_n], self.prev[self.prev.len - foot_n ..]);
        return .{ .pixels = out, .width = w, .height = h };
    }
};

// --- tests: synthetic pages ---

const testing = std.testing;

/// A page row: distinct per y (unless `repeat` folds rows together),
/// varying along x so no row is flat.
fn pageRow(y: u32, x: u32, repeat: ?u32) u32 {
    const yy = if (repeat) |r| (if ((y / r) % 3 == 1) 7 else y) else y;
    const h = std.hash.Wyhash.hash(yy, "row");
    return 0xFF000000 | @as(u32, @truncate(h ^ (@as(u64, x / 4) *% 0x9E3779B97F4A7C15 >> 32))) & 0xFFFFFF;
}

const Page = struct {
    w: u32 = 48,
    view_h: u32 = 120,
    header: u32 = 0,
    footer: u32 = 0,
    len: u32 = 600,
    repeat: ?u32 = null,

    fn body(self: Page) u32 {
        return self.view_h - self.header - self.footer;
    }

    /// The view scrolled by `off` rows; caller frees.
    fn frame(self: Page, off: u32) ![]u32 {
        const px = try testing.allocator.alloc(u32, self.w * self.view_h);
        for (0..self.view_h) |yi| for (0..self.w) |xi| {
            const y: u32 = @intCast(yi);
            const x: u32 = @intCast(xi);
            px[yi * self.w + xi] = if (y < self.header)
                0xFF102030 + y * 3 + x / 16
            else if (y >= self.view_h - self.footer)
                0xFF405060 + (y - (self.view_h - self.footer)) * 5 + x / 16
            else
                pageRow(off + y - self.header, x, self.repeat);
        };
        return px;
    }

    /// The whole page with its header and footer once.
    fn expected(self: Page) ![]u32 {
        const h = self.header + self.len + self.footer;
        const px = try testing.allocator.alloc(u32, self.w * h);
        const first = try self.frame(0);
        defer testing.allocator.free(first);
        const last = try self.frame(self.len - self.body());
        defer testing.allocator.free(last);
        @memcpy(px[0 .. self.header * self.w], first[0 .. self.header * self.w]);
        for (0..self.len) |yi| for (0..self.w) |xi| {
            px[(self.header + yi) * self.w + xi] = pageRow(@intCast(yi), @intCast(xi), self.repeat);
        };
        @memcpy(px[(self.header + self.len) * self.w ..], last[(self.view_h - self.footer) * self.w ..]);
        return px;
    }
};

/// Scroll through the page in `step` rows (the last step shorter), as a
/// capture session would, and check the stitched result.
fn stitchPage(p: Page, step: u32) !void {
    const first = try p.frame(0);
    defer testing.allocator.free(first);
    var st = try Stitcher.init(testing.allocator, .{ .pixels = first, .width = p.w, .height = p.view_h }, default_max_height);
    defer st.deinit();
    var off: u32 = 0;
    const end = p.len - p.body();
    while (off < end) {
        off = @min(end, off + step);
        const f = try p.frame(off);
        defer testing.allocator.free(f);
        const r = try st.push(.{ .pixels = f, .width = p.w, .height = p.view_h });
        try testing.expect(r == .appended);
    }
    // at the end of the page nothing moves any more
    const f = try p.frame(end);
    defer testing.allocator.free(f);
    try testing.expectEqual(Push.unchanged, try st.push(.{ .pixels = f, .width = p.w, .height = p.view_h }));
    const out = try st.result();
    defer testing.allocator.free(out.pixels);
    const want = try p.expected();
    defer testing.allocator.free(want);
    try testing.expectEqual(p.header + p.len + p.footer, out.height);
    try testing.expectEqualSlices(u32, want, out.pixels);
    for ([_]u32{ 0, p.header, out.height / 2, out.height - 1 }) |y|
        try testing.expectEqualSlices(u32, want[y * p.w ..][0..p.w], st.row(y));
}

test "a plain page stitches back together" {
    try stitchPage(.{}, 40);
}

test "sticky header and footer appear once" {
    try stitchPage(.{ .header = 14, .footer = 10 }, 37);
}

test "small scroll steps" {
    try stitchPage(.{ .len = 200 }, 1);
    try stitchPage(.{ .len = 200, .header = 6 }, 3);
}

test "repeated rows do not confuse the offset" {
    // a third of every 12-row block is the same row over and over
    try stitchPage(.{ .repeat = 4, .header = 8 }, 23);
}

test "no overlap when the content jumps past the view" {
    const p: Page = .{};
    const a = try p.frame(0);
    defer testing.allocator.free(a);
    const b = try p.frame(p.view_h + 10);
    defer testing.allocator.free(b);
    var st = try Stitcher.init(testing.allocator, .{ .pixels = a, .width = p.w, .height = p.view_h }, default_max_height);
    defer st.deinit();
    try testing.expectEqual(Push.no_overlap, try st.push(.{ .pixels = b, .width = p.w, .height = p.view_h }));
    // the image is still the first frame alone
    try testing.expectEqual(p.view_h, st.totalHeight());
}

test "the maximum height stops the capture" {
    const p: Page = .{ .len = 2000 };
    const a = try p.frame(0);
    defer testing.allocator.free(a);
    var st = try Stitcher.init(testing.allocator, .{ .pixels = a, .width = p.w, .height = p.view_h }, 300);
    defer st.deinit();
    var off: u32 = 0;
    var full = false;
    while (!full) {
        off += 50;
        const f = try p.frame(off);
        defer testing.allocator.free(f);
        full = (try st.push(.{ .pixels = f, .width = p.w, .height = p.view_h })) == .full;
    }
    try testing.expectEqual(@as(u32, 300), st.totalHeight());
    const out = try st.result();
    defer testing.allocator.free(out.pixels);
    try testing.expectEqual(@as(u32, 300), out.height);
    try testing.expectEqual(pageRow(299, 0, null), out.pixels[299 * p.w]);
}

test "static bands and offsets on hashes" {
    const a = [_]u64{ 9, 1, 2, 3, 4, 5, 6, 8 };
    const b = [_]u64{ 9, 3, 4, 5, 6, 7, 7, 8 };
    try testing.expectEqual(Bands{ .top = 1, .bottom = 1 }, staticBands(&a, &b));
    try testing.expectEqual(Bands{}, staticBands(&a, &a));
    const prev = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const cur = [_]u64{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try testing.expectEqual(@as(?u32, 3), try findOffset(testing.allocator, &prev, &cur, null));
    const other = [_]u64{ 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
    try testing.expectEqual(@as(?u32, null), try findOffset(testing.allocator, &prev, &other, null));
}
