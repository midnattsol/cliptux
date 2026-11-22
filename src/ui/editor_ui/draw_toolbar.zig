//! Drawing the toolbar and the beautify panel: their material, the
//! sliding accent behind the active tool, and each button.

const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const icons = @import("../icons.zig");
const tui = @import("../tools/tui.zig");
const buttons = @import("buttons.zig");
const material = @import("material.zig");
const hit = @import("hit.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Button = buttons.Button;
const Icon = icons.Icon;

pub fn focusRing(self: *const Editor, canvas: *Canvas, r: Rect, radius: f64) void {
    const g = self.sc(theme.focus_gap);
    const fw = theme.focus_w * self.uf();
    const rr = r.expand(g + @as(i32, @intFromFloat(@ceil(fw / 2))));
    shapes_mod.roundRectRing(canvas, rr, radius + ff(g) + fw / 2, fw, self.theme.accent);
}

pub fn drawIconIn(self: *const Editor, canvas: *Canvas, icon: Icon, r: Rect, size: f64, color: u32) void {
    const s = self.sc(size);
    icons.draw(canvas, icon, r.x + @divTrunc(r.w - s, 2), r.y + @divTrunc(r.h - s, 2), s, color);
}

pub fn drawToolbar(self: *Editor, canvas: *Canvas) void {
    if (self.toolbar_rect.isEmpty()) return;
    const now = motion.now();
    const alpha = self.tb_alpha.at(now);
    const th = self.theme;
    const f = self.uf();
    const tb = self.toolbar_rect;
    var foot = material.shadowFootprint(self, tb, th.bar_shadow);
    if (!self.panel_rect.isEmpty()) foot = Rect.unite(foot, material.shadowFootprint(self, self.panel_rect, th.bar_shadow));
    const snap = if (alpha < 1) material.Snapshot.take(self.alloc, canvas, foot) else null;

    if (!self.panel_rect.isEmpty()) drawPanel(self, canvas);
    material.drawMaterial(self, canvas, .bar, tb, theme.bar_radius * f, th.bar_shadow);
    for (self.seps[0..self.n_seps]) |sp| canvas.fillRect(sp.x, sp.y, sp.w, sp.h, th.hairline);
    drawActiveFill(self, canvas, now);
    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .bar and b.layer != .panel) continue;
        drawBarButton(self, canvas, b, bi);
    }
    if (snap) |s| s.restore(self.alloc, canvas, alpha);
}

/// The beautify panel's material and its label.
fn drawPanel(self: *Editor, canvas: *Canvas) void {
    const th = self.theme;
    const f = self.uf();
    material.drawMaterial(self, canvas, .panel, self.panel_rect, theme.bar_radius * f, th.bar_shadow);
    const pad = self.sc(theme.bar_pad);
    const fs = theme.font_small * f;
    text_mod.draw(canvas, self.panel_rect.x + pad + self.sc(8), self.panel_rect.y + @divTrunc(self.panel_rect.h - text_mod.height(fs), 2), fs, th.muted, "Beautify");
}

/// The sliding accent fill of the active tool.
fn drawActiveFill(self: *const Editor, canvas: *Canvas, now: i64) void {
    const tb = self.toolbar_rect;
    for (self.buttons.items) |b| {
        if (b.kind == .tool and buttons.toolButtonActive(self, b.kind.tool)) {
            const ax = tb.x + @as(i32, @intFromFloat(@round(self.act_x.at(now))));
            const ay = tb.y + @as(i32, @intFromFloat(@round(self.act_y.at(now))));
            canvas.fillRoundRectAA(ax, ay, b.rect.w, b.rect.h, theme.button_radius * self.uf(), self.theme.accent_fill);
        }
    }
}

