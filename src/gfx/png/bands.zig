//! Parallel compression of the encoder's image data: each band of rows is
//! filtered and deflated on its own thread into a raw deflate fragment,
//! and the fragments' adler32 checksums are combined for one zlib stream.

const std = @import("std");
const flate = std.compress.flate;
const filters = @import("filters.zig");
const pad = filters.pad;

/// rows per filter-strategy decision, and sample rows per probe group
const segment_rows = 64;
const probe_rows = 4;

/// One band of rows compressed into a raw deflate fragment.
pub const Band = struct {
    pixels: []const u32,
    width: u32,
    y0: u32,
    y1: u32,
    last: bool,
    filter: bool,
    /// bytes per pixel: 3 (RGB) or 4 (RGBA)
    bpp: u8 = 3,
    alloc: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    adler: u32 = 1,
    len: u64 = 0,
    err: ?anyerror = null,

    fn run(self: *Band) void {
        self.compress() catch |e| {
            self.err = e;
        };
    }

    fn compress(self: *Band) !void {
        const alloc = self.alloc;
        const row_len = self.rowLen();
        const bufs = try alloc.alloc(u8, Rows.bufLen(row_len));
        defer alloc.free(bufs);
        var rows: Rows = .init(bufs, row_len);
        self.startRows(&rows, self.y0);

        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        const comp = try alloc.create(flate.Compress);
        defer alloc.destroy(comp);
        const raw_len = @as(usize, self.y1 - self.y0) * (row_len + 1);
        try self.out.ensureUnusedCapacity(raw_len / 8 + 1024);
        // the probe reuses the window before the real compressor starts
        // writing, so each needs its own
        const probe_window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(probe_window);
        comp.* = try flate.Compress.init(&self.out.writer, window, .raw, .level_6);

        // probe state for choosing None vs adaptive filters per segment
        var probe: Probe = .{ .window = probe_window };
        defer probe.deinit(alloc);
        if (self.filter) try probe.alloc(alloc, row_len);

        self.adler = try self.writeRows(comp, &rows, &probe);
        // a non-final band ends byte-aligned with no BFINAL block, so the
        // next band's independent deflate stream can follow it directly
        if (self.last) try comp.finish() else try comp.writer.flush();
        self.len = raw_len;
    }

    /// Filter and deflate every row of the band; returns their adler32.
    fn writeRows(self: *Band, comp: *flate.Compress, rows: *Rows, probe: *Probe) !u32 {
        var adler: std.hash.Adler32 = .{};
        var adaptive = self.filter;
        var y = self.y0;
        while (y < self.y1) : (y += 1) {
            if (self.filter and (y - self.y0) % segment_rows == 0) {
                adaptive = try self.probeAdaptive(probe, y, @min(self.y1, y + segment_rows));
            }
            self.filterNext(rows, y, adaptive);
            adler.update(rows.filtered);
            try comp.writer.writeAll(rows.filtered);
        }
        return adler.adler;
    }

    /// Whether adaptive filtering beats filter None on rows [ys, ye): MSAD
    /// wins on photos and gradients but often loses on UI, where it breaks
    /// the exact repeats (glyphs, borders) LZ77 finds in unfiltered rows.
    /// Decided by fast-compressing a few sample rows both ways.
    fn probeAdaptive(self: *Band, probe: *Probe, ys: u32, ye: u32) !bool {
        const row_len = self.rowLen();
        var rows: Rows = .init(probe.bufs, row_len);
        const sink_buf = probe.bufs[Rows.bufLen(row_len)..];
        const mid = ys + (ye - ys) / 2;
        const groups = [2][2]u32{ .{ ys, @min(ye, ys + probe_rows) }, .{ mid, @min(ye, mid + probe_rows) } };
        var sizes: [2]u64 = undefined;
        for (0..2) |mode| {
            var sink: std.Io.Writer.Discarding = .init(sink_buf);
            const comp = probe.comp.?;
            comp.* = try flate.Compress.init(&sink.writer, probe.window, .raw, .level_6);
            for (groups, 0..) |g, gi| {
                if (gi == 1 and g[0] < groups[0][1]) break; // overlapping: short segment
                self.startRows(&rows, g[0]);
                var y = g[0];
                while (y < g[1]) : (y += 1) {
                    self.filterNext(&rows, y, mode == 1);
                    try comp.writer.writeAll(rows.filtered);
                }
            }
            try comp.finish();
            sizes[mode] = sink.fullCount();
        }
        return sizes[1] < sizes[0];
    }

    fn rowLen(self: *const Band) usize {
        return @as(usize, self.width) * self.bpp;
    }

    /// Zero the left padding and load row y-1 (zeros above the image) as
    /// the previous row.
    fn startRows(self: *const Band, rows: *Rows, y: u32) void {
        const w: usize = self.width;
        @memset(rows.cur[0..pad], 0);
        @memset(rows.prev, 0);
        if (y > 0) toBytes(self.pixels[(y - 1) * w ..][0..w], rows.prev[pad..], self.bpp);
    }

    /// Filter row y into rows.filtered; it becomes the previous row.
    inline fn filterNext(self: *const Band, rows: *Rows, y: u32, adaptive: bool) void {
        const w: usize = self.width;
        toBytes(self.pixels[y * w ..][0..w], rows.cur[pad..], self.bpp);
        filters.filterRow(self.bpp, rows.cur, rows.prev, rows.filtered, adaptive);
        std.mem.swap([]u8, &rows.cur, &rows.prev);
    }
};

