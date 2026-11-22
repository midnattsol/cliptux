//! The layer and the per-pane view caches: sizing a pane when its
//! surface (re)appears, recomposing image rects of the layer after an
//! edit, resampling them into every pane's view, and dirty tracking.

const std = @import("std");
const editor = @import("../editor.zig");
const capture = @import("../../app/capture.zig");
const shapes_mod = @import("../shapes.zig");
const doc_mod = @import("../doc.zig");
const view_mod = @import("../view.zig");
const tall_view = @import("../tall_view.zig");
const png = @import("../../gfx/png.zig");
const tools = @import("../tools/mod.zig");
const hit = @import("hit.zig");

const Editor = editor.Editor;
const Pane = editor.Pane;
const Rect = shapes_mod.Rect;
const View = view_mod.View;

/// The view for surface `idx`: its monitor's pixel rect of the image
/// when there is one surface per monitor, else the image fit to it.
pub fn viewFor(ed: *Editor, idx: u8) View {
    const surfs = ed.win.surfaceList();
    if (ed.monitors.len > 1 and surfs.len > 1 and idx < surfs.len) {
        const sf = surfs[idx];
        if (monitorOf(ed, idx)) |m| return view_mod.monitorView(.{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) }, sf.width, sf.height);
    }
    // a tall image (a scrolling capture) fits the width and scrolls
    if (tall_view.isTall(ed.img.width, ed.img.height, ed.screenRect()))
        return tall_view.view(ed.img.width, ed.img.height, ed.screenRect(), ed.tall_scroll);
    return View.fit(ed.img.width, ed.img.height, ed.screenRect(), 1.0);
}

/// The captured monitor surface `idx` shows: the one at its logical
/// position and size, else the one at the same index.
fn monitorOf(ed: *Editor, idx: u8) ?capture.Monitor {
    const sf = ed.win.surfaceList()[idx];
    var mon: ?capture.Monitor = null;
    for (ed.monitors) |m| {
        const l = m.logical orelse continue;
        if (l.x == sf.x and l.y == sf.y and l.w == sf.out_w and l.h == sf.out_h) mon = m;
    }
    if (mon == null and idx < ed.monitors.len) mon = ed.monitors[idx];
    return mon;
}

/// Surface `idx` is now `w` x `h` buffer pixels (0 x 0: it went away).
pub fn onResize(ed: *Editor, idx: u8, w: u32, h: u32) !void {
    if (idx >= editor.max_panes) return;
    if (w == 0 or h == 0) return dropPane(ed, idx);
    if (!ed.ui_init) {
        ed.ui_init = true;
        tools.start(ed);
        ed.thickness = std.math.clamp(ed.cfg_thickness, 1, 32);
    }
    ed.n_panes = @max(ed.n_panes, idx + 1);
    const saved = ed.pane_i;
    defer ed.pane_i = if (ed.panes[saved].alive) saved else idx;
    ed.pane_i = idx;
    const p = &ed.panes[idx];
    try allocPane(ed, p, idx, w, h);
    if (ed.layer.len == 0) {
        ed.layer = try ed.alloc.alloc(u32, ed.img.pixels.len);
        try doc_mod.composeRegion(ed.alloc, ed.layer, ed.img.pixels, ed.img.width, ed.img.height, ed.doc.shapes.items, ed.lifted, ed.doc.imageRect());
    }
    if (idx == 0) applyPresetSelection(ed);
    refreshView(ed, ed.screenRect());
    for (&p.pending) |*q| {
        q.len = 0;
        q.add(ed.screenRect());
    }
    ed.needs_render = true;
}

