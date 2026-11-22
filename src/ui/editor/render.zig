//! Frames: pick the toolbar's pane, then for each due pane whose
//! surface is free repaint what changed since that back buffer was last
//! drawn (the dimmed view, the bright selection or its beautify frame,
//! the live stroke), the live shapes, and the chrome on top.

const std = @import("std");
const editor = @import("../editor.zig");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const textbox = @import("../textbox.zig");
const ui = @import("../editor_ui.zig");
const caches = @import("caches.zig");
const beauty_cache = @import("beauty_cache.zig");
const fade = @import("fade.zig");
const winpick = @import("winpick.zig");

const Editor = editor.Editor;
const Canvas = render.Canvas;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;

/// What composeRegionTo darkens outside the selection to.
/// Is some pane due for a frame and free to take one?
pub fn renderReady(ed: *Editor) bool {
    if (ed.needs_render) {
        for (ed.panes[0..ed.n_panes]) |*p| p.due = p.alive;
        ed.needs_render = false;
    }
    const surfs = ed.win.surfaceList();
    for (ed.panes[0..ed.n_panes], 0..) |p, i| {
        if (p.alive and p.due and i < surfs.len and !surfs[i].frame_pending) return true;
    }
    return false;
}

/// The pane that shows the toolbar: the pointer's when it shows part
/// of the selection, else the one showing most of it.
fn chooseTbPane(ed: *Editor) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    var best: u8 = ed.mouse_pane;
    var best_area: i64 = -1;
    for (ed.panes[0..ed.n_panes], 0..) |p, i| {
        if (!p.alive) continue;
        ed.pane_i = @intCast(i);
        const sb = ed.selBuf() orelse continue;
        const vis = Rect.intersect(sb, ed.screenRect()) orelse continue;
        var area = @as(i64, vis.w) * vis.h;
        if (i == ed.mouse_pane) area = std.math.maxInt(i64);
        if (area > best_area) {
            best_area = area;
            best = @intCast(i);
        }
    }
    if (best != ed.tb_pane) {
        ed.tb_pane = best;
        for (ed.panes[0..ed.n_panes]) |*p| p.due = p.alive;
    }
}

/// Render every due pane whose surface is free.
pub fn renderFrame(ed: *Editor) !void {
    _ = renderReady(ed);
    defer ed.pane_i = ed.mouse_pane;
    chooseTbPane(ed);
    ed.pane_i = ed.tb_pane;
    try ui.layoutToolbar(ed);
    if (caretRect(ed)) |cr| {
        ed.pane_i = ed.mouse_pane;
        ed.win.setTextInput(true, .{ .x = cr.x, .y = cr.y, .w = cr.w, .h = cr.h }) catch {};
    }
    const surfs = ed.win.surfaceList();
    for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
        if (!p.alive or !p.due or p.viewc.len == 0 or i >= surfs.len or surfs[i].frame_pending) continue;
        ed.pane_i = @intCast(i);
        try renderPane(ed, @intCast(i));
        p.due = false;
    }
}

/// Draw pane `idx` (the current one) into its surface's back buffer and
/// present it.
pub fn renderPane(ed: *Editor, idx: u8) !void {
    try beauty_cache.ensure(ed);
    ed.pn().overlays.len = 0;
    ui.collectOverlays(ed, &ed.pn().overlays);
    for (&ed.pn().pending) |*p| {
        p.addAll(&ed.pn().content_dirty);
        p.addAll(&ed.pn().overlays);
    }
    ed.pn().content_dirty.len = 0;

    const px = try ed.win.backBufferOf(idx);
    const bi = ed.win.surfaceList()[idx].cur_buf;
    const p = &ed.pn().pending[bi];
    // the fade-in blends whole frames: nothing of the last one is reusable
    const entering = fade.enterLevel(ed);
    if (entering != null) p.add(ed.screenRect());
    // past ~half the screen one full pass beats many partial ones
    if (p.area() * 2 > @as(i64, ed.pn().width) * ed.pn().height) {
        composeRegion(ed, px, ed.screenRect());
    } else {
        for (p.slice()) |r| composeRegion(ed, px, r);
    }
    var canvas = Canvas.init(px, ed.pn().width, ed.pn().height);
    canvas.mask = ed.pn().stroke_mask;
    drawLiveShapes(ed, &canvas);
    ui.drawChrome(ed, &canvas);
    if (entering) |k| fade.blendIn(ed, px, k);
    p.len = 0;
    p.addAll(&ed.pn().overlays);
    ed.pn().last_frame = px;
    try ed.win.presentSurface(idx);
}

