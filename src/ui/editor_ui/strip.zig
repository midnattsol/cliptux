//! The mode strip: a small Glass bar of capture modes (editor/capmode.zig)
//! at the bottom centre of the monitor with the pointer, while nothing is
//! selected yet. It fades out as a selection starts (the toolbar takes
//! over) and back in if the selection goes away. Its buttons are the
//! editor's (layer .strip): hover, tooltips, focus and clicks as on the
//! toolbar.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const barkit = @import("../barkit.zig");
const capmode = @import("../editor/capmode.zig");
const buttons = @import("buttons.zig");
const material = @import("material.zig");
const hit = @import("hit.zig");
const draw_toolbar = @import("draw_toolbar.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Mode = capmode.Mode;

/// Gap from the monitor's bottom edge, logical pixels.
const bottom_gap = 40;

fn sepW(self: *const Editor) i32 {
    return 1 + 2 * self.sc(theme.sep_margin);
}

/// The strip's size for the modes in capmode.order.
fn size(self: *const Editor) [2]i32 {
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    var w: i32 = 2 * pad - gap;
    var grp: u8 = 0;
    for (capmode.order) |m| {
        if (m.group() != grp) {
            w += sepW(self) + gap;
            grp = m.group();
        }
        w += btn + gap;
    }
    return .{ w, btn + 2 * pad };
}

/// Mode `k`'s button in a strip at `r`; the x of a separator before it
/// (0: none).
fn itemRect(self: *const Editor, r: Rect, k: usize) struct { rect: Rect, sep_x: i32 } {
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    var x = r.x + pad;
    var sep_x: i32 = 0;
    for (capmode.order[0 .. k + 1], 0..) |m, i| {
        sep_x = 0;
        if (i > 0 and m.group() != capmode.order[i - 1].group()) {
            sep_x = x + self.sc(theme.sep_margin);
            x += sepW(self) + gap;
        }
        if (i == k) break;
        x += btn + gap;
    }
    return .{ .rect = .{ .x = x, .y = r.y + pad, .w = btn, .h = btn }, .sep_x = sep_x };
}

/// The monitor under the pointer in this pane's buffer pixels (the whole
/// surface when it shows one monitor).
fn monitorBuf(self: *const Editor) Rect {
    const scr = self.screenRect();
    if (self.monitors.len < 2) return scr;
    const mr = capmode.monitorAtPointer(self);
    return Rect.intersect(self.pn().view.rectToBuf(mr), scr) orelse scr;
}

/// Place the strip (on the toolbar's pane, which is the pointer's while
/// nothing is selected), fade it toward shown or gone, and add its
/// buttons while it is wanted.
pub fn layout(self: *Editor) !void {
    const st = &self.capmode;
    const now = motion.now();
    const want = capmode.wanted(self);
    if (!st.shown_once and want) {
        st.shown_once = true;
        st.alpha.snap(1);
    }
    st.alpha.to(if (want) 1 else 0, now);
    // never under the toolbar as it takes over
    if (!want and Rect.intersect(st.rect, self.toolbar_rect) != null) st.alpha.snap(0);
    const a = st.alpha.at(now);
    if (a <= 0) {
        st.rect = Rect.empty;
        return;
    }
    const wh = size(self);
    const mon = monitorBuf(self);
    const rise: i32 = @intFromFloat(@round((1 - a) * @as(f64, @floatFromInt(self.sc(6)))));
    const y = @max(mon.y, mon.bottom() - wh[1] - self.sc(bottom_gap)) + rise;
    st.rect = .{ .x = mon.x + @divTrunc(mon.w - wh[0], 2), .y = y, .w = wh[0], .h = wh[1] };
    slideChosen(self, now);
    if (!want) return;
    for (capmode.order, 0..) |m, k| {
        try self.buttons.append(self.alloc, .{ .rect = itemRect(self, st.rect, k).rect, .kind = .{ .mode = m }, .group = m.group(), .layer = .strip });
    }
}

/// The chosen mode's accent fill glides to its button.
fn slideChosen(self: *Editor, now: i64) void {
    const st = &self.capmode;
    const k = std.mem.indexOfScalar(Mode, &capmode.order, capmode.current(self)) orelse 0;
    const x: f64 = @floatFromInt(itemRect(self, st.rect, k).rect.x - st.rect.x);
    st.act_x.dur_ms = theme.motion;
    if (st.act_x.target == 0 and st.act_x.start_ms == 0) st.act_x.snap(x) else st.act_x.to(x, now);
}

/// Still fading in or out, or the accent gliding.
pub fn busy(self: *const Editor) bool {
    const t = motion.now();
    return self.capmode.alpha.busy(t) or self.capmode.act_x.busy(t);
}

/// The strip's footprint with its shadow, if it shows.
pub fn footprint(self: *const Editor) ?Rect {
    const r = self.capmode.rect;
    if (r.isEmpty()) return null;
    return material.shadowFootprint(self, r.expand(self.sc(1)), self.theme.bar_shadow);
}

/// Is buffer point `m` on the strip (while it takes the pointer)?
pub fn contains(self: *const Editor, x: i32, y: i32) bool {
    return capmode.wanted(self) and !self.capmode.rect.isEmpty() and self.capmode.rect.contains(x, y);
}

pub fn draw(self: *Editor, canvas: *Canvas) void {
    const r = self.capmode.rect;
    if (r.isEmpty()) return;
    const th = self.theme;
    const f = self.uf();
    const alpha = self.capmode.alpha.at(motion.now());
    const snap = if (alpha < 1) material.Snapshot.take(self.alloc, canvas, material.shadowFootprint(self, r, th.bar_shadow)) else null;
    material.drawMaterial(self, canvas, .strip, r, theme.bar_radius * f, th.bar_shadow);
    const btn = self.sc(theme.button);
    const ax = r.x + @as(i32, @intFromFloat(@round(self.capmode.act_x.at(motion.now()))));
    canvas.fillRoundRectAA(ax, r.y + self.sc(theme.bar_pad), btn, btn, theme.button_radius * f, th.accent_fill);
    for (capmode.order, 0..) |m, k| {
        const it = itemRect(self, r, k);
        if (it.sep_x != 0) barkit.separator(canvas, it.sep_x, r.y + @divTrunc(r.h - self.sc(theme.sep_h), 2), self.sc(theme.sep_h), th);
        drawItem(self, canvas, m, it.rect);
    }
    if (snap) |s| s.restore(self.alloc, canvas, alpha);
}

fn drawItem(self: *const Editor, canvas: *Canvas, m: Mode, r: Rect) void {
    const th = self.theme;
    const bi = buttonIndex(self, m);
    const hv = if (bi) |i| hit.hoverAmount(self, i) else 0;
    const look: barkit.Look = if (capmode.current(self) == m) .selected else .plain;
    const off = capmode.disabledWhy(self, m) != null;
    // the chosen one's fill slides on its own (draw)
    if (look == .plain and !off) barkit.fill(canvas, r, self.uf(), th, look, hv);
    const ink = if (off) theme.fade(barkit.ink(th, look, false), theme.disabled_alpha) else barkit.ink(th, look, false);
    draw_toolbar.drawIconIn(self, canvas, m.icon(), r, theme.icon, ink);
    // Record's dot, filled
    if (m == .record) canvas.fillCircleAA(@as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) / 2, @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2, 3.6 * self.uf(), ink);
    if (bi) |i| if (self.focus == i) draw_toolbar.focusRing(self, canvas, r, theme.button_radius * self.uf());
}

/// Mode `m`'s entry in the editor's buttons (none while fading out).
fn buttonIndex(self: *const Editor, m: Mode) ?usize {
    for (self.buttons.items, 0..) |b, i| {
        if (b.layer == .strip and b.kind == .mode and b.kind.mode == m) return i;
    }
    return null;
}

test "the strip fits its modes with a separator between groups" {
    var groups: usize = 1;
    for (capmode.order[1..], 0..) |m, i| {
        if (m.group() != capmode.order[i].group()) groups += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), groups);
}
