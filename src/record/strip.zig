//! Small pictures taken along a recording, evenly spaced however long it
//! runs (every k-th frame; when full, every other one is dropped and k
//! doubles): the trim window's filmstrip and the thumbnail's hover
//! preview, with no need to decode the video again.
//!
//! Stored as one PNG, the pictures side by side, plus the frame number of
//! each in the entry's meta.

const std = @import("std");
const yuv = @import("../encode/yuv.zig");

pub const max = 24;
/// each picture's width (height follows the shape)
pub const pic_w = 192;

pub const Strip = struct {
    gpa: std.mem.Allocator,
    w: u32 = 0,
    h: u32 = 0,
    pics: [max][]u32 = @splat(&.{}),
    index: [max]u64 = @splat(0),
    n: usize = 0,
    every: u64 = 1,

    pub fn deinit(self: *Strip) void {
        for (self.pics) |p| self.gpa.free(p);
    }

    /// Offer frame `frame` (src: sw x sh, stride ss); kept when due.
    pub fn offer(self: *Strip, frame: u64, src: []const u32, ss: usize, sw: u32, sh: u32) void {
        if (frame % self.every != 0) return;
        if (self.w == 0) {
            self.w = @min(pic_w, sw);
            self.h = @max(1, @as(u32, @intCast(@as(u64, sh) * self.w / sw)));
        }
        if (self.n == max) self.halve();
        if (frame % self.every != 0) return;
        const pic = self.gpa.alloc(u32, @as(usize, self.w) * self.h) catch return;
        yuv.downscale(src, ss, sw, sh, pic, self.w, self.h);
        self.pics[self.n] = pic;
        self.index[self.n] = frame;
        self.n += 1;
    }

    fn halve(self: *Strip) void {
        var k: usize = 0;
        for (0..self.n) |i| {
            if (i % 2 == 0) {
                self.pics[k] = self.pics[i];
                self.index[k] = self.index[i];
                k += 1;
            } else {
                self.gpa.free(self.pics[i]);
            }
        }
        for (k..max) |i| self.pics[i] = &.{};
        self.n = k;
        self.every *= 2;
    }

    /// All pictures side by side (n*w x h), owned by the caller.
    pub fn joined(self: *const Strip, gpa: std.mem.Allocator) ![]u32 {
        const total_w = self.w * @as(u32, @intCast(self.n));
        const out = try gpa.alloc(u32, @as(usize, total_w) * self.h);
        for (self.pics[0..self.n], 0..) |p, i| {
            for (0..self.h) |y| @memcpy(out[y * total_w + i * self.w ..][0..self.w], p[y * self.w ..][0..self.w]);
        }
        return out;
    }

    /// "0,12,24,..." for the meta.
    pub fn indexList(self: *const Strip, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.index[0..self.n], 0..) |f, i| {
            const s = std.fmt.bufPrint(buf[n..], "{s}{d}", .{ if (i > 0) "," else "", f }) catch break;
            n += s.len;
        }
        return buf[0..n];
    }
};

test "pictures stay evenly spaced and bounded" {
    const gpa = std.testing.allocator;
    var s: Strip = .{ .gpa = gpa };
    defer s.deinit();
    var px: [400 * 100]u32 = @splat(0xFF336699);
    for (0..1000) |f| s.offer(f, &px, 400, 400, 100);
    try std.testing.expect(s.n <= max and s.n >= max / 2);
    const step = s.index[1] - s.index[0];
    for (1..s.n) |i| try std.testing.expectEqual(step, s.index[i] - s.index[i - 1]);
    try std.testing.expectEqual(@as(u32, 192), s.w);
    try std.testing.expectEqual(@as(u32, 48), s.h);
    const j = try s.joined(gpa);
    defer gpa.free(j);
    try std.testing.expectEqual(@as(u32, 0xFF336699), j[5]);
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, s.indexList(&buf), "0,"));
}
