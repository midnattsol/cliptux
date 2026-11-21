//! GIF's variable-length LZW (codes of 9 to 12 bits for 8-bit pixels),
//! both ways: the encoder writes the image data sub-blocks, the decoder
//! reads them back (tests, the trim window, the thumbnail).

const std = @import("std");

const max_code = 4096;
const hsize = 8191; // prime, about twice the table

pub const Encoder = struct {
    keys: [hsize]u32 = undefined,
    vals: [hsize]u16 = undefined,
    used: [hsize]u32 = @splat(0),
    gen: u32 = 0,

    /// Append the LZW data of `pixels` (min code size 8) as GIF
    /// sub-blocks, with the terminating empty block.
    pub fn encode(self: *Encoder, gpa: std.mem.Allocator, pixels: []const u8, out: *std.ArrayList(u8)) !void {
        var bits: BitSink = .{ .gpa = gpa, .out = out };
        try out.append(gpa, 8);
        const clear: u32 = 256;
        const eoi: u32 = 257;
        var size: u5 = 9;
        var next: u32 = 258;
        self.reset();
        try bits.put(clear, size);
        if (pixels.len == 0) {
            try bits.put(eoi, size);
            return bits.finish();
        }
        var prefix: u32 = pixels[0];
        for (pixels[1..]) |c| {
            const key = prefix << 8 | c;
            if (self.find(key)) |code| {
                prefix = code;
                continue;
            }
            if (next - 1 >= @as(u32, 1) << size and size < 12) size += 1;
            try bits.put(prefix, size);
            self.insert(key, @intCast(next));
            next += 1;
            if (next == max_code) {
                try bits.put(clear, size);
                size = 9;
                next = 258;
                self.reset();
            }
            prefix = c;
        }
        if (next - 1 >= @as(u32, 1) << size and size < 12) size += 1;
        try bits.put(prefix, size);
        // the decoder adds one more entry before reading EOI
        next += 1;
        if (next - 1 >= @as(u32, 1) << size and size < 12) size += 1;
        try bits.put(eoi, size);
        try bits.finish();
    }

    fn reset(self: *Encoder) void {
        self.gen +%= 1;
        if (self.gen == 0) {
            @memset(&self.used, 0);
            self.gen = 1;
        }
    }

    fn slot(key: u32) usize {
        return @intCast((key *% 2654435761) % hsize);
    }

    fn find(self: *const Encoder, key: u32) ?u16 {
        var i = slot(key);
        while (self.used[i] == self.gen) : (i = (i + 1) % hsize) {
            if (self.keys[i] == key) return self.vals[i];
        }
        return null;
    }

    fn insert(self: *Encoder, key: u32, code: u16) void {
        var i = slot(key);
        while (self.used[i] == self.gen) i = (i + 1) % hsize;
        self.used[i] = self.gen;
        self.keys[i] = key;
        self.vals[i] = code;
    }
};