/// Paint the background for buffer rect `region`: the dimmed view, the
/// bright selection (or its beautify frame) and the live stroke.
fn composeRegion(ed: *Editor, px: []u32, region: Rect) void {
    composeRegionTo(ed, px, ed.pn().width, .{ .x = 0, .y = 0 }, region);
}

/// composeRegion into `dst`, a buffer `stride` pixels wide whose first
/// pixel is buffer point `origin` (the backdrop of floating chrome).
pub fn composeRegionTo(ed: *Editor, dst: []u32, stride: usize, origin: Point, region: Rect) void {
    const r = Rect.intersect(region, ed.screenRect()) orelse return;
    // a window lit for a click, else the selection (or its frame)
    const lit = winpick.lit(ed);
    const sel = ed.selBuf();
    const beauty = lit == null and ed.beautify.enabled and ed.pn().bcache_valid and sel != null;
    const bright: ?Rect = lit orelse if (beauty) ed.pn().bcache_rect else sel;
    var y = r.y;
    while (y < r.bottom()) : (y += 1) composeRow(ed, dst, stride, origin, r, y, bright, beauty);
    // the freehand stroke being drawn
    const s = &(ed.cur orelse return);
    if (s.tool != .pen and s.tool != .highlight) return;
    const lr = Rect.intersect(r, ed.pn().live_bbox) orelse return;
    composeLiveStroke(ed, dst, stride, origin, lr, s, bright);
}

/// Row `y` of `r`: dimmed outside `bright`, inside it the view (or the
/// beautify cache when `beauty`).
inline fn composeRow(ed: *Editor, dst: []u32, stride: usize, origin: Point, r: Rect, y: i32, bright: ?Rect, beauty: bool) void {
    const w: usize = ed.pn().width;
    const row = @as(usize, @intCast(y)) * w;
    // dst[drow + x] is buffer pixel (x, y)
    const drow = @as(usize, @intCast(y - origin.y)) * stride -% @as(usize, @intCast(origin.x));
    var x0 = r.right();
    var x1 = r.right();
    if (bright) |b| {
        if (y >= b.y and y < b.bottom()) {
            x0 = std.math.clamp(b.x, r.x, r.right());
            x1 = std.math.clamp(b.right(), r.x, r.right());
        }
    }
    if (x1 <= x0) {
        x0 = r.right();
        x1 = r.right();
    }
    const a: usize = @intCast(r.x);
    const sa: usize = @intCast(x0);
    const sb: usize = @intCast(x1);
    const e: usize = @intCast(r.right());
    if (sa > a) @memcpy(dst[drow +% a .. drow +% sa], ed.pn().viewc_dim[row + a .. row + sa]);
    if (sb > sa) {
        if (beauty) {
            const b = ed.pn().bcache_rect;
            const bw: usize = @intCast(b.w);
            const by: usize = @intCast(y - b.y);
            const bx: usize = @intCast(x0 - b.x);
            @memcpy(dst[drow +% sa .. drow +% sb], ed.pn().bcache[by * bw + bx ..][0 .. sb - sa]);
        } else {
            @memcpy(dst[drow +% sa .. drow +% sb], ed.pn().viewc[row + sa .. row + sb]);
        }
    }
    if (e > sb) @memcpy(dst[drow +% sb .. drow +% e], ed.pn().viewc_dim[row + sb .. row + e]);
}

/// Blend the live freehand stroke `s` over `lr`, dimmed outside `bright`.
fn composeLiveStroke(ed: *Editor, dst: []u32, stride: usize, origin: Point, lr: Rect, s: *const Shape, bright: ?Rect) void {
    const w: usize = ed.pn().width;
    const col = if (s.tool == .highlight) (s.color & 0x00FFFFFF) | 0x66000000 else s.color;
    const ca: u32 = col >> 24;
    var dimmed: [1]u32 = undefined;
    caches.dimRow(&.{col}, &dimmed, ed.dim_keep);
    var y = lr.y;
    while (y < lr.bottom()) : (y += 1) {
        var x = lr.x;
        while (x < lr.right()) : (x += 1) {
            const idx = @as(usize, @intCast(y)) * w + @as(usize, @intCast(x));
            const cv: u32 = ed.pn().live_cov[idx];
            if (cv == 0) continue;
            const inside = if (bright) |b| b.contains(x, y) else false;
            const c = if (inside) col else dimmed[0];
            const a = (ca * cv + 127) / 255;
            const di = @as(usize, @intCast(y - origin.y)) * stride + @as(usize, @intCast(x - origin.x));
            dst[di] = Canvas.blendPixel(dst[di], (c & 0x00FFFFFF) | (a << 24));
        }
    }
}

