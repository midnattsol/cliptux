//! Crop mode (C): the selection becomes the crop frame, with handles and
//! a rule-of-thirds grid; the toolbar offers the aspect ratios, Cancel
//! and Apply. Enter applies, Esc leaves the picture as it was.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const crop = @import("crop.zig");
const tools = @import("mod.zig");

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = shapes.Rect;
const Point = shapes.Point;

pub fn enter(ed: *Editor) !void {
    if (ed.tools.mode == .crop) return apply(ed);
    try ed.settle();
    ed.closePopover();
    ed.selected = null;
    ed.tools.mode = .crop;
    if (ed.doc.sel == null) ed.doc.sel = ed.doc.imageRect();
    try setAspect(ed, ed.tools.aspect);
    ed.selDirty();
    std.log.info("crop: started", .{});
}

pub fn setAspect(ed: *Editor, a: tools.Aspect) !void {
    ed.tools.aspect = a;
    const k = crop.ratio(a) orelse return;
    const s = (ed.doc.sel orelse return).normalized();
    ed.selDirty();
    ed.doc.sel = crop.fitInside(Rect.intersect(s, ed.doc.imageRect()) orelse ed.doc.imageRect(), k);
    ed.selDirty();
}

/// A press while cropping: move or resize the frame, or draw a new one.
pub fn onPress(ed: *Editor) bool {
    if (ed.tools.mode != .crop) return false;
    const m = ed.mouse;
    const ip = clampImg(ed, ed.imgAt(m));
    if (ed.selBuf()) |n| {
        if (shapes.handleAt(n, m, ed.handleRadius())) |h| {
            ed.drag = .{ .resizing_sel = .{ .handle = h, .orig = ed.doc.sel.?.normalized() } };
            return true;
        }
        if (n.contains(m.x, m.y)) {
            ed.drag = .{ .moving_sel = .{ .orig = ed.doc.sel.?.normalized(), .start = ip } };
            return true;
        }
    }
    ed.selDirty();
    ed.doc.sel = .{ .x = ip.x, .y = ip.y, .w = 0, .h = 0 };
    ed.drag = .{ .selecting = ip };
    ed.drag_anchor = ip;
    return true;
}

fn clampImg(ed: *const Editor, p: Point) Point {
    return .{
        .x = std.math.clamp(p.x, 0, @as(i32, @intCast(ed.img.width))),
        .y = std.math.clamp(p.y, 0, @as(i32, @intCast(ed.img.height))),
    };
}

/// The frame follows the pointer at the chosen aspect ratio.
pub fn constrain(ed: *Editor) void {
    if (ed.tools.mode != .crop) return;
    const k = crop.ratio(ed.tools.aspect) orelse return;
    const r = switch (ed.drag) {
        .selecting => crop.fromCorner(ed.drag_anchor, clampImg(ed, ed.imgAt(ed.mouse)), k),
        .resizing_sel => |rs| crop.constrainResize(rs.orig, rs.handle, ed.doc.sel.?, k),
        else => return,
    };
    ed.selDirty();
    ed.doc.sel = Rect.intersect(r, ed.doc.imageRect()) orelse r;
    ed.selDirty();
}

/// Crop the picture to the frame: a marked, undoable change.
pub fn apply(ed: *Editor) !void {
    ed.tools.mode = .none;
    ed.needs_render = true;
    const sel = ed.doc.sel orelse return;
    const r = Rect.intersect(sel.normalized(), ed.doc.imageRect()) orelse return;
    if (r.eql(ed.doc.imageRect()) or r.w < 2 or r.h < 2) return;
    try ed.settle();
    const st = &ed.tools.crops;
    const after = try st.adopt(ed.alloc, try crop.cropImage(ed.alloc, ed.img, r));
    const mark = st.next_mark;
    st.next_mark += 1;
    try st.entries.append(ed.alloc, .{ .mark = mark, .rect = r, .before = ed.img, .after = after });
    try ed.doc.checkpointMarked(mark);
    crop.moveShapes(ed.doc.shapes.items, r);
    ed.doc.sel = .{ .x = 0, .y = 0, .w = @intCast(after.width), .h = @intCast(after.height) };
    try ed.replaceImage(after);
    std.log.info("crop: {d}x{d} at {d},{d}", .{ r.w, r.h, r.x, r.y });
}