/// Row buffers: current and previous row as bytes (each with `pad` leading
/// zeros), and the filtered output row (filter byte + data).
const Rows = struct {
    cur: []u8,
    prev: []u8,
    filtered: []u8,

    fn bufLen(row_len: usize) usize {
        return 2 * (pad + row_len) + 1 + row_len;
    }

    fn init(bufs: []u8, row_len: usize) Rows {
        return .{
            .cur = bufs[0 .. pad + row_len],
            .prev = bufs[pad + row_len ..][0 .. pad + row_len],
            .filtered = bufs[2 * (pad + row_len) ..][0 .. 1 + row_len],
        };
    }
};

/// The probe compressor with its own window, row buffers and a small
/// discard buffer after them.
const Probe = struct {
    comp: ?*flate.Compress = null,
    window: []u8,
    bufs: []u8 = &.{},

    fn alloc(self: *Probe, a: std.mem.Allocator, row_len: usize) !void {
        self.comp = try a.create(flate.Compress);
        self.bufs = try a.alloc(u8, Rows.bufLen(row_len) + 64);
    }

    fn deinit(self: *Probe, a: std.mem.Allocator) void {
        a.free(self.bufs);
        if (self.comp) |p| a.destroy(p);
    }
};

fn toBytes(src: []const u32, dst: []u8, bpp: u8) void {
    if (bpp == 4) {
        for (src, 0..) |p, x| {
            dst[x * 4] = @truncate(p >> 16);
            dst[x * 4 + 1] = @truncate(p >> 8);
            dst[x * 4 + 2] = @truncate(p);
            dst[x * 4 + 3] = @truncate(p >> 24);
        }
        return;
    }
    for (src, 0..) |p, x| {
        dst[x * 3] = @truncate(p >> 16);
        dst[x * 3 + 1] = @truncate(p >> 8);
        dst[x * 3 + 2] = @truncate(p);
    }
}

/// Compress every band: bands[0] on this thread, the others on worker
/// threads (or here when a thread cannot be spawned). Returns the first
/// band error. At most 64 bands.
pub fn compressAll(bands: []Band) !void {
    var threads: [64]?std.Thread = @splat(null);
    for (bands[1..], 1..) |*b, i| {
        threads[i] = std.Thread.spawn(.{}, Band.run, .{b}) catch null;
        if (threads[i] == null) b.run(); // no thread: do it here
    }
    bands[0].run();
    for (threads[1..bands.len]) |t| if (t) |th| th.join();
    for (bands) |*b| if (b.err) |e| return e;
}

/// adler32 of all bands' uncompressed data, in order.
pub fn combinedAdler(bands: []const Band) u32 {
    var adler: u32 = bands[0].adler;
    for (bands[1..]) |*b| adler = adlerCombine(adler, b.adler, b.len);
    return adler;
}

/// adler32 of A ++ B from adler32(A), adler32(B) and len(B) (zlib's
/// adler32_combine).
fn adlerCombine(a1: u32, a2: u32, len2: u64) u32 {
    const base: u64 = 65521;
    const rem = len2 % base;
    var sum1: u64 = a1 & 0xFFFF;
    var sum2: u64 = (rem * sum1) % base;
    sum1 += (a2 & 0xFFFF) + base - 1;
    sum2 += (a1 >> 16) + (a2 >> 16) + base - rem;
    if (sum1 >= base) sum1 -= base;
    if (sum1 >= base) sum1 -= base;
    if (sum2 >= base * 2) sum2 -= base * 2;
    if (sum2 >= base) sum2 -= base;
    return @intCast(sum1 | (sum2 << 16));
}

test "adler32 combine" {
    const a = "hello, ";
    const b = "world and more bytes";
    const whole = std.hash.Adler32.hash(a ++ b);
    try std.testing.expectEqual(whole, adlerCombine(std.hash.Adler32.hash(a), std.hash.Adler32.hash(b), b.len));
}
