//! Drawing a new shape with the active tool: start it at the press,
//! shape it as the pointer moves (Shift constrains, Alt draws from the
//! centre, Space moves it), commit it on release. A freehand stroke is
//! rasterized into each pane's live coverage mask as it grows.

const std = @import("std");
const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const tools = @import("../tools/mod.zig");
const caches = @import("caches.zig");

const Editor = editor.Editor;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;

/// Start a shape of the active tool at image point `ip`.
pub fn start(ed: *Editor, ip: Point) !void {
    const at = tools.startPoint(ed, ed.tool, ip);
    var s = Shape{
        .tool = ed.tool,
        .color = ed.color(),
        .thickness = ed.imgThickness(),
        .p0 = at,
        .p1 = at,
        .filled = (ed.styles.get(ed.tool) & 1) != 0,
        .rounded = (ed.styles.get(ed.tool) & 2) != 0,
    };
    tools.initShape(ed, &s);
    errdefer s.deinit(ed.alloc);
    if (ed.tool == .pen or ed.tool == .highlight) {
        try s.points.append(ed.alloc, ip);
        liveSegment(ed, &s, ip, ip);
    }
    ed.cur = s;
    ed.drag = .drawing;
    ed.drag_anchor = at;
    ed.space.last = null;
    ed.needs_render = true;
}

/// The pointer moved to `ip` while drawing.
pub fn update(ed: *Editor, ip: Point) !void {
    const s = &(ed.cur orelse return);
    if (tools.updateDrawing(ed, s, ip)) return;
    switch (s.tool) {
        .pen, .highlight => try extendStroke(ed, s, ip),
        .line, .arrow => {
            spaceMove(ed, ip);
            const q = if (ed.mod_shift) shapes_mod.snapAngle(ed.drag_anchor, ip) else ip;
            const a = ed.drag_anchor;
            s.p0 = if (ed.mod_alt) .{ .x = 2 * a.x - q.x, .y = 2 * a.y - q.y } else a;
            s.p1 = q;
        },
        else => {
            spaceMove(ed, ip);
            const cs = shapes_mod.dragCorners(ed.drag_anchor, ip, ed.mod_shift, ed.mod_alt);
            s.p0 = cs[0];
            s.p1 = cs[1];
        },
    }
    ed.needs_render = true;
}

/// A freehand stroke gains a point once the pointer moved 2 buffer pixels.
fn extendStroke(ed: *Editor, s: *Shape, ip: Point) !void {
    const last = s.points.items[s.points.items.len - 1];
    const dx: f64 = @floatFromInt(ip.x - last.x);
    const dy: f64 = @floatFromInt(ip.y - last.y);
    const min_step = ed.pn().view.lenToImg(2.0);
    if (dx * dx + dy * dy >= min_step * min_step) {
        try s.points.append(ed.alloc, ip);
        liveSegment(ed, s, last, ip);
    }
}

/// With Space held, the pointer moves the whole box being dragged.
pub fn spaceMove(ed: *Editor, ip: Point) void {
    if (!ed.space.held) {
        ed.space.last = null;
        return;
    }
    if (ed.space.last) |last| {
        ed.drag_anchor.x += ip.x - last.x;
        ed.drag_anchor.y += ip.y - last.y;
    }
    ed.space.last = ip;
}

/// Add the shape being drawn to the document, unless it is too small to
/// be meant.
pub fn commit(ed: *Editor) !void {
    var s = ed.cur orelse return;
    ed.cur = null;
    clearLive(ed);
    if (tooSmall(ed, &s)) {
        s.deinit(ed.alloc);
        ed.needs_render = true;
        return;
    }
    ed.doc.checkpoint() catch |e| {
        s.deinit(ed.alloc);
        return e;
    };
    const i = try ed.doc.add(s);
    tools.committed(&ed.doc.shapes.items[i]);
    try caches.paintTop(ed, i);
}

