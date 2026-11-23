//! The editor's document, in image pixels and free of any window: the
//! annotations, the selected region, undo/redo, the native-resolution
//! composite layer and export (crop + optional "beautify" frame, in
//! doc/compose.zig).

const std = @import("std");
const shapes = @import("shapes.zig");

pub const Shape = shapes.Shape;
pub const Rect = shapes.Rect;
pub const Point = shapes.Point;

const max_undo = 200;

pub const Document = struct {
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    shapes: std.ArrayList(Shape) = .empty,
    /// selected region in image pixels (normalized except mid-drag)
    sel: ?Rect = null,
    undo_stack: std.ArrayList(Snap) = .empty,
    redo_stack: std.ArrayList(Snap) = .empty,
    /// the mark of the change the last undo or redo crossed (0: none);
    /// changes beyond the shapes (a crop) are marked to be found again
    last_mark: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) Document {
        return .{ .alloc = alloc, .width = width, .height = height };
    }

    pub fn deinit(self: *Document) void {
        freeShapes(self.alloc, self.shapes.items);
        self.shapes.deinit(self.alloc);
        for (self.undo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.undo_stack.deinit(self.alloc);
        for (self.redo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.redo_stack.deinit(self.alloc);
    }

    pub fn imageRect(self: *const Document) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    /// What gets exported: the selection clipped to the image, or exactly
    /// the image when nothing (or nothing visible) is selected.
    pub fn exportRect(self: *const Document) Rect {
        const img = self.imageRect();
        const s = self.sel orelse return img;
        return Rect.intersect(s.normalized(), img) orelse img;
    }

    // --- undo ---

    /// Shapes as they were before a change, and that change's mark.
    pub const Snap = struct { shapes: []Shape, mark: u32 = 0 };

    fn snapshot(self: *Document) ![]Shape {
        const snap = try self.alloc.alloc(Shape, self.shapes.items.len);
        var n: usize = 0;
        errdefer {
            freeShapes(self.alloc, snap[0..n]);
            self.alloc.free(snap);
        }
        for (self.shapes.items) |*s| {
            snap[n] = try s.clone(self.alloc);
            n += 1;
        }
        return snap;
    }

    /// Record the current shapes so the next change can be undone.
    pub fn checkpoint(self: *Document) !void {
        return self.checkpointMarked(0);
    }

    /// checkpoint() for a change `mark` names (see last_mark).
    pub fn checkpointMarked(self: *Document, mark: u32) !void {
        const snap: Snap = .{ .shapes = try self.snapshot(), .mark = mark };
        errdefer freeSnapshot(self.alloc, snap);
        if (self.undo_stack.items.len >= max_undo) {
            freeSnapshot(self.alloc, self.undo_stack.orderedRemove(0));
        }
        try self.undo_stack.append(self.alloc, snap);
        for (self.redo_stack.items) |s| freeSnapshot(self.alloc, s);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Forget the last checkpoint (the change it guarded never happened).
    pub fn dropCheckpoint(self: *Document) void {
        if (self.undo_stack.pop()) |s| freeSnapshot(self.alloc, s);
    }

    fn swapIn(self: *Document, snap: []Shape) void {
        freeShapes(self.alloc, self.shapes.items);
        self.shapes.clearRetainingCapacity();
        // capacity was reserved by the caller
        self.shapes.appendSliceAssumeCapacity(snap);
        self.alloc.free(snap);
    }

    pub fn undo(self: *Document) !bool {
        return self.step(&self.undo_stack, &self.redo_stack);
    }

    pub fn redo(self: *Document) !bool {
        return self.step(&self.redo_stack, &self.undo_stack);
    }

    /// Back to the top of `from`; the current shapes go onto `to` with
    /// the same mark, so the change can be crossed again either way.
    fn step(self: *Document, from: *std.ArrayList(Snap), to: *std.ArrayList(Snap)) !bool {
        if (from.items.len == 0) return false;
        const snap = from.items[from.items.len - 1];
        const cur: Snap = .{ .shapes = try self.snapshot(), .mark = snap.mark };
        errdefer freeSnapshot(self.alloc, cur);
        try to.ensureUnusedCapacity(self.alloc, 1);
        try self.shapes.ensureTotalCapacity(self.alloc, snap.shapes.len);
        _ = from.pop();
        self.swapIn(snap.shapes);
        to.appendAssumeCapacity(cur);
        self.last_mark = snap.mark;
        return true;
    }

    /// Drop the changes since the last checkpoint (and the checkpoint).
    pub fn revert(self: *Document) !void {
        if (self.undo_stack.items.len == 0) return;
        const snap = self.undo_stack.items[self.undo_stack.items.len - 1];
        try self.shapes.ensureTotalCapacity(self.alloc, snap.shapes.len);
        _ = self.undo_stack.pop();
        self.swapIn(snap.shapes);
    }

    // --- shape edits (callers checkpoint first) ---

    /// Take ownership of `s` and put it on top.
    pub fn add(self: *Document, s: Shape) !usize {
        var owned = s;
        errdefer owned.deinit(self.alloc);
        try self.shapes.append(self.alloc, owned);
        return self.shapes.items.len - 1;
    }

    pub fn remove(self: *Document, i: usize) void {
        var s = self.shapes.orderedRemove(i);
        s.deinit(self.alloc);
    }

    /// Copy shape `i` on top, offset by (dx, dy); returns the new index.
    pub fn duplicate(self: *Document, i: usize, dx: i32, dy: i32) !usize {
        var c = try self.shapes.items[i].clone(self.alloc);
        c.translate(dx, dy);
        if (c.tool == .counter) c.number = self.nextNumber();
        return self.add(c);
    }

    pub fn bringToFront(self: *Document, i: usize) usize {
        const s = self.shapes.orderedRemove(i);
        self.shapes.appendAssumeCapacity(s);
        return self.shapes.items.len - 1;
    }

    /// Topmost shape at image point `p` (within `tol` image pixels).
    pub fn hit(self: *const Document, p: Point, tol: f64) ?usize {
        var i = self.shapes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.shapes.items[i].hitTest(p, tol)) return i;
        }
        return null;
    }

    /// Number for the next counter badge.
    pub fn nextNumber(self: *const Document) u32 {
        var n: u32 = 0;
        for (self.shapes.items) |s| {
            if (s.tool == .counter) n = @max(n, s.number);
        }
        return n + 1;
    }

    // --- selection ---

    /// Move the selection by (dx, dy), kept inside the image.
    pub fn moveSelection(self: *Document, dx: i32, dy: i32) void {
        const s = (self.sel orelse return).normalized();
        const iw: i32 = @intCast(self.width);
        const ih: i32 = @intCast(self.height);
        self.sel = .{
            .x = std.math.clamp(s.x + dx, 0, @max(0, iw - s.w)),
            .y = std.math.clamp(s.y + dy, 0, @max(0, ih - s.h)),
            .w = s.w,
            .h = s.h,
        };
    }
};

