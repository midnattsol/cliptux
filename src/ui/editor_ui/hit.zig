//! Pointer and keyboard queries on the chrome: which control is under
//! the pointer, keyboard focus order, the size slider's value, hover
//! fades and whether animations still need frames.

const std = @import("std");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const motion = @import("../motion.zig");
const ff = @import("common.zig").ff;
const pop_fade = @import("pop_fade.zig");

const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

/// Tab order: the popover or menu while one is open, else the bars.
pub fn moveFocus(self: *Editor, dir: i32) void {
    const top = self.popover != .none;
    var list: [64]usize = undefined;
    var n: usize = 0;
    for (self.buttons.items, 0..) |b, i| {
        const on_top = b.layer == .popover or b.layer == .menu;
        if (on_top != top or n == list.len) continue;
        list[n] = i;
        n += 1;
    }
    if (n == 0) return;
    var cur: i32 = if (dir > 0) -1 else @intCast(n);
    if (self.focus) |f| for (list[0..n], 0..) |li, k| {
        if (li == f) cur = @intCast(k);
    };
    const ni: usize = @intCast(@mod(cur + dir, @as(i32, @intCast(n))));
    self.focus = list[ni];
}

/// The control under buffer point `m` (pointer pane must be the toolbar's).
pub fn buttonAt(self: *const Editor, m: Point) ?usize {
    if (self.mouse_pane != self.tb_pane) return null;
    // the popover is on top
    var i = self.buttons.items.len;
    while (i > 0) {
        i -= 1;
        const b = self.buttons.items[i];
        if (b.rect.contains(m.x, m.y)) return i;
    }
    return null;
}

/// Is `m` on any floating surface (toolbar, panel, popover, picker)?
pub fn onChrome(self: *const Editor, m: Point) bool {
    if (self.mouse_pane != self.tb_pane) return false;
    for ([_]Rect{ self.toolbar_rect, self.panel_rect, self.pop_rect }) |r| {
        if (!r.isEmpty() and r.contains(m.x, m.y)) return true;
    }
    return self.picker.open and self.picker.rect.contains(m.x, m.y);
}

pub fn popoverContains(self: *const Editor, m: Point) bool {
    return self.popover != .none and self.mouse_pane == self.tb_pane and self.pop_rect.contains(m.x, m.y);
}

/// Thickness for a pointer at `m` on the size slider.
pub fn sliderValue(self: *const Editor, m: Point) i32 {
    for (self.buttons.items) |b| {
        if (b.kind != .thickness) continue;
        const knob = self.sc(9);
        const t = std.math.clamp(ff(m.x - b.rect.x - knob) / ff(@max(1, b.rect.w - 2 * knob)), 0, 1);
        return @intFromFloat(@round(1 + t * 31));
    }
    return self.thickness;
}

/// Are animations running that need more frames?
pub fn animating(self: *const Editor) bool {
    const t = motion.now();
    if (self.toolbar_rect.isEmpty()) return false;
    return self.tb_x.busy(t) or self.tb_y.busy(t) or self.tb_alpha.busy(t) or self.act_x.busy(t) or
        self.act_y.busy(t) or self.hov.busy(t) or (self.popover != .none and self.pop_open.busy(t)) or pop_fade.busy(self);
}

/// Hover highlight strength of button `bi` (fades in and out).
pub fn hoverAmount(self: *const Editor, bi: usize) f64 {
    const t = motion.now();
    const k = self.hov.at(t);
    if (self.hover_btn >= 0 and bi == @as(usize, @intCast(self.hover_btn))) return k;
    if (self.hover_prev >= 0 and bi == @as(usize, @intCast(self.hover_prev))) return 1 - k;
    return 0;
}