/// After an undo or redo: a crop it crossed swaps the picture back.
pub fn afterHistory(ed: *Editor, undone: bool) !void {
    const mark = ed.doc.last_mark;
    ed.doc.last_mark = 0;
    if (mark == 0) return;
    const e = ed.tools.crops.find(mark) orelse return;
    const img = if (undone) e.before else e.after;
    ed.doc.sel = if (undone) e.rect else .{ .x = 0, .y = 0, .w = @intCast(img.width), .h = @intCast(img.height) };
    try ed.replaceImage(img);
}

pub fn overlay(ed: *const Editor) ?Rect {
    if (ed.tools.mode != .crop) return null;
    return (ed.selBuf() orelse return null).expand(ed.handleRadius() + ed.sc(4));
}

/// The frame's thirds and its eight handles: L-shaped corners and short
/// bars mid-edge, just outside the frame, white on a dark halo so they
/// show on light and dark pictures alike.
pub fn draw(ed: *Editor, canvas: *Canvas) void {
    if (ed.tools.mode != .crop) return;
    const s = ed.selBuf() orelse return;
    drawThirds(canvas, s);
    const len: i32 = @min(ed.sc(18), @divTrunc(@min(s.w, s.h), 3));
    const t = @max(2, ed.sc(3));
    const halo = @max(1, ed.sc(1));
    // every halo first, so no halo covers a neighbouring arm
    for ([_]bool{ true, false }) |under| {
        for (0..8) |k| {
            const bars = handleBars(s, @intCast(k), len, t);
            for (bars.r[0..bars.n]) |b| {
                const r = if (under) b.expand(halo) else b;
                canvas.fillRect(r.x, r.y, r.w, r.h, if (under) ed.theme.handle_shadow else ed.theme.handle);
            }
        }
    }
}

/// Thirds, as a light line with a dark one beside it.
fn drawThirds(canvas: *Canvas, s: Rect) void {
    var i: i32 = 1;
    while (i < 3) : (i += 1) {
        const x = s.x + @divTrunc(s.w * i, 3);
        const y = s.y + @divTrunc(s.h * i, 3);
        canvas.fillRect(x + 1, s.y, 1, s.h, 0x33000000);
        canvas.fillRect(s.x, y + 1, s.w, 1, 0x33000000);
        canvas.fillRect(x, s.y, 1, s.h, 0x99FFFFFF);
        canvas.fillRect(s.x, y, s.w, 1, 0x99FFFFFF);
    }
}

const Bars = struct { r: [2]Rect, n: usize };

/// The bars of handle `k` (shapes.handlePoints order): two arms for a
/// corner, one bar for an edge, `t` thick and `len` long, outside `s`.
fn handleBars(s: Rect, k: u3, len: i32, t: i32) Bars {
    const p = shapes.handlePoints(s)[k];
    const left = p.x == s.x;
    const top = p.y == s.y;
    if (k % 2 == 0) {
        // a corner: a horizontal and a vertical arm meeting outside it
        const hx = if (left) p.x - t else p.x - len;
        const vy = if (top) p.y - t else p.y - len;
        return .{ .n = 2, .r = .{
            .{ .x = hx, .y = if (top) p.y - t else p.y, .w = len + t, .h = t },
            .{ .x = if (left) p.x - t else p.x, .y = vy, .w = t, .h = len + t },
        } };
    }
    const bar: Rect = if (k == 1 or k == 5)
        .{ .x = p.x - @divTrunc(len, 2), .y = if (k == 1) p.y - t else p.y, .w = len, .h = t }
    else
        .{ .x = if (k == 7) p.x - t else p.x, .y = p.y - @divTrunc(len, 2), .w = t, .h = len };
    return .{ .n = 1, .r = .{ bar, bar } };
}

test "crop handles sit just outside the frame" {
    const s: Rect = .{ .x = 100, .y = 100, .w = 200, .h = 100 };
    // the north-west corner: arms along the top and the left edge
    const nw = handleBars(s, 0, 18, 3);
    try std.testing.expectEqual(@as(usize, 2), nw.n);
    try std.testing.expect(nw.r[0].eql(.{ .x = 97, .y = 97, .w = 21, .h = 3 }));
    try std.testing.expect(nw.r[1].eql(.{ .x = 97, .y = 97, .w = 3, .h = 21 }));
    // the south-east corner ends where the frame does, plus the arm
    const se = handleBars(s, 4, 18, 3);
    try std.testing.expect(se.r[0].eql(.{ .x = 282, .y = 200, .w = 21, .h = 3 }));
    // the east edge: one bar, centred, outside
    const e = handleBars(s, 3, 18, 3);
    try std.testing.expectEqual(@as(usize, 1), e.n);
    try std.testing.expect(e.r[0].eql(.{ .x = 300, .y = 141, .w = 3, .h = 18 }));
}