fn drawBarButton(self: *const Editor, canvas: *Canvas, b: Button, bi: usize) void {
    const th = self.theme;
    const active = buttons.buttonActive(self, b.kind);
    const hv = hit.hoverAmount(self, bi);
    const rad = theme.button_radius * self.uf();
    const r = b.rect;
    switch (b.kind) {
        .copy => drawCopyButton(self, canvas, r, hv),
        .colors => drawColorsButton(self, canvas, r, if (active) 1 else hv),
        .background => {
            if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hv));
            drawBackgroundSwatch(self, canvas, r.expand(-self.sc(8)));
        },
        else => {
            const on_accent = active and b.kind == .tool;
            if (!on_accent) {
                if (active) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.pressed);
                if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hv));
            }
            const fg: u32 = if (on_accent) th.on_accent else if (active and b.layer == .panel) th.accent else th.fg;
            if (buttons.kindIcon(self, b.kind)) |ic| drawIconIn(self, canvas, ic, r, theme.icon, fg) else if (b.kind == .ext) tui.drawBarLabel(self, canvas, b, fg);
        },
    }
    if (self.focus == bi) focusRing(self, canvas, r, rad);
}

/// The accent Copy button: icon and bold label.
fn drawCopyButton(self: *const Editor, canvas: *Canvas, r: Rect, hv: f64) void {
    const th = self.theme;
    const f = self.uf();
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, theme.button_radius * f, theme.mix(th.accent_fill, th.accent_fill_hover, hv));
    const is = self.sc(16);
    icons.draw(canvas, .copy, r.x + self.sc(10), r.y + @divTrunc(r.h - is, 2), is, th.on_accent);
    const fs = theme.font_label * f;
    text_mod.drawStyled(canvas, r.x + self.sc(10) + is + self.sc(6), r.y + @divTrunc(r.h - text_mod.heightStyled(fs, .bold), 2), fs, th.on_accent, .bold, "Copy");
}

/// The colour and size button: the current colour's dot and a chevron;
/// `press` is how pressed it looks (1 while its popover is open).
fn drawColorsButton(self: *const Editor, canvas: *Canvas, r: Rect, press: f64) void {
    const th = self.theme;
    const f = self.uf();
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, theme.button_radius * f, theme.mix(th.hover, th.pressed, press));
    const cx = ff(r.x) + 8.0 * f + 9.0 * f;
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const col = self.color();
    canvas.ringAA(cx, cy, 10.5 * f, 3.0 * f, theme.withAlpha(col, 0x99));
    canvas.ringAA(cx, cy, 10.0 * f, 2.0 * f, th.material_solid);
    canvas.fillCircleAA(cx, cy, 9.0 * f, col);
    if (col & 0xFFFFFF == 0xFFFFFF or (col & 0xFFFFFF) == 0x1C1C1E) canvas.ringAA(cx, cy, 8.5 * f, 1.0 * f, 0x59808080);
    const cs = self.sc(12);
    icons.draw(canvas, .chevron_down, r.x + self.sc(8 + 18 + 8), r.y + @divTrunc(r.h - cs, 2), cs, th.muted);
}

fn drawBackgroundSwatch(self: *const Editor, canvas: *Canvas, r: Rect) void {
    const bg = self.beautify.background();
    const s: u32 = @intCast(@min(64, @min(r.w, r.h)));
    var px: [64 * 64]u32 = @splat(0);
    if (bg.transparent()) {
        const cell = @max(2, s / 4);
        for (0..s) |yy| for (0..s) |xx| {
            px[yy * s + xx] = if ((xx / cell + yy / cell) % 2 == 0) 0xFFFFFFFF else 0xFFB8BEC6;
        };
    } else effects.gradient(&px, s, s, .{ .x = 0, .y = 0, .w = @intCast(s), .h = @intCast(s) }, bg.from, bg.to);
    effects.blitRounded(canvas.px, @intCast(canvas.w), @intCast(canvas.h), &px, s, s, r.x, r.y, @intFromFloat(5 * self.uf()));
    shapes_mod.roundRectRing(canvas, .{ .x = r.x, .y = r.y, .w = @intCast(s), .h = @intCast(s) }, 5 * self.uf(), 1, 0x40808080);
}