fn freeShapes(alloc: std.mem.Allocator, list: []Shape) void {
    for (list) |*s| s.deinit(alloc);
}

fn freeSnapshot(alloc: std.mem.Allocator, snap: Document.Snap) void {
    freeShapes(alloc, snap.shapes);
    alloc.free(snap.shapes);
}

// the frame around an export (beautify.zig)
const beautify = @import("beautify.zig");
pub const Background = beautify.Background;
pub const backgrounds = beautify.backgrounds;
pub const padding_pct = beautify.padding_pct;
pub const Beautify = beautify.Beautify;

// the composite layer and export (doc/compose.zig)
const compose = @import("doc/compose.zig");
pub const composeRegion = compose.composeRegion;
pub const paintOnTop = compose.paintOnTop;
pub const Exported = compose.Exported;
pub const exportImage = compose.exportImage;

comptime {
    _ = compose;
}

// --- tests ---

const testing = std.testing;

test "export is exactly the image without a selection" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 300, 200);
    defer d.deinit();
    try testing.expect(d.exportRect().eql(.{ .x = 0, .y = 0, .w = 300, .h = 200 }));
    // a selection entirely off the image falls back to the whole image
    d.sel = .{ .x = 400, .y = 0, .w = 10, .h = 10 };
    try testing.expect(d.exportRect().eql(d.imageRect()));
}

test "export intersects a selection hanging off the image" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 300, 200);
    defer d.deinit();
    d.sel = .{ .x = 250, .y = -20, .w = 100, .h = 70 };
    try testing.expect(d.exportRect().eql(.{ .x = 250, .y = 0, .w = 50, .h = 50 }));
    // unnormalized (mid-drag) selections work too
    d.sel = .{ .x = 50, .y = 60, .w = -60, .h = -10 };
    try testing.expect(d.exportRect().eql(.{ .x = 0, .y = 50, .w = 50, .h = 10 }));
}

