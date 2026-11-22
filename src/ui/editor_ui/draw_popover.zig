//! Drawing the colour and size popover (swatches, custom colour, size
//! slider, segmented controls) and the More menu.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const icons = @import("../icons.zig");
const hsv_mod = @import("../hsv.zig");
const tui = @import("../tools/tui.zig");
const buttons = @import("buttons.zig");
const material = @import("material.zig");
const hit = @import("hit.zig");
const draw_toolbar = @import("draw_toolbar.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Button = buttons.Button;
const Icon = icons.Icon;
const palette = shapes_mod.palette;
const focusRing = draw_toolbar.focusRing;

/// Segment rows whose trough is drawn, by their y (minInt: free slot).
const Troughs = [4]i32;

pub fn drawPopover(self: *Editor, canvas: *Canvas) void {
    const now = motion.now();
    const p = self.pop_open.at(now);
    const th = self.theme;
    const f = self.uf();
    const pr = self.pop_rect;
    // grow from 96% around the side facing the toolbar
    const sc_k = 0.96 + 0.04 * p;
    const gw: i32 = @intFromFloat(@round(ff(pr.w) * sc_k));
    const gh: i32 = @intFromFloat(@round(ff(pr.h) * sc_k));
    const gy = if (pr.y < self.toolbar_rect.y) pr.bottom() - gh else pr.y;
    const grown = Rect{ .x = pr.x + @divTrunc(pr.w - gw, 2), .y = gy, .w = gw, .h = gh };
    const sh = th.popover_shadow;
    const snap = if (p < 1) material.Snapshot.take(self.alloc, canvas, material.shadowFootprint(self, pr, sh)) else null;
    const radius = (if (self.popover == .more) theme.menu_radius else theme.popover_radius) * f;
    material.drawMaterial(self, canvas, .popover, grown, radius, sh);
    switch (self.popover) {
        .none => {},
        .colors => drawColorsContent(self, canvas),
        .more => drawMenuContent(self, canvas),
    }
    if (snap) |s| s.restore(self.alloc, canvas, p);
}

fn drawColorsContent(self: *Editor, canvas: *Canvas) void {
    var troughs: Troughs = @splat(std.math.minInt(i32));
    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .popover) continue;
        switch (b.kind) {
            .color => |ci| drawSwatch(self, canvas, b, bi, palette[ci], !self.custom_active and self.color_idx == ci),
            .custom_color => drawCustomSwatch(self, canvas, b, bi),
            .thickness => drawSizeSlider(self, canvas, b, bi),
            .seg => |s| drawSegment(self, canvas, b, bi, s, &troughs),
            .ext => tui.drawPopoverButton(self, canvas, b, bi),
            else => {},
        }
    }
}

/// A palette colour: a dot, ringed in accent when chosen.
fn drawSwatch(self: *const Editor, canvas: *Canvas, b: Button, bi: usize, col: u32, sel: bool) void {
    const th = self.theme;
    const f = self.uf();
    const r = b.rect;
    const cx = ff(r.x) + ff(r.w) / 2.0;
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const hv = hit.hoverAmount(self, bi);
    const rad = ff(r.w) / 2.0;
    if (sel) {
        canvas.ringAA(cx, cy, rad + 3.0 * f, 2.0 * f, th.accent);
    } else if (hv > 0) {
        canvas.ringAA(cx, cy, rad + 2.5 * f, 1.5 * f, theme.fade(th.hairline, 2 * hv));
    }
    canvas.fillCircleAA(cx, cy, rad, col);
    canvas.ringAA(cx, cy, rad - 0.5 * f, 1.0 * f, 0x59808080);
    if (self.focus == bi) focusRing(self, canvas, r.expand(self.sc(2)), rad + 2 * f);
}

/// The custom colour: a hue wheel, with the chosen colour inside it.
fn drawCustomSwatch(self: *const Editor, canvas: *Canvas, b: Button, bi: usize) void {
    const th = self.theme;
    const f = self.uf();
    const r = b.rect;
    const cx = ff(r.x) + ff(r.w) / 2.0;
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const hv = hit.hoverAmount(self, bi);
    const rad = ff(r.w) / 2.0;
    drawConic(canvas, cx, cy, rad);
    if (self.custom_active) {
        canvas.fillCircleAA(cx, cy, rad * 0.42, self.custom_color);
        canvas.ringAA(cx, cy, rad * 0.42, 1.5 * f, 0xFFFFFFFF);
        canvas.ringAA(cx, cy, rad + 3.0 * f, 2.0 * f, th.accent);
    } else if (hv > 0) canvas.ringAA(cx, cy, rad + 2.5 * f, 1.5 * f, theme.fade(th.hairline, 2 * hv));
    if (self.focus == bi) focusRing(self, canvas, r.expand(self.sc(2)), rad + 2 * f);
}

