//! Animated GIF encoder for screen recordings, streaming to a file.
//!
//! Each frame only stores the rectangle that changed since the previous
//! one, with its own palette (median cut over that rectangle, 255
//! colours plus one transparent index); inside it, pixels whose source
//! did not change are transparent, so the previous frame shows through
//! and the LZW data compresses well. Ordered dithering by default: it
//! leaves still areas still, frame after frame. A frame is held until
//! the next one arrives, to give it its exact display time (GIF delays
//! are centiseconds; the rounding carries over).

const std = @import("std");
const quantize = @import("quantize.zig");
const lzw = @import("lzw.zig");
const sys = @import("../platform/api.zig").sys;

pub const Options = struct {
    dither: quantize.Dither = .ordered,
    /// loop forever
    loop: bool = true,
};

const transparent: u8 = 255;
const max_colors: u16 = 255;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    opts: Options,
    /// where finished bytes go; null keeps them in `out` (tests)
    fd: ?sys.fd_t,
    out: std.ArrayList(u8) = .empty,
    /// the previous frame's source pixels
    last: []u32,
    idx: []u8,
    err: []i16,
    lut: []u16,
    hist: *quantize.Histogram,
    lzw: *lzw.Encoder,
    frames: u32 = 0,
    /// the held frame: its bytes in `out` from `held_at`, delay at `delay_at`
    held_at: ?usize = null,
    delay_at: usize = 0,
    held_ms: i64 = 0,
    /// centiseconds written so far (delays add up to this)
    shown_cs: i64 = 0,
    bytes_written: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, opts: Options, fd: ?sys.fd_t) !Encoder {
        if (width == 0 or height == 0 or width > 65535 or height > 65535) return error.BadSize;
        const n = @as(usize, width) * height;
        const last = try gpa.alloc(u32, n);
        errdefer gpa.free(last);
        const idx = try gpa.alloc(u8, n);
        errdefer gpa.free(idx);
        const err = try gpa.alloc(i16, (@as(usize, width) + 2) * 6);
        errdefer gpa.free(err);
        const lut = try gpa.alloc(u16, quantize.Mapper.lut_len);
        errdefer gpa.free(lut);
        const hist = try gpa.create(quantize.Histogram);
        errdefer gpa.destroy(hist);
        const enc = try gpa.create(lzw.Encoder);
        enc.* = .{};
        var self: Encoder = .{ .gpa = gpa, .width = width, .height = height, .opts = opts, .fd = fd, .last = last, .idx = idx, .err = err, .lut = lut, .hist = hist, .lzw = enc };
        self.header() catch |e| {
            self.deinit();
            return e;
        };
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.gpa);
        self.gpa.free(self.last);
        self.gpa.free(self.idx);
        self.gpa.free(self.err);
        self.gpa.free(self.lut);
        self.gpa.destroy(self.hist);
        self.gpa.destroy(self.lzw);
        self.* = undefined;
    }

    fn put16(self: *Encoder, v: u32) !void {
        try self.out.appendSlice(self.gpa, &.{ @truncate(v), @truncate(v >> 8) });
    }

    fn header(self: *Encoder) !void {
        try self.out.appendSlice(self.gpa, "GIF89a");
        try self.put16(self.width);
        try self.put16(self.height);
        // no global colour table; background 0, aspect 0
        try self.out.appendSlice(self.gpa, &.{ 0x00, 0, 0 });
        if (self.opts.loop) {
            try self.out.appendSlice(self.gpa, &.{ 0x21, 0xFF, 11 });
            try self.out.appendSlice(self.gpa, "NETSCAPE2.0");
            try self.out.appendSlice(self.gpa, &.{ 3, 1, 0, 0, 0 });
        }
    }

    /// Add a frame (`px`: width x height, `stride` pixels per row) shown
    /// from `t_ms` (ms since the start, increasing).
    pub fn addFrame(self: *Encoder, px: []const u32, stride: usize, t_ms: i64) !void {
        const dirty = if (self.frames == 0)
            Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height }
        else
            changedRect(self.last, self.width, px, stride, self.width, self.height) orelse return;
        // a frame closer than 1 cs to the held one replaces nothing: it
        // waits for the next change (fps above 100 is not a thing in GIF)
        if (self.held_at != null and centis(t_ms) <= centis(self.held_ms)) return;
        try self.release(t_ms);
        try self.frame(px, stride, dirty, self.frames > 0);
        self.held_ms = t_ms;
        self.frames += 1;
        try self.flushDone();
    }

    /// Write the held frame with its delay up to `end_ms` and the trailer.
    pub fn finish(self: *Encoder, end_ms: i64) !void {
        try self.release(@max(end_ms, self.held_ms + 10));
        try self.out.append(self.gpa, 0x3B);
        self.held_at = null;
        try self.flushDone();
        try self.flushAll();
    }

    fn centis(ms: i64) i64 {
        return @divFloor(ms + 5, 10);
    }

    /// Give the held frame its delay (shown until `t_ms`).
    fn release(self: *Encoder, t_ms: i64) !void {
        const at = self.held_at orelse return;
        _ = at;
        const end_cs = @max(centis(t_ms), self.shown_cs + 1);
        const d: u32 = @intCast(@min(end_cs - self.shown_cs, 65535));
        self.shown_cs += d;
        self.out.items[self.delay_at] = @truncate(d);
        self.out.items[self.delay_at + 1] = @truncate(d >> 8);
        self.held_at = null;
    }

    fn frame(self: *Encoder, px: []const u32, stride: usize, r: Rect, diff: bool) !void {
        const view: quantize.View = .{ .px = px, .stride = stride, .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        self.hist.reset();
        self.hist.add(view);
        var pal: quantize.Palette = .{};
        quantize.medianCut(self.hist, max_colors, &pal);
        var m = quantize.Mapper.init(&pal, self.lut);
        const idx = self.idx[0 .. r.w * r.h];
        quantize.mapView(&m, view, self.opts.dither, idx, self.err);
        if (diff) self.punchUnchanged(px, stride, r, idx);
        self.copyLast(px, stride, r);

        self.held_at = self.out.items.len;
        // graphic control: disposal 1 (keep), transparency on
        try self.out.appendSlice(self.gpa, &.{ 0x21, 0xF9, 4, 0x04 | 0x01 });
        self.delay_at = self.out.items.len;
        try self.out.appendSlice(self.gpa, &.{ 0, 0, transparent, 0 });
        // image descriptor with a 256-entry local colour table
        try self.out.append(self.gpa, 0x2C);
        try self.put16(r.x);
        try self.put16(r.y);
        try self.put16(r.w);
        try self.put16(r.h);
        try self.out.append(self.gpa, 0x80 | 7);
        for (0..256) |i| {
            const c: u32 = if (i < pal.len) pal.colors[i] else 0;
            try self.out.appendSlice(self.gpa, &.{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) });
        }
        try self.lzw.encode(self.gpa, idx, &self.out);
    }

    /// Pixels whose source is as in the previous frame stay as shown.
    fn punchUnchanged(self: *const Encoder, px: []const u32, stride: usize, r: Rect, idx: []u8) void {
        for (0..r.h) |y| {
            const src = px[(r.y + y) * stride + r.x ..][0..r.w];
            const old = self.last[(r.y + y) * self.width + r.x ..][0..r.w];
            const row = idx[y * r.w ..][0..r.w];
            for (src, old, row) |s, o, *i| {
                if (s == o) i.* = transparent;
            }
        }
    }

    fn copyLast(self: *Encoder, px: []const u32, stride: usize, r: Rect) void {
        for (0..r.h) |y| {
            @memcpy(self.last[(r.y + y) * self.width + r.x ..][0..r.w], px[(r.y + y) * stride + r.x ..][0..r.w]);
        }
    }

    /// Write out every byte before the held frame.
    fn flushDone(self: *Encoder) !void {
        const end = self.held_at orelse self.out.items.len;
        if (self.fd == null or end < 64 * 1024) return;
        try sys.writeAllBlocking(self.fd.?, self.out.items[0..end]);
        self.bytes_written += end;
        const rest = self.out.items.len - end;
        std.mem.copyForwards(u8, self.out.items[0..rest], self.out.items[end..]);
        self.out.shrinkRetainingCapacity(rest);
        if (self.held_at) |h| {
            self.held_at = h - end;
            self.delay_at -= end;
        }
    }

    fn flushAll(self: *Encoder) !void {
        const fd = self.fd orelse return;
        try sys.writeAllBlocking(fd, self.out.items);
        self.bytes_written += self.out.items.len;
        self.out.clearRetainingCapacity();
    }
};