test "undo and redo cover add, move, recolour, delete, duplicate and z-order" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    try d.checkpoint();
    _ = try d.add(.{ .tool = .rect, .color = 1, .thickness = 2, .p1 = .{ .x = 10, .y = 10 } });
    try d.checkpoint();
    _ = try d.add(.{ .tool = .counter, .color = 2, .thickness = 2, .number = d.nextNumber() });
    try testing.expectEqual(@as(u32, 1), d.shapes.items[1].number);
    try d.checkpoint();
    d.shapes.items[0].translate(5, 5);
    d.shapes.items[0].color = 9;
    try d.checkpoint();
    const dup = try d.duplicate(1, 10, 10);
    try testing.expectEqual(@as(u32, 2), d.shapes.items[dup].number);
    try d.checkpoint();
    _ = d.bringToFront(0);
    try testing.expectEqual(shapes.Tool.rect, d.shapes.items[2].tool);
    try d.checkpoint();
    d.remove(2);
    try testing.expectEqual(@as(usize, 2), d.shapes.items.len);

    try testing.expect(try d.undo()); // delete
    try testing.expectEqual(@as(usize, 3), d.shapes.items.len);
    try testing.expect(try d.undo()); // z-order
    try testing.expectEqual(shapes.Tool.rect, d.shapes.items[0].tool);
    try testing.expect(try d.undo()); // duplicate
    try testing.expectEqual(@as(usize, 2), d.shapes.items.len);
    try testing.expect(try d.undo()); // move + recolour
    try testing.expectEqual(@as(i32, 0), d.shapes.items[0].p0.x);
    try testing.expectEqual(@as(u32, 1), d.shapes.items[0].color);
    try testing.expect(try d.redo());
    try testing.expectEqual(@as(u32, 9), d.shapes.items[0].color);
    try testing.expect(try d.undo());
    try testing.expect(try d.undo());
    try testing.expect(try d.undo());
    try testing.expectEqual(@as(usize, 0), d.shapes.items.len);
    try testing.expect(!try d.undo());
    // a new change clears redo
    try d.checkpoint();
    _ = try d.add(.{ .tool = .line, .color = 1, .thickness = 1 });
    try testing.expect(!try d.redo());
    d.dropCheckpoint();
    try testing.expect(!try d.undo());
}

test "hit picks the topmost shape" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    _ = try d.add(.{ .tool = .redact, .color = 1, .thickness = 2, .p1 = .{ .x = 50, .y = 50 } });
    _ = try d.add(.{ .tool = .redact, .color = 2, .thickness = 2, .p0 = .{ .x = 20, .y = 20 }, .p1 = .{ .x = 60, .y = 60 } });
    try testing.expectEqual(@as(?usize, 1), d.hit(.{ .x = 30, .y = 30 }, 1));
    try testing.expectEqual(@as(?usize, 0), d.hit(.{ .x = 5, .y = 5 }, 1));
    try testing.expectEqual(@as(?usize, null), d.hit(.{ .x = 90, .y = 90 }, 1));
}

test "keyboard selection moves stay inside the image" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 80);
    defer d.deinit();
    d.sel = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    d.moveSelection(-50, 0);
    try testing.expectEqual(@as(i32, 0), d.sel.?.x);
    d.moveSelection(500, 500);
    try testing.expect(d.sel.?.eql(.{ .x = 80, .y = 60, .w = 20, .h = 20 }));
}

test "undo covers a text box's width" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    try d.checkpoint();
    const i = try d.add(.{ .tool = .text, .color = 1, .thickness = 2 });
    try d.shapes.items[i].str.appendSlice(alloc, "hello world");
    try d.checkpoint();
    d.shapes.items[i].box_w = 40;
    try testing.expect(try d.undo());
    try testing.expectEqual(@as(i32, 0), d.shapes.items[i].box_w);
    try testing.expect(try d.redo());
    try testing.expectEqual(@as(i32, 40), d.shapes.items[i].box_w);
}

test "a marked change is named again by the undo and redo crossing it" {
    const alloc = testing.allocator;
    var d = Document.init(alloc, 100, 100);
    defer d.deinit();
    try d.checkpoint();
    _ = try d.add(.{ .tool = .rect, .color = 1, .thickness = 2 });
    try d.checkpointMarked(7);
    d.shapes.items[0].translate(-10, -10);
    try testing.expect(try d.undo());
    try testing.expectEqual(@as(u32, 7), d.last_mark);
    try testing.expectEqual(@as(i32, 0), d.shapes.items[0].p0.x);
    try testing.expect(try d.redo());
    try testing.expectEqual(@as(u32, 7), d.last_mark);
    try testing.expectEqual(@as(i32, -10), d.shapes.items[0].p0.x);
    try testing.expect(try d.undo());
    try testing.expect(try d.undo());
    try testing.expectEqual(@as(u32, 0), d.last_mark);
}
