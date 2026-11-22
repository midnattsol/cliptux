//! The latest picture of the recorded area, handed from PipeWire's thread
//! to the encoder's: three buffers, so the producer always has one to
//! fill while the encoder reads another and a third holds the newest.
//! Memory stays at three frames however far the encoder lags (it then
//! repeats or skips pictures, never queues them).

const std = @import("std");
const sync = @import("sync.zig");
const region = @import("region.zig");
const media = @import("../platform/api.zig").record;

pub const Latest = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    arrived: sync.Event = .{},
    bufs: [3][]u32 = .{ &.{}, &.{}, &.{} },
    width: u32 = 0,
    height: u32 = 0,
    /// newest complete buffer, the one the encoder reads (null: none)
    front: ?u2 = null,
    reading: ?u2 = null,
    /// pictures received; when the first arrived (monotonic ns)
    count: u64 = 0,
    first_ns: i64 = 0,
    /// the logical area (in the stream's logical rect) to keep, or null
    /// for the whole frame
    crop: ?region.Rect = null,
    stream_rect: region.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    frozen: bool = false,

    pub fn deinit(self: *Latest) void {
        for (self.bufs) |b| self.gpa.free(b);
    }

    /// The pixel area of a w x h frame to keep (the size is fixed by the
    /// first frame: later ones of another size are cropped or padded).
    fn area(self: *const Latest, w: u32, h: u32) ?region.Rect {
        const c = self.crop orelse return .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };
        var r = self.stream_rect;
        if (r.w <= 0 or r.h <= 0) r = .{ .x = r.x, .y = r.y, .w = @intCast(w), .h = @intCast(h) };
        return region.toPixels(c, r, w, h);
    }

    /// PipeWire callback: copy the area out of the mapped buffer.
    pub fn onVideo(ctx: *anyopaque, raw: *const media.Raw) void {
        const self: *Latest = @ptrCast(@alignCast(ctx));
        if (@atomicLoad(bool, &self.frozen, .acquire)) return;
        const a = self.area(raw.width, raw.height) orelse return;
        if (self.width == 0) self.allocate(@intCast(a.w), @intCast(a.h)) catch return;
        self.mutex.lock();
        const slot: u2 = for (0..3) |i| {
            const s: u2 = @intCast(i);
            if (self.front != s and self.reading != s) break s;
        } else unreachable;
        self.mutex.unlock();
        copyArea(self.bufs[slot], self.width, self.height, raw, a);
        self.mutex.lock();
        self.front = slot;
        if (self.count == 0) self.first_ns = raw.time_ns;
        self.count += 1;
        self.mutex.unlock();
        self.arrived.signal();
    }

    fn allocate(self: *Latest, w: u32, h: u32) !void {
        for (&self.bufs) |*b| {
            b.* = try self.gpa.alloc(u32, @as(usize, w) * h);
            @memset(b.*, 0xFF000000);
        }
        self.height = h;
        @atomicStore(u32, &self.width, w, .release);
    }

    /// The newest picture (w x h), held until the next call; null before
    /// the first.
    pub fn acquire(self: *Latest) ?[]const u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const f = self.front orelse return null;
        self.reading = f;
        return self.bufs[f];
    }

    pub fn received(self: *Latest) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

/// Copy area `a` of `raw` into dst (w x h), as 0xFFRRGGBB.
fn copyArea(dst: []u32, w: u32, h: u32, raw: *const media.Raw, a: region.Rect) void {
    const cw = @min(w, @as(u32, @intCast(a.w)));
    const ch = @min(h, @as(u32, @intCast(a.h)));
    const swap = switch (raw.format) {
        .RGBA, .RGBx => true,
        else => false,
    };
    for (0..ch) |y| {
        const src_row: [*]const u8 = raw.base + (@as(usize, @intCast(a.y)) + y) * raw.stride + @as(usize, @intCast(a.x)) * 4;
        const out = dst[y * w ..][0..cw];
        const src: [*]align(1) const u32 = @ptrCast(src_row);
        if (swap) {
            for (out, 0..) |*o, i| {
                const v = src[i];
                o.* = 0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF);
            }
        } else {
            for (out, 0..) |*o, i| o.* = src[i] | 0xFF000000;
        }
    }
}

test "the area is cropped out and converted" {
    const gpa = std.testing.allocator;
    var l: Latest = .{ .gpa = gpa, .crop = .{ .x = 2, .y = 1, .w = 2, .h = 2 }, .stream_rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 } };
    defer l.deinit();
    var px: [16]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i);
    const raw: media.Raw = .{ .base = @ptrCast(&px), .stride = 16, .width = 4, .height = 4, .format = .BGRx, .time_ns = 5 };
    try std.testing.expect(l.acquire() == null);
    Latest.onVideo(&l, &raw);
    const f = l.acquire().?;
    try std.testing.expectEqualSlices(u32, &.{ 0xFF000006, 0xFF000007, 0xFF00000A, 0xFF00000B }, f);
    // the producer never writes the buffer being read
    Latest.onVideo(&l, &raw);
    Latest.onVideo(&l, &raw);
    try std.testing.expect(l.front.? != l.reading.?);
    try std.testing.expectEqual(@as(u64, 3), l.received());
    try std.testing.expectEqual(@as(i64, 5), l.first_ns);
}