/// The bounding box of the pixels that differ, or null when none do.
pub fn changedRect(old: []const u32, old_stride: usize, px: []const u32, stride: usize, w: u32, h: u32) ?Rect {
    var x0: u32 = w;
    var y0: u32 = h;
    var x1: u32 = 0;
    var y1: u32 = 0;
    for (0..h) |yu| {
        const y: u32 = @intCast(yu);
        const a = old[yu * old_stride ..][0..w];
        const b = px[yu * stride ..][0..w];
        if (std.mem.eql(u32, a, b)) continue;
        var l: u32 = 0;
        while (a[l] == b[l]) l += 1;
        var r: u32 = w - 1;
        while (a[r] == b[r]) r -= 1;
        x0 = @min(x0, l);
        x1 = @max(x1, r + 1);
        y0 = @min(y0, y);
        y1 = y + 1;
    }
    if (x1 == 0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "changed rect finds the box of differing pixels" {
    var a: [10 * 6]u32 = @splat(0xFF000000);
    var b = a;
    try std.testing.expect(changedRect(&a, 10, &b, 10, 10, 6) == null);
    b[2 * 10 + 3] = 0xFFFFFFFF;
    b[4 * 10 + 7] = 0xFF00FF00;
    const r = changedRect(&a, 10, &b, 10, 10, 6).?;
    try std.testing.expectEqual(Rect{ .x = 3, .y = 2, .w = 5, .h = 3 }, r);
}
