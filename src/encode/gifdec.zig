//! A small GIF decoder: every frame composed onto the full canvas
//! (0xFFRRGGBB), with its display time. Enough for Shotlet's own GIFs
//! (the trim window, thumbnails, tests) and ordinary animated GIFs.

const std = @import("std");
const lzw = @import("lzw.zig");

pub const Frame = struct {
    /// the whole canvas after this frame, width x height
    pixels: []const u32,
    /// shown from this many ms after the start, for delay_ms
    start_ms: i64,
    delay_ms: i64,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    pos: usize,
    width: u32,
    height: u32,
    global: [256]u32 = @splat(0xFF000000),
    global_len: usize = 0,
    canvas: []u32,
    /// the canvas before the current frame (for "restore previous")
    saved: []u32,
    idx: []u8,
    t_ms: i64 = 0,
    // the pending frame's disposal of its area, applied before the next
    dispose: u3 = 0,
    last_rect: [4]u32 = @splat(0),

    pub fn init(gpa: std.mem.Allocator, data: []const u8) !Decoder {
        if (data.len < 13 or !(std.mem.eql(u8, data[0..6], "GIF89a") or std.mem.eql(u8, data[0..6], "GIF87a"))) return error.NotAGif;
        const w = rd16(data, 6);
        const h = rd16(data, 8);
        if (w == 0 or h == 0) return error.BadSize;
        const flags = data[10];
        const n = @as(usize, w) * h;
        const canvas = try gpa.alloc(u32, n);
        errdefer gpa.free(canvas);
        const saved = try gpa.alloc(u32, n);
        errdefer gpa.free(saved);
        const idx = try gpa.alloc(u8, n);
        errdefer gpa.free(idx);
        var d: Decoder = .{ .gpa = gpa, .data = data, .pos = 13, .width = w, .height = h, .canvas = canvas, .saved = saved, .idx = idx };
        @memset(canvas, 0);
        if (flags & 0x80 != 0) d.global_len = try d.readTable(&d.global, flags);
        return d;
    }

    pub fn deinit(self: *Decoder) void {
        self.gpa.free(self.canvas);
        self.gpa.free(self.saved);
        self.gpa.free(self.idx);
    }

    fn rd16(data: []const u8, at: usize) u32 {
        return @as(u32, data[at]) | @as(u32, data[at + 1]) << 8;
    }

    fn need(self: *const Decoder, n: usize) !void {
        if (self.pos + n > self.data.len) return error.Truncated;
    }

    fn readTable(self: *Decoder, out: *[256]u32, flags: u8) !usize {
        const n = @as(usize, 2) << @intCast(flags & 7);
        try self.need(n * 3);
        for (0..n) |i| {
            const p = self.data[self.pos + i * 3 ..][0..3];
            out[i] = 0xFF000000 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2];
        }
        self.pos += n * 3;
        return n;
    }

    fn skipBlocks(self: *Decoder) !void {
        while (true) {
            try self.need(1);
            const len = self.data[self.pos];
            self.pos += 1;
            if (len == 0) return;
            try self.need(len);
            self.pos += len;
        }
    }

    /// The next frame, or null at the end. The pixels stay valid until
    /// the next call.
    pub fn next(self: *Decoder) !?Frame {
        var delay_cs: u32 = 0;
        var trans: ?u8 = null;
        var disposal: u3 = 0;
        while (true) {
            try self.need(1);
            const tag = self.data[self.pos];
            self.pos += 1;
            switch (tag) {
                0x3B => return null,
                0x21 => {
                    try self.need(1);
                    const label = self.data[self.pos];
                    self.pos += 1;
                    if (label == 0xF9) {
                        try self.need(6);
                        const f = self.data[self.pos + 1];
                        delay_cs = rd16(self.data, self.pos + 2);
                        if (f & 1 != 0) trans = self.data[self.pos + 4];
                        disposal = @intCast((f >> 2) & 7);
                        self.pos += 5;
                    }
                    try self.skipBlocks();
                },
                0x2C => return try self.image(delay_cs, trans, disposal),
                else => return error.BadBlock,
            }
        }
    }

    fn image(self: *Decoder, delay_cs: u32, trans: ?u8, disposal: u3) !Frame {
        self.applyDisposal();
        try self.need(9);
        const x = rd16(self.data, self.pos);
        const y = rd16(self.data, self.pos + 2);
        const w = rd16(self.data, self.pos + 4);
        const h = rd16(self.data, self.pos + 6);
        const flags = self.data[self.pos + 8];
        self.pos += 9;
        var local: [256]u32 = @splat(0xFF000000);
        const table: *const [256]u32 = if (flags & 0x80 != 0) blk: {
            _ = try self.readTable(&local, flags);
            break :blk &local;
        } else &self.global;
        if (flags & 0x40 != 0) return error.Interlaced;
        if (x + w > self.width or y + h > self.height) return error.BadRect;
        const idx = self.idx[0 .. @as(usize, w) * h];
        @memset(idx, if (trans) |t| t else 0);
        try lzw.decode(self.data, &self.pos, idx);
        if (disposal == 3) @memcpy(self.saved, self.canvas);
        for (0..h) |r| for (0..w) |c| {
            const i = idx[r * w + c];
            if (trans != null and i == trans.?) continue;
            self.canvas[(y + r) * self.width + x + c] = table[i];
        };
        self.dispose = disposal;
        self.last_rect = .{ x, y, w, h };
        const start = self.t_ms;
        const delay: i64 = @as(i64, delay_cs) * 10;
        self.t_ms += delay;
        return .{ .pixels = self.canvas, .start_ms = start, .delay_ms = delay };
    }

    fn applyDisposal(self: *Decoder) void {
        const r = self.last_rect;
        switch (self.dispose) {
            2 => for (0..r[3]) |yy| @memset(self.canvas[(r[1] + yy) * self.width + r[0] ..][0..r[2]], 0),
            3 => @memcpy(self.canvas, self.saved),
            else => {},
        }
        self.dispose = 0;
    }
};