/// The surface of pane `idx` went away (output unplugged): move the
/// pointer, toolbar and current pane to one still alive.
fn dropPane(ed: *Editor, idx: u8) void {
    const p = &ed.panes[idx];
    p.release(ed.alloc);
    p.alive = false;
    for (ed.panes[0..ed.n_panes], 0..) |q, i| {
        if (!q.alive) continue;
        if (!ed.panes[ed.mouse_pane].alive) ed.mouse_pane = @intCast(i);
        if (!ed.panes[ed.tb_pane].alive) ed.tb_pane = @intCast(i);
        if (!ed.panes[ed.pane_i].alive) ed.pane_i = @intCast(i);
    }
    ed.needs_render = true;
}

/// Start pane `p` over at the surface's size, with fresh caches.
fn allocPane(ed: *Editor, p: *Pane, idx: u8, w: u32, h: u32) !void {
    const sf = ed.win.surfaceList()[idx];
    p.release(ed.alloc);
    p.* = .{ .alive = true, .width = w, .height = h, .scale120 = sf.scale120 };
    const n: usize = @as(usize, w) * h;
    p.view = viewFor(ed, idx);
    p.viewc = try ed.alloc.alloc(u32, n);
    p.viewc_dim = try ed.alloc.alloc(u32, n);
    p.stroke_mask = try ed.alloc.alloc(u8, n);
    @memset(p.stroke_mask, 0);
    p.live_cov = try ed.alloc.alloc(u8, n);
    @memset(p.live_cov, 0);
}

/// Dev: the selection presetSelection asked for, once the first pane
/// can map window pixels to the image.
fn applyPresetSelection(ed: *Editor) void {
    const v = ed.preset_sel orelse return;
    ed.preset_sel = null;
    const a = hit.clampImg(ed, ed.imgAt(.{ .x = v[0], .y = v[1] }));
    const b = hit.clampImg(ed, ed.imgAt(.{ .x = v[0] + v[2], .y = v[1] + v[3] }));
    const r = Rect.fromCorners(a, b);
    if (!r.isEmpty()) ed.doc.sel = r;
}

/// Scroll a tall image by wheel notches: lay every pane out again.
pub fn scrollTall(ed: *Editor, notches: i32) !void {
    const before = ed.tall_scroll;
    ed.tall_scroll = tall_view.clampScroll(ed.img.width, ed.img.height, ed.screenRect(), ed.tall_scroll + notches * ed.sc(80));
    if (ed.tall_scroll == before) return;
    for (ed.panes[0..ed.n_panes], 0..) |p, i| if (p.alive) try onResize(ed, @intCast(i), p.width, p.height);
}

/// Re-render `b` (buffer pixels) of the view caches from the layer.
pub fn refreshView(ed: *Editor, b: Rect) void {
    const r = Rect.intersect(b, ed.screenRect()) orelse return;
    view_mod.resample(ed.layer, ed.img.width, ed.img.height, ed.pn().view, ed.pn().viewc, ed.pn().width, ed.pn().height, r);
    const keep = ed.dim_keep;
    const w: usize = ed.pn().width;
    var y: usize = @intCast(r.y);
    while (y < @as(usize, @intCast(r.bottom()))) : (y += 1) {
        const off = y * w + @as(usize, @intCast(r.x));
        dimRow(ed.pn().viewc[off..][0..@intCast(r.w)], ed.pn().viewc_dim[off..][0..@intCast(r.w)], keep);
    }
    ed.pn().content_dirty.add(r);
    ed.pn().gen +%= 1;
    if (ed.selBuf()) |s| {
        if (Rect.intersect(s, r) != null) ed.pn().bcache_valid = false;
    }
}

/// Re-render image rect `r` on every pane.
fn refreshAll(ed: *Editor, r: Rect) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
        if (!p.alive or p.viewc.len == 0) continue;
        ed.pane_i = @intCast(i);
        refreshView(ed, p.view.rectToBufOuter(r));
    }
    ed.needs_render = true;
}