/// LSB-first bit packing into 255-byte sub-blocks.
const BitSink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    acc: u64 = 0,
    n: u6 = 0,
    block: [255]u8 = undefined,
    blen: usize = 0,

    fn put(self: *BitSink, code: u32, size: u5) !void {
        self.acc |= @as(u64, code) << self.n;
        self.n += size;
        while (self.n >= 8) {
            try self.byte(@truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    fn byte(self: *BitSink, b: u8) !void {
        self.block[self.blen] = b;
        self.blen += 1;
        if (self.blen == 255) try self.flushBlock();
    }

    fn flushBlock(self: *BitSink) !void {
        if (self.blen == 0) return;
        try self.out.append(self.gpa, @intCast(self.blen));
        try self.out.appendSlice(self.gpa, self.block[0..self.blen]);
        self.blen = 0;
    }

    fn finish(self: *BitSink) !void {
        if (self.n > 0) try self.byte(@truncate(self.acc));
        self.acc = 0;
        self.n = 0;
        try self.flushBlock();
        try self.out.append(self.gpa, 0);
    }
};

/// Decode sub-blocks starting at data[pos.*] (the min code size byte)
/// into `out` (exactly out.len pixels; extra codes are an error, missing
/// ones leave the rest 0). Advances pos past the terminating block.
pub fn decode(data: []const u8, pos: *usize, out: []u8) !void {
    if (pos.* >= data.len) return error.Truncated;
    const min: u4 = @intCast(std.math.clamp(data[pos.*], 2, 11));
    pos.* += 1;
    var d: Decoder = .{ .min = min };
    d.reset();
    var o: usize = 0;
    var acc: u64 = 0;
    var n: u6 = 0;
    var done = false;
    while (true) {
        if (pos.* >= data.len) return error.Truncated;
        const len = data[pos.*];
        pos.* += 1;
        if (len == 0) break;
        if (pos.* + len > data.len) return error.Truncated;
        for (data[pos.* .. pos.* + len]) |b| {
            acc |= @as(u64, b) << n;
            n += 8;
            while (!done and n >= d.size) {
                const code: u16 = @intCast(acc & ((@as(u64, 1) << d.size) - 1));
                acc >>= d.size;
                n -= d.size;
                done = try d.step(code, out, &o);
            }
        }
        pos.* += len;
    }
}

const Decoder = struct {
    min: u4,
    size: u4 = 0,
    avail: u16 = 0,
    prev: ?u16 = null,
    prefix: [max_code]u16 = undefined,
    suffix: [max_code]u8 = undefined,
    first: [max_code]u8 = undefined,
    len: [max_code]u16 = undefined,

    fn clearCode(self: *const Decoder) u16 {
        return @as(u16, 1) << self.min;
    }

    fn reset(self: *Decoder) void {
        const clear = self.clearCode();
        for (0..clear) |i| {
            self.suffix[i] = @intCast(i);
            self.first[i] = @intCast(i);
            self.len[i] = 1;
        }
        self.size = self.min + 1;
        self.avail = clear + 2;
        self.prev = null;
    }

    /// One code; true at the end of the data.
    fn step(self: *Decoder, code: u16, out: []u8, o: *usize) !bool {
        const clear = self.clearCode();
        if (code == clear) {
            self.reset();
            return false;
        }
        if (code == clear + 1) return true;
        const p = self.prev orelse {
            if (code >= clear) return error.BadCode;
            try self.emit(code, out, o);
            self.prev = code;
            return false;
        };
        if (code < self.avail) {
            try self.emit(code, out, o);
            self.add(p, self.first[code]);
        } else if (code == self.avail) {
            self.add(p, self.first[p]);
            try self.emit(code, out, o);
        } else return error.BadCode;
        if (self.avail == @as(u16, 1) << self.size and self.size < 12) self.size += 1;
        self.prev = code;
        return false;
    }

    fn add(self: *Decoder, p: u16, c: u8) void {
        if (self.avail >= max_code) return;
        const a = self.avail;
        self.prefix[a] = p;
        self.suffix[a] = c;
        self.first[a] = self.first[p];
        self.len[a] = self.len[p] + 1;
        self.avail += 1;
    }

    fn emit(self: *const Decoder, code: u16, out: []u8, o: *usize) !void {
        const l = self.len[code];
        if (o.* + l > out.len) return error.TooManyPixels;
        var c = code;
        var i: usize = l;
        while (i > 0) {
            i -= 1;
            out[o.* + i] = self.suffix[c];
            c = self.prefix[c];
        }
        o.* += l;
    }
};

test "lzw round-trips random, repetitive and long data" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const enc = try gpa.create(Encoder);
    defer gpa.destroy(enc);
    enc.* = .{};
    const lens = [_]usize{ 1, 2, 300, 5000, 200_000 };
    for (lens, 0..) |n, k| {
        const src = try gpa.alloc(u8, n);
        defer gpa.free(src);
        for (src, 0..) |*b, i| b.* = switch (k % 3) {
            0 => prng.random().int(u8),
            1 => @intCast((i / 37) % 7),
            else => if (prng.random().boolean()) 3 else prng.random().int(u8),
        };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try enc.encode(gpa, src, &out);
        const back = try gpa.alloc(u8, n);
        defer gpa.free(back);
        @memset(back, 0xAA);
        var pos: usize = 0;
        try decode(out.items, &pos, back);
        try std.testing.expectEqual(out.items.len, pos);
        try std.testing.expectEqualSlices(u8, src, back);
    }
}
