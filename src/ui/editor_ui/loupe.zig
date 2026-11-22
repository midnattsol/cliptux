//! The magnifier: a lens (ui/lens.zig) beside the pointer while an area
//! is chosen, with the pixel's coordinates and colour in a pill under it
//! (loupe_label.zig), and for the colour picker. When it shows follows
//! the `loupe` setting; it fades and grows in from the corner nearest the
//! pointer, and fades out where it was. The wheel (and - =) zoom it, C
//! copies the colour (editor/loupe_input.zig).

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
const hit = @import("hit.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

/// the lens's side (at least: as wide as its label) and corner radius,
/// logical px
const lens_side = 152;
const lens_radius = 12;
/// what it starts from as it grows in
const grow_from = 0.88;
/// how long "Copied" stays in the label
const copied_ms = 1400;

pub const State = struct {
    /// when it shows, and its zoom (one of config.loupe_zooms)
    mode: config.Loupe = .always,
    zoom: u8 = config.loupe_zoom_default,
    /// 0 gone .. 1 shown, eased
    shown: motion.Tween = .{ .dur_ms = theme.motion_fast },
    /// the pointer where it was last wanted, and on which pane: it fades
    /// out there
    at: Point = .{ .x = 0, .y = 0 },
    pane: u8 = 0,
    /// the label says "Copied" until then (monotonic ms), while the
    /// pointer stays on that image pixel
    copied_until_ms: i64 = 0,
    copied_at: Point = .{ .x = 0, .y = 0 },
};

/// Wanted now, for the pointer's pane (the current one): the colour
/// picker always; else as the setting says, before a selection or while
/// one is dragged, never over the help, a tool's mode or the chrome.
pub fn wanted(ed: *const Editor) bool {
    if (ed.help_open or !ed.screenRect().contains(ed.mouse.x, ed.mouse.y)) return false;
    if (ed.tools.mode == .eyedropper) return true;
    if (ed.tools.mode != .none or (ed.drag == .none and hit.onChrome(ed, ed.mouse))) return false;
    const dragging = ed.drag == .selecting or ed.drag == .resizing_sel;
    return switch (ed.loupe.mode) {
        .never => false,
        .selecting => dragging,
        .always => dragging or (ed.drag == .none and ed.doc.sel == null),
    };
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

/// Once a frame: follow the pointer while wanted, fade toward shown or
/// gone, end the "Copied" note when due.
pub fn sync(ed: *Editor) void {
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    ed.pane_i = ed.mouse_pane;
    const st = &ed.loupe;
    const now = motion.now();
    const want = wanted(ed);
    if (want) {
        st.at = ed.mouse;
        st.pane = ed.mouse_pane;
    }
    st.shown.to(if (want) 1 else 0, now);
    if (st.copied_until_ms != 0 and (now >= st.copied_until_ms or !std.meta.eql(imgPoint(ed), st.copied_at))) st.copied_until_ms = 0;
}

/// The colour was just copied: the label says so for a moment.
pub fn copied(ed: *Editor) void {
    ed.loupe.copied_until_ms = motion.now() + copied_ms;
    ed.loupe.copied_at = imgPoint(ed);
    ed.needs_render = true;
}

/// Still fading.
pub fn busy(ed: *const Editor) bool {
    return ed.loupe.shown.busy(motion.now());
}

/// When the "Copied" note ends (0: none).
pub fn dueMs(ed: *const Editor) i64 {
    return ed.loupe.copied_until_ms;
}

/// The image pixel under the magnifier's pointer (on its pane).
pub fn imgPoint(ed: *const Editor) Point {
    return ed.panes[ed.loupe.pane].view.toImg(ed.loupe.at);
}

/// Physical pixels per image pixel at the current zoom.
fn cellSize(ed: *const Editor) i32 {
    return @max(2, ed.sc(@floatFromInt(ed.loupe.zoom)));
}

/// Where it goes on this pane (null: not here, or gone).
fn placement(ed: *const Editor) ?place.Placement {
    if (ed.pane_i != ed.loupe.pane or ed.loupe.shown.at(motion.now()) <= 0) return null;
    const ls = label.size(ed);
    const side = @max(ed.sc(lens_side), ls[0]);
    const s: place.Size = .{ .lens = side, .label_w = side, .label_h = ls[1], .gap = ed.sc(8), .off = ed.sc(20), .margin = ed.sc(6) };
    var avoid: [3]Rect = @splat(Rect.empty);
    if (ed.isTbPane()) {
        avoid[0] = ed.toolbar_rect;
        avoid[1] = ed.capmode.rect;
    }
    if (ed.selBuf()) |sb| avoid[2] = selection.dimsPillRect(ed, sb);
    return place.place(ed.loupe.at, s, ed.screenRect(), &avoid);
}

/// Everything it paints on this pane, its shadow included.
pub fn footprint(ed: *const Editor) ?Rect {
    const pl = placement(ed) orelse return null;
    const sh = material.shadowFootprint(ed, pl.lens.expand(1), ed.theme.loupe_shadow);
    return Rect.unite(sh, pl.label.expand(ed.sc(2)));
}

pub fn draw(ed: *Editor, canvas: *Canvas) void {
    const pl = placement(ed) orelse return;
    const a = ed.loupe.shown.at(motion.now());
    const snap = if (a < 1) material.Snapshot.take(ed.alloc, canvas, footprint(ed).?) else null;
    const k = grow_from + (1 - grow_from) * a;
    const lr = grown(pl.lens, pl.anchor, k);
    const radius = lens_radius * ed.uf() * k;
    material.drawShadow(ed, canvas, .loupe, lr, radius, ed.theme.loupe_shadow, 1);
    const ip = imgPoint(ed);
    const px = pixels(ed);
    lens_mod.draw(canvas, .{ .rect = lr, .size = pl.lens.w, .radius = radius, .cell = cellSize(ed), .centre = ip, .mark = @max(1, ed.sc(1)) }, px, ed.theme.accent);
    var lab = pl.label;
    lab.x = pl.anchor.x + scaled(pl.label.x - pl.anchor.x, k);
    lab.y = pl.anchor.y + scaled(pl.label.y - pl.anchor.y, k);
    label.draw(ed, canvas, lab, .{ .at = clampImg(ed, ip), .color = px.at(ip.x, ip.y), .copied = ed.loupe.copied_until_ms != 0 });
    if (snap) |s| s.restore(ed.alloc, canvas, a);
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

/// The coordinates shown: on the picture.
fn clampImg(ed: *const Editor, p: Point) Point {
    return .{
        .x = std.math.clamp(p.x, 0, @as(i32, @intCast(ed.img.width)) - 1),
        .y = std.math.clamp(p.y, 0, @as(i32, @intCast(ed.img.height)) - 1),
    };
}

/// The colour under the magnifier's pointer (null off the picture).
pub fn colorAt(ed: *const Editor) ?u32 {
    const ip = imgPoint(ed);
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