/// Invalidate every pane's beautify cache and backdrops; with `whole`,
/// mark the whole screen dirty too.
pub fn dirtyAll(ed: *Editor, comptime whole: bool) void {
    for (ed.panes[0..ed.n_panes]) |*p| {
        if (!p.alive) continue;
        if (whole) p.content_dirty.add(.{ .x = 0, .y = 0, .w = @intCast(p.width), .h = @intCast(p.height) });
        p.bcache_valid = false;
        p.gen +%= 1;
    }
    ed.needs_render = true;
}

/// Recompose image rect `r` of the layer and everything derived.
pub fn recompose(ed: *Editor, r: Rect) !void {
    if (ed.layer.len == 0) return;
    var margin: i32 = 0;
    for (ed.doc.shapes.items) |*s| margin += s.readMargin();
    const reg = r.expand(margin);
    try doc_mod.composeRegion(ed.alloc, ed.layer, ed.img.pixels, ed.img.width, ed.img.height, ed.doc.shapes.items, ed.lifted, reg);
    refreshAll(ed, reg);
}

/// Shape `i` changed and is the topmost one: paint just it.
pub fn paintTop(ed: *Editor, i: usize) !void {
    if (i + 1 != ed.doc.shapes.items.len or ed.lifted != null or ed.layer.len == 0) {
        return recompose(ed, ed.doc.shapes.items[i].bounds());
    }
    const s = &ed.doc.shapes.items[i];
    try doc_mod.paintOnTop(ed.alloc, ed.layer, ed.img.width, ed.img.height, s);
    refreshAll(ed, s.bounds());
}

pub fn recomposeAll(ed: *Editor) !void {
    try recompose(ed, ed.doc.imageRect());
}

/// `dst` = `src` darkened to `keep`/256, opaque.
pub fn dimRow(src: []const u32, dst: []u32, keep: u32) void {
    @setRuntimeSafety(false);
    for (src, dst) |p, *d| {
        const rb = ((p & 0x00FF00FF) * keep >> 8) & 0x00FF00FF;
        const g = ((p & 0x0000FF00) * keep >> 8) & 0x0000FF00;
        d.* = 0xFF000000 | rb | g;
    }
}

/// Mark the on-screen selection area (or its beautify frame) dirty.
pub fn selDirty(ed: *Editor) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
        if (!p.alive) continue;
        ed.pane_i = @intCast(i);
        if (ed.selBuf()) |sb| p.content_dirty.add(frameRect(ed, sb).expand(2));
        p.bcache_valid = false;
        p.gen +%= 1;
    }
    ed.needs_render = true;
}

/// The selection plus its beautify padding, on screen.
pub fn frameRect(ed: *const Editor, s: Rect) Rect {
    if (!ed.beautify.enabled) return s;
    const sel = ed.doc.sel.?.normalized();
    const g = ed.beautify.geometry(@intCast(@max(1, sel.w)), @intCast(@max(1, sel.h)));
    const pad: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(g.pad)) * ed.pn().view.scale));
    return s.expand(pad);
}

/// Show `img` instead (a crop, an opened file): the layer, every
/// view and its caches start over; the shapes stay as they are.
pub fn replaceImage(ed: *Editor, img: *const png.Image) !void {
    ed.img = img;
    ed.doc.width = img.width;
    ed.doc.height = img.height;
    ed.monitors = &.{};
    ed.selected = null;
    ed.lifted = null;
    ed.alloc.free(ed.layer);
    ed.layer = &.{};
    ed.layer = try ed.alloc.alloc(u32, img.pixels.len);
    try doc_mod.composeRegion(ed.alloc, ed.layer, img.pixels, img.width, img.height, ed.doc.shapes.items, null, ed.doc.imageRect());
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
        if (!p.alive or p.viewc.len == 0) continue;
        ed.pane_i = @intCast(i);
        p.view = viewFor(ed, @intCast(i));
        p.bcache_valid = false;
        for (&p.backdrops) |*b| b.hash = 0;
        refreshView(ed, ed.screenRect());
        for (&p.pending) |*q| q.add(ed.screenRect());
    }
    ed.needs_render = true;
}