fn tooSmall(ed: *Editor, s: *const Shape) bool {
    const f = s.frame();
    const min = ed.pn().view.lenToImg(3.0);
    return switch (s.tool) {
        .pen, .highlight => false,
        .line, .arrow, .ruler => @abs(s.p1.x - s.p0.x) < @as(i32, @intFromFloat(min)) + 1 and @abs(s.p1.y - s.p0.y) < @as(i32, @intFromFloat(min)) + 1,
        else => @as(f64, @floatFromInt(f.w)) < min or @as(f64, @floatFromInt(f.h)) < min,
    };
}

/// Drop the shape being drawn.
pub fn discard(ed: *Editor) void {
    if (ed.cur) |*s| s.deinit(ed.alloc);
    ed.cur = null;
    clearLive(ed);
}

/// Rasterize one new freehand segment into the live coverage mask: the
/// stroke being drawn costs O(segment) per motion, not O(stroke).
fn liveSegment(ed: *Editor, s: *const Shape, a_img: Point, b_img: Point) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |p, i| {
        if (!p.alive) continue;
        ed.pane_i = @intCast(i);
        liveSegmentPane(ed, s, a_img, b_img);
    }
}

fn liveSegmentPane(ed: *Editor, s: *const Shape, a_img: Point, b_img: Point) void {
    if (ed.pn().live_cov.len == 0) return;
    const xf = ed.pn().view.xform();
    const a = xf.pt(a_img);
    const b = xf.pt(b_img);
    var half = @max(0.5, @as(f64, @floatFromInt(s.thickness)) * ed.pn().view.scale / 2.0);
    if (s.tool == .highlight) half *= 3.0;
    const pad: i32 = @as(i32, @intFromFloat(@ceil(half))) + 2;
    const bb = Rect.intersect(Rect.fromCorners(a, b).expand(pad), ed.screenRect()) orelse return;
    const w: usize = ed.pn().width;
    const ax: f64 = @floatFromInt(a.x);
    const ay: f64 = @floatFromInt(a.y);
    const abx = @as(f64, @floatFromInt(b.x)) - ax;
    const aby = @as(f64, @floatFromInt(b.y)) - ay;
    const ab2 = abx * abx + aby * aby;
    var y = bb.y;
    while (y < bb.bottom()) : (y += 1) {
        var x = bb.x;
        while (x < bb.right()) : (x += 1) {
            const px = @as(f64, @floatFromInt(x)) + 0.5 - ax;
            const py = @as(f64, @floatFromInt(y)) + 0.5 - ay;
            const t = if (ab2 == 0) 0.0 else std.math.clamp((px * abx + py * aby) / ab2, 0.0, 1.0);
            const dx = px - abx * t;
            const dy = py - aby * t;
            const cov = std.math.clamp(half - @sqrt(dx * dx + dy * dy) + 0.5, 0.0, 1.0);
            if (cov <= 0.003) continue;
            const cv: u8 = @intFromFloat(cov * 255.0);
            const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            if (cv > ed.pn().live_cov[idx]) ed.pn().live_cov[idx] = cv;
        }
    }
    ed.pn().live_bbox = Rect.unite(ed.pn().live_bbox, bb);
    ed.pn().content_dirty.add(bb);
}

fn clearLive(ed: *Editor) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |p, i| {
        if (!p.alive) continue;
        ed.pane_i = @intCast(i);
        clearLivePane(ed);
    }
}

fn clearLivePane(ed: *Editor) void {
    if (ed.pn().live_bbox.isEmpty()) return;
    const w: usize = ed.pn().width;
    const r = ed.pn().live_bbox;
    var y: usize = @intCast(r.y);
    while (y < @as(usize, @intCast(r.bottom()))) : (y += 1) {
        @memset(ed.pn().live_cov[y * w + @as(usize, @intCast(r.x)) ..][0..@intCast(r.w)], 0);
    }
    ed.pn().content_dirty.add(r);
    ed.pn().live_bbox = Rect.empty;
}
