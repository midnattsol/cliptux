//! The record picker's selection, in the desktop's logical pixels:
//! drag out an area, move it, resize it by its handles; a click takes the
//! whole monitor under the pointer. Pure geometry (picker.zig draws it).

const std = @import("std");
const region = @import("../../record/region.zig");

pub const Rect = region.Rect;
pub const Point = struct { x: i32, y: i32 };

/// 0..7: corners and edges, clockwise from the top-left
pub const Handle = u3;

pub const Drag = union(enum) {
    none,
    selecting: Point,
    moving: struct { orig: Rect, start: Point },
    resizing: struct { handle: Handle, orig: Rect },
};

pub const handle_hit = 9;
/// smaller than this is a click, not a drag
const min_size = 4;

pub const Selection = struct {
    sel: ?Rect = null,
    drag: Drag = .none,
    /// the monitors (logical rects): bounds and click targets
    monitors: []const Rect,

    pub fn handlePoint(r: Rect, h: Handle) Point {
        const xs = [3]i32{ r.x, r.x + @divTrunc(r.w, 2), r.right() };
        const ys = [3]i32{ r.y, r.y + @divTrunc(r.h, 2), r.bottom() };
        const at = [8][2]u2{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
        return .{ .x = xs[at[h][0]], .y = ys[at[h][1]] };
    }

    pub fn handleAt(self: *const Selection, p: Point) ?Handle {
        const r = self.sel orelse return null;
        for (0..8) |i| {
            const hp = handlePoint(r, @intCast(i));
            if (@abs(hp.x - p.x) <= handle_hit and @abs(hp.y - p.y) <= handle_hit) return @intCast(i);
        }
        return null;
    }

    pub fn press(self: *Selection, p: Point) void {
        if (self.handleAt(p)) |h| {
            self.drag = .{ .resizing = .{ .handle = h, .orig = self.sel.? } };
        } else if (self.sel != null and inside(self.sel.?, p)) {
            self.drag = .{ .moving = .{ .orig = self.sel.?, .start = p } };
        } else {
            self.drag = .{ .selecting = p };
            self.sel = .{ .x = p.x, .y = p.y, .w = 0, .h = 0 };
        }
    }

    pub fn motion(self: *Selection, p: Point) void {
        switch (self.drag) {
            .none => {},
            .selecting => |a| self.sel = span(a, p),
            .moving => |m| self.sel = self.keepInside(.{ .x = m.orig.x + p.x - m.start.x, .y = m.orig.y + p.y - m.start.y, .w = m.orig.w, .h = m.orig.h }),
            .resizing => |rz| self.sel = resize(rz.orig, rz.handle, p),
        }
    }

    pub fn release(self: *Selection, p: Point) void {
        const was = self.drag;
        self.drag = .none;
        if (was != .selecting) return;
        const s = self.sel orelse return;
        if (s.w < min_size or s.h < min_size) self.sel = self.monitorAt(p);
    }

    pub fn monitorAt(self: *const Selection, p: Point) ?Rect {
        for (self.monitors) |m| if (inside(m, p)) return m;
        return if (self.monitors.len > 0) self.monitors[0] else null;
    }

    /// Moved areas stay on the monitor they mostly cover.
    fn keepInside(self: *const Selection, r: Rect) Rect {
        const i = region.bestMonitor(r, self.monitors) orelse return r;
        const m = self.monitors[i];
        return .{
            .x = std.math.clamp(r.x, m.x, @max(m.x, m.right() - r.w)),
            .y = std.math.clamp(r.y, m.y, @max(m.y, m.bottom() - r.h)),
            .w = r.w,
            .h = r.h,
        };
    }
};

pub fn inside(r: Rect, p: Point) bool {
    return p.x >= r.x and p.y >= r.y and p.x < r.right() and p.y < r.bottom();
}

pub fn span(a: Point, b: Point) Rect {
    return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .w = @intCast(@abs(a.x - b.x)), .h = @intCast(@abs(a.y - b.y)) };
}

/// `orig` with handle `h` dragged to `p` (flipping over as needed).
pub fn resize(orig: Rect, h: Handle, p: Point) Rect {
    var x0 = orig.x;
    var y0 = orig.y;
    var x1 = orig.right();
    var y1 = orig.bottom();
    switch (h) {
        0 => {
            x0 = p.x;
            y0 = p.y;
        },
        1 => y0 = p.y,
        2 => {
            x1 = p.x;
            y0 = p.y;
        },
        3 => x1 = p.x,
        4 => {
            x1 = p.x;
            y1 = p.y;
        },
        5 => y1 = p.y,
        6 => {
            x0 = p.x;
            y1 = p.y;
        },
        7 => x0 = p.x,
    }
    return span(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 });
}

test "drag, move, resize and click" {
    const mons = [_]Rect{ .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .{ .x = 1600, .y = 0, .w = 1280, .h = 720 } };
    var s: Selection = .{ .monitors = &mons };
    s.press(.{ .x = 500, .y = 400 });
    s.motion(.{ .x = 100, .y = 100 });
    s.release(.{ .x = 100, .y = 100 });
    try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    // move, kept on the monitor
    s.press(.{ .x = 200, .y = 200 });
    s.motion(.{ .x = 0, .y = 200 });
    s.release(.{ .x = 0, .y = 200 });
    try std.testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    // the bottom-right handle
    s.press(.{ .x = 400, .y = 400 });
    s.motion(.{ .x = 500, .y = 450 });
    s.release(.{ .x = 500, .y = 450 });
    try std.testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 500, .h = 350 }, s.sel.?);
    // a click elsewhere: that whole monitor
    s.press(.{ .x = 2000, .y = 300 });
    s.release(.{ .x = 2001, .y = 301 });
    try std.testing.expectEqual(mons[1], s.sel.?);
}
