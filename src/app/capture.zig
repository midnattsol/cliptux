//! What a capture hands to the editor: one image covering every captured
//! monitor, and where each monitor lies inside it.

const std = @import("std");
const png = @import("../gfx/png.zig");

pub const Monitor = struct {
    /// pixel rectangle of this monitor inside `Capture.image`
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// the monitor in the compositor's logical layout, as the ScreenCast
    /// portal reports it (stream `position` and `size`); null when unknown,
    /// as with --from or the Screenshot portal
    logical: ?Logical = null,

    pub const Logical = struct { x: i32, y: i32, w: u32, h: u32 };
};

pub const Capture = struct {
    image: png.Image,
    /// at least one entry; a single monitor spanning the image when the
    /// layout is unknown
    monitors: []Monitor,

    /// A capture whose layout is unknown: the whole image is one monitor.
    pub fn single(alloc: std.mem.Allocator, image: png.Image) !Capture {
        const mons = try alloc.alloc(Monitor, 1);
        mons[0] = .{ .x = 0, .y = 0, .w = image.width, .h = image.height };
        return .{ .image = image, .monitors = mons };
    }

    pub fn deinit(self: *Capture, alloc: std.mem.Allocator) void {
        self.image.deinit(alloc);
        alloc.free(self.monitors);
        self.* = undefined;
    }
};

test "single capture spans the image" {
    const alloc = std.testing.allocator;
    const px = try alloc.alloc(u32, 6);
    @memset(px, 0);
    var cap = try Capture.single(alloc, .{ .width = 3, .height = 2, .pixels = px });
    defer cap.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cap.monitors.len);
    try std.testing.expectEqual(@as(u32, 3), cap.monitors[0].w);
}