/// Frames and total duration, without keeping pixels.
pub fn stats(gpa: std.mem.Allocator, data: []const u8) !struct { frames: u32, duration_ms: i64, width: u32, height: u32 } {
    var d = try Decoder.init(gpa, data);
    defer d.deinit();
    var n: u32 = 0;
    while (try d.next()) |_| n += 1;
    return .{ .frames = n, .duration_ms = d.t_ms, .width = d.width, .height = d.height };
}

// --- tests: the encoder against this decoder

const gif = @import("gif.zig");

fn scene(px: []u32, w: u32, h: u32, t: u32) void {
    for (0..h) |y| for (0..w) |x| {
        const g: u32 = @intCast((x * 255) / w);
        px[y * w + x] = 0xFF000000 | (@as(u32, @intCast(y * 255 / h)) << 16) | g << 8 | 0x40;
    };
    // a white square moving right
    const sx = 4 + t * 6;
    for (10..26) |y| for (sx..sx + 16) |x| {
        if (x < w) px[y * w + x] = 0xFFFFFFFF;
    };
}

test "gif: frames round-trip with their timing and small diffs" {
    const gpa = std.testing.allocator;
    const w = 96;
    const h = 48;
    var px: [w * h]u32 = undefined;
    var enc = try gif.Encoder.init(gpa, w, h, .{}, null);
    defer enc.deinit();
    const times = [_]i64{ 0, 33, 66, 100, 133 };
    for (times, 0..) |t, k| {
        scene(&px, w, h, @intCast(k));
        try enc.addFrame(&px, w, t);
        // an unchanged frame adds nothing
        try enc.addFrame(&px, w, t + 10);
    }
    try enc.finish(200);
    const bytes = enc.out.items;
    try std.testing.expect(std.mem.startsWith(u8, bytes, "GIF89a"));
    try std.testing.expectEqual(@as(u8, 0x3B), bytes[bytes.len - 1]);

    var d = try Decoder.init(gpa, bytes);
    defer d.deinit();
    var k: u32 = 0;
    var last_start: i64 = -1;
    while (try d.next()) |f| : (k += 1) {
        try std.testing.expect(f.start_ms > last_start);
        last_start = f.start_ms;
        // close to the source: the square is white, the rest near
        scene(&px, w, h, k);
        var worst: u32 = 0;
        for (f.pixels, px) |a, b| {
            for (0..3) |c| {
                const sh: u5 = @intCast(c * 8);
                const da = (a >> sh) & 0xFF;
                const db = (b >> sh) & 0xFF;
                worst = @max(worst, if (da > db) da - db else db - da);
            }
        }
        try std.testing.expect(worst <= 48);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), f.pixels[18 * w + 4 + k * 6 + 8]);
    }
    try std.testing.expectEqual(@as(u32, 5), k);
    try std.testing.expectEqual(@as(i64, 200), d.t_ms);
    const s = try stats(gpa, bytes);
    try std.testing.expectEqual(@as(u32, 5), s.frames);
}

test "gif: a still recording stays one frame and tiny" {
    const gpa = std.testing.allocator;
    const w = 200;
    const h = 100;
    var px: [w * h]u32 = undefined;
    scene(&px, w, h, 0);
    var enc = try gif.Encoder.init(gpa, w, h, .{ .dither = .floyd }, null);
    defer enc.deinit();
    var t: i64 = 0;
    while (t < 3000) : (t += 33) try enc.addFrame(&px, w, t);
    try enc.finish(3000);
    const s = try stats(gpa, enc.out.items);
    try std.testing.expectEqual(@as(u32, 1), s.frames);
    try std.testing.expectEqual(@as(i64, 3000), s.duration_ms);
}

test "gif: garbage never crashes the decoder" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [600]u8 = undefined;
    for (0..300) |_| {
        prng.random().bytes(&buf);
        @memcpy(buf[0..6], "GIF89a");
        buf[6] = 20;
        buf[7] = 0;
        buf[8] = 10;
        buf[9] = 0;
        var d = Decoder.init(gpa, &buf) catch continue;
        defer d.deinit();
        var n: usize = 0;
        while (n < 50) : (n += 1) {
            _ = (d.next() catch break) orelse break;
        }
    }
}