/// The text caret on screen while editing text.
pub fn caretRect(ed: *const Editor) ?Rect {
    const t = ed.text orelse return null;
    const s = &ed.doc.shapes.items[t.idx];
    const fs = s.fontPx();
    const lh = text_mod.height(fs);
    var buf: [8192]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&buf, ed.alloc);
    var lay = textbox.Layout.init(bfa.allocator(), s.str.items, fs, s.box_w) catch return null;
    defer lay.deinit(bfa.allocator());
    const c = lay.caretPoint(s.str.items, .{ .off = t.te.caret, .upstream = t.upstream });
    const p = Point{ .x = s.p0.x + c.x, .y = s.p0.y + c.y };
    const b = ed.pn().view.toBuf(p);
    return .{ .x = b.x, .y = b.y, .w = @max(1, ed.sc(2)), .h = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(lh)) * ed.pn().view.scale)))) };
}

/// Shapes not in the layer: the one being drawn and the lifted one.
/// The export is cut to the selection, so whatever of them lies outside
/// it is shown dimmed, like committed shapes there: what is bright is
/// exactly what will be copied or saved.
fn drawLiveShapes(ed: *Editor, canvas: *Canvas) void {
    const sel = ed.selBuf() orelse return drawLiveShapesRaw(ed, canvas);
    const lb = Rect.intersect(liveBounds(ed), ed.screenRect()) orelse return;
    if (Rect.intersect(lb, sel)) |in| if (in.x == lb.x and in.y == lb.y and in.w == lb.w and in.h == lb.h)
        return drawLiveShapesRaw(ed, canvas);
    // remember the pixels outside the selection, draw, then darken the
    // ones the shapes changed
    const w: usize = @intCast(lb.w);
    const before = ed.alloc.alloc(u32, w * @as(usize, @intCast(lb.h))) catch return drawLiveShapesRaw(ed, canvas);
    defer ed.alloc.free(before);
    const cw: usize = @intCast(canvas.w);
    for (0..@intCast(lb.h)) |row| {
        const off = (@as(usize, @intCast(lb.y)) + row) * cw + @as(usize, @intCast(lb.x));
        @memcpy(before[row * w ..][0..w], canvas.px[off..][0..w]);
    }
    drawLiveShapesRaw(ed, canvas);
    for (0..@intCast(lb.h)) |row| {
        const y = lb.y + @as(i32, @intCast(row));
        const off = @as(usize, @intCast(y)) * cw + @as(usize, @intCast(lb.x));
        for (canvas.px[off..][0..w], before[row * w ..][0..w], 0..) |*px, old, col| {
            if (px.* == old) continue;
            if (sel.contains(lb.x + @as(i32, @intCast(col)), y)) continue;
            caches.dimRow(&.{px.*}, px[0..1], ed.dim_keep);
        }
    }
}

fn drawLiveShapesRaw(ed: *Editor, canvas: *Canvas) void {
    const xf = ed.pn().view.xform();
    if (ed.cur) |*s| {
        if (s.tool != .pen and s.tool != .highlight) shapes_mod.drawShape(canvas, ed.alloc, s, xf, null);
    }
    if (ed.lifted) |i| {
        const cursor: ?shapes_mod.TextCursor = if (ed.text) |t| .{ .caret = t.te.caret, .sel = t.te.selection(), .upstream = t.upstream } else null;
        shapes_mod.drawShape(canvas, ed.alloc, &ed.doc.shapes.items[i], xf, cursor);
    }
}

/// Screen footprint of the live shapes, for damage tracking.
pub fn liveBounds(ed: *const Editor) Rect {
    var r = Rect.empty;
    if (ed.cur) |*s| {
        if (s.tool != .pen and s.tool != .highlight) r = Rect.unite(r, s.bounds());
    }
    if (ed.lifted) |i| r = Rect.unite(r, ed.doc.shapes.items[i].bounds().expand(4));
    if (r.isEmpty()) return r;
    return ed.pn().view.rectToBufOuter(r).expand(2);
}
