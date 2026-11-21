//! Tooltips: a control's name and shortcut in a pill beside the bars,
//! shown after a short hover or for the keyboard-focused control.

const std = @import("std");
const text_mod = @import("../../gfx/text.zig");
const render = @import("../../gfx/render.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const buttons = @import("buttons.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Button = buttons.Button;

fn tooltipButton(self: *const Editor) ?Button {
    if (self.drag != .none) return null;
    if (self.focus) |fi| {
        if (fi < self.buttons.items.len) {
            const b = self.buttons.items[fi];
            if (b.layer != .menu) return b;
        }
    }
    if (self.mouse_pane == self.tb_pane and self.hover_btn >= 0 and self.hover_btn < self.buttons.items.len) {
        if (motion.now() - self.hover_since_ms < theme.tooltip_delay) return null;
        const b = self.buttons.items[@intCast(self.hover_btn)];
        if (b.layer == .menu or b.kind == .seg or b.kind == .thickness) return null;
        return b;
    }
    return null;
}

/// When the pending tooltip is due (0: none pending).
pub fn tooltipDueMs(self: *const Editor) i64 {
    if (self.hover_btn < 0 or self.hover_btn >= self.buttons.items.len or self.drag != .none) return 0;
    if (self.tip_drawn_for == self.hover_since_ms or self.mouse_pane != self.tb_pane) return 0;
    const b = self.buttons.items[@intCast(self.hover_btn)];
    if (b.layer == .menu or b.kind == .seg or b.kind == .thickness) return 0;
    return self.hover_since_ms + theme.tooltip_delay;
}

pub fn tooltipRect(self: *const Editor) ?Rect {
    const b = tooltipButton(self) orelse return null;
    var kb: [32]u8 = undefined;
    const l = buttons.buttonLabel(self, b.kind, &kb);
    const fs = theme.font_small * self.uf();
    var tw = text_mod.width(fs, l.name);
    if (l.key.len > 0) tw += self.sc(8) + text_mod.width(fs, l.key);
    const th = text_mod.height(fs) + self.sc(8);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const pw = tw + self.sc(20);
    const x = std.math.clamp(b.rect.x + @divTrunc(b.rect.w - pw, 2), 4, @max(4, w - pw - 4));
    // away from the selection: outside the toolbar, beyond the popover
    var top = b.rect.y;
    var bottom = b.rect.bottom();
    if (b.layer == .bar or b.layer == .panel) {
        top = self.toolbar_rect.y;
        bottom = self.toolbar_rect.bottom();
        if (!self.panel_rect.isEmpty()) {
            top = @min(top, self.panel_rect.y);
            bottom = @max(bottom, self.panel_rect.bottom());
        }
    }
    var y = if (self.tb_below) bottom + self.sc(8) else top - th - self.sc(8);
    if (y + th > h - 2 or y < 2) y = if (self.tb_below) top - th - self.sc(8) else bottom + self.sc(8);
    if (self.popover != .none and b.layer != .popover and Rect.intersect(.{ .x = x, .y = y, .w = pw, .h = th }, self.pop_rect) != null) return null;
    return .{ .x = x, .y = y, .w = pw, .h = th };
}

pub fn drawTooltip(self: *Editor, canvas: *Canvas) void {
    const b = tooltipButton(self) orelse return;
    self.tip_drawn_for = self.hover_since_ms;
    const r = tooltipRect(self) orelse return;
    var kb: [32]u8 = undefined;
    const l = buttons.buttonLabel(self, b.kind, &kb);
    const f = self.uf();
    const th = self.theme;
    const fs = theme.font_small * f;
    canvas.fillRoundRectAA(r.x, r.y + self.sc(2), r.w, r.h, 7.0 * f, 0x1F000000);
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.pill_bg);
    const ty = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    text_mod.draw(canvas, r.x + self.sc(10), ty, fs, th.pill_fg, l.name);
    if (l.key.len > 0) text_mod.draw(canvas, r.right() - self.sc(10) - text_mod.width(fs, l.key), ty, fs, 0x99EBEBF5, l.key);
}
