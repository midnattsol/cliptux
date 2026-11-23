//! The one-time "Hold Ctrl to zoom" hint: the first time ever (the caller
//! keeps that across runs) an edge or corner of the selection is dragged
//! while the magnifier waits for Ctrl, a quiet pill beside the size label
//! (its look) says so for a couple of seconds, fading in and out.

const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const selchrome = @import("../selchrome.zig");
const material = @import("material.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;

/// how long it stays
const show_ms = 2500;
const hint_text = "Hold Ctrl to zoom";

pub const Hint = struct {
    /// never shown yet (the caller says)
    due: bool = false,
    /// on screen until then (monotonic ms); 0: not now
    until_ms: i64 = 0,
    /// shown this run: the caller remembers it
    seen: bool = false,
    /// 0 gone .. 1 shown, eased
    shown: motion.Tween = .{ .dur_ms = theme.motion_fast },
};

/// An edge or corner of the selection is being dragged: the hint, if it
/// is due and about the setting in use.
pub fn edgeDragged(ed: *Editor) void {
    const h = &ed.loupe.hint;
    if (!h.due or ed.loupe.mode != .hold) return;
    h.due = false;
    h.seen = true;
    h.until_ms = motion.now() + show_ms;
    ed.needs_render = true;
}

/// Once a frame: fade toward shown while it is on, gone after.
pub fn sync(ed: *Editor, now: i64) void {
    const h = &ed.loupe.hint;
    if (h.until_ms != 0 and now >= h.until_ms) h.until_ms = 0;
    h.shown.to(if (h.until_ms != 0) 1 else 0, now);
}

/// When it goes by itself (0: it is not on).
pub fn dueMs(ed: *const Editor) i64 {
    return ed.loupe.hint.until_ms;
}

/// Still fading.
pub fn busy(ed: *const Editor) bool {
    return ed.loupe.hint.shown.busy(motion.now());
}

/// Where it goes beside the size pill `pill`, on the pane showing that
/// (null: not on).
pub fn rect(ed: *const Editor, pill: Rect) ?Rect {
    if (!ed.isTbPane() or ed.loupe.hint.shown.at(motion.now()) <= 0) return null;
    const w = text_mod.widthStyled(theme.font_small * ed.uf(), selchrome.size_style, hint_text) + ed.sc(20);
    const gap = ed.sc(6);
    const edge = 6;
    var x = pill.right() + gap;
    if (x + w > @as(i32, @intCast(ed.pn().width)) - edge) x = pill.x - gap - w;
    return .{ .x = @max(edge, x), .y = pill.y, .w = w, .h = pill.h };
}

pub fn draw(ed: *Editor, canvas: *Canvas, pill: Rect) void {
    const r = rect(ed, pill) orelse return;
    const a = ed.loupe.hint.shown.at(motion.now());
    const snap = if (a < 1) material.Snapshot.take(ed.alloc, canvas, r.expand(1)) else null;
    selchrome.sizePill(canvas, r, ed.uf(), ed.theme, hint_text);
    if (snap) |s| s.restore(ed.alloc, canvas, a);
}