/// The size label and value above a track with a knob.
fn drawSizeSlider(self: *const Editor, canvas: *Canvas, b: Button, bi: usize) void {
    const th = self.theme;
    const f = self.uf();
    const r = b.rect;
    const pr = self.pop_rect;
    const pad = self.sc(theme.popover_pad);
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const fs = theme.font_small * f;
    const ly = r.y - self.sc(8) - text_mod.height(fs);
    text_mod.draw(canvas, pr.x + pad, ly, fs, th.muted, "Size");
    var buf: [16]u8 = undefined;
    const v = std.fmt.bufPrint(&buf, "{d} px", .{self.thickness}) catch "?";
    text_mod.draw(canvas, pr.right() - pad - text_mod.width(fs, v), ly, fs, th.muted, v);
    const knob = 9.0 * f;
    const t = ff(self.thickness - 1) / 31.0;
    const track_h = self.sc(4);
    const ty = r.y + @divTrunc(r.h - track_h, 2);
    canvas.fillRoundRectAA(r.x, ty, r.w, track_h, ff(track_h) / 2, th.track);
    const kx = ff(r.x) + knob + t * (ff(r.w) - 2 * knob);
    canvas.fillRoundRectAA(r.x, ty, @intFromFloat(@round(kx - ff(r.x))), track_h, ff(track_h) / 2, th.accent);
    canvas.fillCircleAA(kx, cy + 1.0 * f, knob + 1.0 * f, 0x26000000);
    canvas.fillCircleAA(kx, cy + 0.5 * f, knob + 0.5 * f, 0x33000000);
    canvas.fillCircleAA(kx, cy, knob, 0xFFFFFFFF);
    if (self.focus == bi) focusRing(self, canvas, .{ .x = @intFromFloat(kx - knob), .y = @intFromFloat(cy - knob), .w = @intFromFloat(2 * knob), .h = @intFromFloat(2 * knob) }, knob);
}

/// One segment of a segmented control (the row's trough drawn once).
fn drawSegment(self: *const Editor, canvas: *Canvas, b: Button, bi: usize, s: buttons.Seg, troughs: *Troughs) void {
    const th = self.theme;
    const f = self.uf();
    const r = b.rect;
    const hv = hit.hoverAmount(self, bi);
    if (claimTrough(troughs, r.y)) {
        const pr = self.pop_rect;
        const pad = self.sc(theme.popover_pad);
        canvas.fillRoundRectAA(pr.x + pad, r.y - self.sc(2), pr.w - 2 * pad, r.h + self.sc(4), 9.0 * f, th.track);
    }
    const on = buttons.segOn(self, s);
    if (on) {
        canvas.fillRoundRectAA(r.x, r.y + self.sc(1), r.w, r.h, 7.0 * f, 0x26000000);
        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.seg_on);
    } else if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, theme.fade(th.hover, hv));
    var kb: [32]u8 = undefined;
    const l = buttons.buttonLabel(self, b.kind, &kb).name;
    const fs = theme.font_small * f;
    const tw = text_mod.width(fs, l);
    text_mod.draw(canvas, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, if (on) th.fg else th.muted, l);
    if (self.focus == bi) focusRing(self, canvas, r, 7.0 * f);
}

/// True the first time the row at `y` asks: its trough is to be drawn.
fn claimTrough(troughs: *Troughs, y: i32) bool {
    for (troughs) |k| if (k == y) return false;
    for (troughs) |*k| if (k.* == std.math.minInt(i32)) {
        k.* = y;
        break;
    };
    return true;
}

/// A hue wheel disc: the custom colour swatch.
fn drawConic(canvas: *Canvas, cx: f64, cy: f64, r: f64) void {
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const n: i32 = @intFromFloat(@ceil(2 * r + 2));
    var y = y0;
    while (y < y0 + n) : (y += 1) {
        var x = x0;
        while (x < x0 + n) : (x += 1) {
            const dx = ff(x) + 0.5 - cx;
            const dy = ff(y) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            const cov = std.math.clamp(r - d + 0.5, 0, 1);
            if (cov <= 0) continue;
            var hue = std.math.atan2(dx, -dy) * 180.0 / std.math.pi;
            if (hue < 0) hue += 360;
            const c = hsv_mod.hsvToRgb(hue, 0.85, 1);
            canvas.blend(x, y, (c & 0xFFFFFF) | (@as(u32, @intFromFloat(@round(cov * 255))) << 24));
        }
    }
}

fn drawMenuContent(self: *Editor, canvas: *Canvas) void {
    const th = self.theme;
    const f = self.uf();
    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .menu) continue;
        const r = b.rect;
        if (b.kind == .cancel) {
            canvas.fillRect(r.x + self.sc(10), r.y - self.sc(5), r.w - self.sc(20), 1, th.hairline);
        }
        const hot = (self.hover_btn >= 0 and @as(usize, @intCast(self.hover_btn)) == bi) or self.focus == bi;
        if (hot) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.accent_fill);
        const fg = if (hot) th.on_accent else th.fg;
        const sub = if (hot) theme.withAlpha(th.on_accent, 0xBF) else th.muted;
        const is = self.sc(16);
        const checked = b.kind == .beautify and self.beautify.enabled;
        const icon: Icon = if (checked) .check else buttons.kindIcon(self, b.kind) orelse .more;
        icons.draw(canvas, icon, r.x + self.sc(10), r.y + @divTrunc(r.h - is, 2), is, if (checked and !hot) th.accent else fg);
        var kb: [32]u8 = undefined;
        const l = buttons.buttonLabel(self, b.kind, &kb);
        const fs = theme.font_label * f;
        text_mod.draw(canvas, r.x + self.sc(10) + is + self.sc(10), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, fg, l.name);
        const ks = theme.font_small * f;
        if (l.key.len > 0) text_mod.draw(canvas, r.right() - self.sc(10) - text_mod.width(ks, l.key), r.y + @divTrunc(r.h - text_mod.height(ks), 2), ks, sub, l.key);
    }
}
