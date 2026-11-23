//! The magnifier: a lens (ui/lens.zig) beside the point being aimed at
//! while an area is chosen, and for the colour picker. When it shows
//! follows the `loupe` setting: while Ctrl is held (loupe_hold.zig),
//! always, or never. On an edge (creating the selection, dragging a
//! handle, after an arrow key moved one) it looks at that edge, the
//! selection drawn inside it to the pixel. Its one label, the pixel's
//! colour (loupe_label.zig), shows while Alt is held, in the colour
//! picker and after C; the label brings the lens with it. It fades and
//! grows in from the corner nearest the point, and fades out where it
//! was. The wheel (and - =) zoom it, C copies the colour
//! (editor/loupe_input.zig, which also feeds it Ctrl).

const std = @import("std");
const render = @import("../../gfx/render.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const config = @import("../../app/config.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const lens_mod = @import("../lens.zig");
const material = @import("material.zig");
const selection = @import("selection.zig");
const label = @import("loupe_label.zig");
const place = @import("loupe_place.zig");
const hold_mod = @import("loupe_hold.zig");
const hint = @import("loupe_hint.zig");
const hit = @import("hit.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

/// the lens's side and corner radius, logical px
const lens_side = 110;
const lens_radius = 11;
/// what it starts from as it grows in
const grow_from = 0.92;
/// how long "Copied" stays in the label
const copied_ms = 1400;
/// from this zoom up a faint grid parts the pixels
const grid_zoom = 12;

pub const State = struct {
    /// when it shows, and its zoom (one of config.loupe_zooms)
    mode: config.Loupe = .hold,
    zoom: u8 = config.loupe_zoom_default,
    /// 0 gone .. 1 shown, eased
    shown: motion.Tween = .{ .dur_ms = theme.motion_fast },
    /// Ctrl held: "while holding Ctrl" shows it
    hold: hold_mod.Hold = .{},
    /// it is wanted and Ctrl will have been held long enough then
    /// (monotonic ms; 0: not waiting for Ctrl)
    hold_due_ms: i64 = 0,
    /// what it looks at while wanted (it fades out there), on which pane
    look: Look = .{},
    pane: u8 = 0,
    /// the selection's handle an arrow key last moved (a corner when it
    /// moved whole): it looks at that edge until the pointer moves
    nudge: ?u3 = null,
    /// the label says "Copied" until then (monotonic ms), while it looks
    /// at that image pixel
    copied_until_ms: i64 = 0,
    copied_at: Point = .{ .x = 0, .y = 0 },
    /// the one-time "Hold Ctrl to zoom" hint
    hint: hint.Hint = .{},
};

/// What the lens looks at.
pub const Look = struct {
    /// the image pixel in its middle
    at: Point = .{ .x = 0, .y = 0 },
    /// at the selection's edge (a corner is the pixel's top left), the
    /// selection drawn; else the pixel under the pointer, framed
    edge: bool = false,
};

/// Wanted now for the pointer (on its pane, the current one): the colour
/// picker always; else unless the setting is never, before a selection
/// or while one is dragged, never over the help, a tool's mode or the
/// chrome. Its keys apply then.
pub fn wanted(ed: *const Editor) bool {
    if (ed.help_open or !ed.screenRect().contains(ed.mouse.x, ed.mouse.y)) return false;
    if (ed.tools.mode == .eyedropper) return true;
    if (ed.loupe.mode == .never or ed.tools.mode != .none) return false;
    if (ed.drag == .none and hit.onChrome(ed, ed.mouse)) return false;
    return switch (ed.drag) {
        .selecting, .resizing_sel => true,
        .none => ed.doc.sel == null,
        else => false,
    };
}

/// An arrow key moved the selection since the pointer last did: it
/// looks at that edge.
fn nudging(ed: *const Editor) bool {
    return ed.loupe.nudge != null and ed.loupe.mode != .never and ed.doc.sel != null and
        ed.tools.mode == .none and !ed.help_open;
}

/// Wanted, or still showing (fading out): pointer moves need frames.
pub fn active(ed: *const Editor) bool {
    return wanted(ed) or ed.loupe.shown.target > 0 or busy(ed);
}

/// The capture screen's magnifier is up (not the colour picker's): its
/// keys apply.
pub fn capturing(ed: *const Editor) bool {
    return ed.tools.mode == .none and wanted(ed);
}

/// Shown when wanted: the colour picker's, the label's and the setting
/// always's right away; while holding Ctrl once it is held long enough.
fn visible(ed: *const Editor, now: i64) bool {
    if (ed.tools.mode == .eyedropper or labelled(ed)) return true;
    return switch (ed.loupe.mode) {
        .hold => ed.loupe.hold.shown(now),
        .always => true,
        .never => false,
    };
}

/// Ctrl held shows it: the wheel and - = zoom it then, Ctrl down.
pub fn held(ed: *const Editor) bool {
    return ed.loupe.mode == .hold and ed.loupe.hold.shown(motion.now());
}

/// The pointer moved or was pressed: it looks at the pointer (or the
/// drag) again, not at the edge an arrow key moved.
pub fn pointed(ed: *Editor) void {
    ed.loupe.nudge = null;
}

/// An arrow key moved the selection's handle `h` (a corner when it moved
/// as a whole): it looks at that edge.
pub fn nudged(ed: *Editor, h: u3) void {
    ed.loupe.nudge = h;
    ed.needs_render = true;
}

/// Once a frame: follow what it looks at while wanted, fade toward shown
/// or gone, end the "Copied" note and the hint when due.
pub fn sync(ed: *Editor) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    ed.pane_i = ed.mouse_pane;
    const st = &ed.loupe;
    const now = motion.now();
    const nudge = nudging(ed);
    const want = nudge or wanted(ed);
    if (want) {
        st.look = look(ed, nudge);
        st.pane = if (nudge) paneShowing(ed, st.look.at) else ed.mouse_pane;
    }
    const show = want and visible(ed, now);
    st.shown.to(if (show) 1 else 0, now);
    st.hold_due_ms = if (want and !show and st.mode == .hold) st.hold.dueMs(now) else 0;
    if (st.copied_until_ms != 0 and (now >= st.copied_until_ms or !std.meta.eql(st.look.at, st.copied_at))) st.copied_until_ms = 0;
    hint.sync(ed, now);
}

/// What it looks at now: the edge being nudged or dragged (a new
/// selection's moving corner), else the pixel under the pointer.
fn look(ed: *const Editor, nudge: bool) Look {
    const q = clampImg(ed, ed.imgAt(ed.mouse));
    if (nudge) {
        const s = ed.doc.sel.?.normalized();
        return .{ .at = shapes_mod.handleFocus(s, ed.loupe.nudge.?, q), .edge = true };
    }
    return switch (ed.drag) {
        .resizing_sel => |rs| .{ .at = shapes_mod.handleFocus(ed.doc.sel.?, rs.handle, q), .edge = true },
        .selecting => blk: {
            const s = ed.doc.sel.?;
            break :blk .{ .at = shapes_mod.handleFocus(s, shapes_mod.nearestCorner(s, q), q), .edge = true };
        },
        else => .{ .at = ed.pn().view.toImg(ed.mouse) },
    };
}

/// The pane showing image point `p`: the pointer's when it does.
fn paneShowing(ed: *const Editor, p: Point) u8 {
    var best = ed.mouse_pane;
    for (ed.panes[0..ed.n_panes], 0..) |pane, i| {
        if (!pane.alive) continue;
        const b = pane.view.toBuf(p);
        const r: Rect = .{ .x = 0, .y = 0, .w = @intCast(pane.width), .h = @intCast(pane.height) };
        if (r.contains(b.x, b.y) and (i == ed.mouse_pane or best == ed.mouse_pane)) best = @intCast(i);
    }
    return best;
}

/// The label (the colour) shows: in the colour picker,
/// while Alt is held over the capture before a selection, after C.
fn labelled(ed: *const Editor) bool {
    if (ed.tools.mode == .eyedropper or ed.loupe.copied_until_ms != 0) return true;
    return ed.mod_alt and ed.drag == .none and ed.doc.sel == null;
}

/// The colour was just copied: the label says so for a moment.
pub fn copied(ed: *Editor) void {
    ed.loupe.copied_until_ms = motion.now() + copied_ms;
    ed.loupe.copied_at = ed.loupe.look.at;
    ed.needs_render = true;
}

/// Still fading, or its hint.
pub fn busy(ed: *const Editor) bool {
    return ed.loupe.shown.busy(motion.now()) or hint.busy(ed);
}

/// When it next changes by itself (0: never): Ctrl has been held long
/// enough, the "Copied" note or the hint ends.
pub fn dueMs(ed: *const Editor) i64 {
    const st = &ed.loupe;
    var due: i64 = 0;
    for ([_]i64{ st.copied_until_ms, hint.dueMs(ed), st.hold_due_ms }) |t| {
        if (t != 0 and (due == 0 or t < due)) due = t;
    }
    return due;
}

/// Physical pixels per image pixel at the current zoom.
fn cellSize(ed: *const Editor) i32 {
    return @max(2, ed.sc(@floatFromInt(ed.loupe.zoom)));
}

/// Where it goes on this pane (null: not here, or gone).
fn placement(ed: *const Editor) ?place.Placement {
    if (ed.pane_i != ed.loupe.pane or ed.loupe.shown.at(motion.now()) <= 0) return null;
    const p = ed.pn().view.toBuf(ed.loupe.look.at);
    var s: place.Size = .{ .lens = ed.sc(lens_side), .off = ed.sc(18), .margin = ed.sc(6) };
    if (labelled(ed)) {
        const ls = label.size(ed);
        s.label_w = ls[0];
        s.label_h = ls[1];
        s.gap = ed.sc(8);
    }
    var avoid: [3]Rect = @splat(Rect.empty);
    if (ed.isTbPane()) {
        avoid[0] = ed.toolbar_rect;
        avoid[1] = ed.capmode.rect;
    }
    const sb = ed.selBuf();
    if (sb) |r| avoid[2] = selection.dimsPillRect(ed, r);
    const inside: ?Point = if (sb) |r| .{ .x = r.x + @divTrunc(r.w, 2), .y = r.y + @divTrunc(r.h, 2) } else null;
    const way = if (ed.loupe.look.edge) place.Corner.toward(p, inside) else place.Corner{};
    return place.place(p, way, s, ed.screenRect(), &avoid);
}

/// Everything it paints on this pane, its shadow included.
pub fn footprint(ed: *const Editor) ?Rect {
    const pl = placement(ed) orelse return null;
    const sh = material.shadowFootprint(ed, pl.lens.expand(1), ed.theme.loupe_shadow);
    return if (pl.label.isEmpty()) sh else Rect.unite(sh, pl.label.expand(ed.sc(2)));
}

pub fn draw(ed: *Editor, canvas: *Canvas) void {
    const pl = placement(ed) orelse return;
    const a = ed.loupe.shown.at(motion.now());
    const snap = if (a < 1) material.Snapshot.take(ed.alloc, canvas, footprint(ed).?) else null;
    const k = grow_from + (1 - grow_from) * a;
    const lr = grown(pl.lens, pl.anchor, k);
    const radius = lens_radius * ed.uf() * k;
    material.drawShadow(ed, canvas, .loupe, lr, radius, ed.theme.loupe_shadow, 1);
    lens_mod.draw(canvas, lensFor(ed, lr, pl.lens.w, radius), pixels(ed));
    if (!pl.label.isEmpty()) {
        var lab = pl.label;
        lab.x = pl.anchor.x + scaled(pl.label.x - pl.anchor.x, k);
        lab.y = pl.anchor.y + scaled(pl.label.y - pl.anchor.y, k);
        const ip = ed.loupe.look.at;
        label.draw(ed, canvas, lab, .{ .color = pixels(ed).at(ip.x, ip.y), .copied = ed.loupe.copied_until_ms != 0 });
    }
    if (snap) |s| s.restore(ed.alloc, canvas, a);
}

/// The lens in `r` (full size `size`): on an edge, the selection inside
/// it once it has an area (it may also go as the lens fades out); else
/// the pointer's pixel framed.
fn lensFor(ed: *const Editor, r: Rect, size: i32, radius: f64) lens_mod.Lens {
    const lk = ed.loupe.look;
    const th = ed.theme;
    const s = if (lk.edge and ed.doc.sel != null) ed.doc.sel.?.normalized() else Rect.empty;
    const sel: ?lens_mod.Selection = if (s.isEmpty()) null else .{
        .rect = s,
        .keep = ed.dim_keep,
        .light = th.sel_edge,
        .dark = th.sel_edge_outer,
    };
    return .{
        .rect = r,
        .size = size,
        .radius = radius,
        .cell = cellSize(ed),
        .centre = lk.at,
        .mark = @max(1, ed.sc(1)),
        .grid = ed.loupe.zoom >= grid_zoom,
        .target = !lk.edge,
        .selection = sel,
    };
}

/// The composed picture (annotations included) the lens magnifies.
fn pixels(ed: *const Editor) lens_mod.Pixels {
    return .{ .px = ed.layer, .w = ed.img.width, .h = ed.img.height };
}

/// `r` scaled by `k` toward its point `anchor`.
fn grown(r: Rect, anchor: Point, k: f64) Rect {
    const x0 = anchor.x + scaled(r.x - anchor.x, k);
    const y0 = anchor.y + scaled(r.y - anchor.y, k);
    const x1 = anchor.x + scaled(r.right() - anchor.x, k);
    const y1 = anchor.y + scaled(r.bottom() - anchor.y, k);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn scaled(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

/// `p` on the picture's pixel corners (where a selection's edge can be).
fn clampImg(ed: *const Editor, p: Point) Point {
    return .{
        .x = std.math.clamp(p.x, 0, @as(i32, @intCast(ed.img.width))),
        .y = std.math.clamp(p.y, 0, @as(i32, @intCast(ed.img.height))),
    };
}

/// The colour of the pixel it looks at (null off the picture).
pub fn colorAt(ed: *const Editor) ?u32 {
    const ip = ed.loupe.look.at;
    if (ip.x < 0 or ip.y < 0 or ip.x >= ed.img.width or ip.y >= ed.img.height) return null;
    return pixels(ed).at(ip.x, ip.y);
}

test "growing in keeps the corner by the pointer" {
    const r: Rect = .{ .x = 100, .y = 100, .w = 100, .h = 100 };
    const g = grown(r, .{ .x = 100, .y = 100 }, 0.5);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 50, .h = 50 }, g);
    const h = grown(r, .{ .x = 200, .y = 200 }, 0.5);
    try std.testing.expectEqual(Rect{ .x = 150, .y = 150, .w = 50, .h = 50 }, h);
}
