//! Footprints: every rectangle the chrome may paint, so the editor
//! repaints only those (must cover everything drawChrome draws).

const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const tools = @import("../tools/mod.zig");
const help = @import("../help.zig");
const pop_fade = @import("pop_fade.zig");
const material = @import("material.zig");
const draw_chrome = @import("draw_chrome.zig");
const selection = @import("selection.zig");
const loupe = @import("loupe.zig");
const loupe_hint = @import("loupe_hint.zig");
const tooltip = @import("tooltip.zig");
const notice = @import("notice.zig");
const strip = @import("strip.zig");
const winpick = @import("../editor/winpick.zig");

const Editor = editor_mod.Editor;
const RectList = editor_mod.RectList;
const Rect = shapes_mod.Rect;

fn addOutline(list: *RectList, r: Rect, pad: i32) void {
    list.add(.{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.bottom() - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
    list.add(.{ .x = r.right() - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
}

fn chromePad(self: *const Editor) i32 {
    return @as(i32, @intFromFloat(@ceil(draw_chrome.handleDrawRadius(self) + 3.0 * self.uf()))) + 3;
}

pub fn collectOverlays(self: *Editor, list: *RectList) void {
    list.add(self.liveBounds());
    if (self.text) |t| {
        const f = self.pn().view.rectToBuf(self.doc.shapes.items[t.idx].frame()).expand(self.sc(3));
        addOutline(list, f, 2);
        if (self.isMousePane()) if (draw_chrome.preeditRect(self)) |r| list.add(r.expand(2));
    }
    if (self.selected) |i| {
        if (draw_chrome.shapeChromeRect(self, i)) |r| addOutline(list, r, chromePad(self));
    }
    if (self.textHandleShape()) |i| list.add(draw_chrome.textHandleRect(self, i).expand(2));
    if (self.selBuf()) |s| {
        addOutline(list, s, chromePad(self));
        const pill = selection.dimsPillRect(self, s);
        list.add(pill.expand(1));
        if (loupe_hint.rect(self, pill)) |r| list.add(r.expand(1));
    }
    if (self.show_hint) list.add(selection.hintRect(self).expand(1));
    if (winpick.footprint(self)) |r| addOutline(list, r, chromePad(self));
    if (loupe.footprint(self)) |r| list.add(r);
    if (!self.isTbPane()) return;
    collectFloating(self, list);
    tools.collectOverlays(self, list);
}

/// The floating surfaces on the toolbar's pane, with their shadows.
fn collectFloating(self: *Editor, list: *RectList) void {
    const th = self.theme;
    const foot = material.shadowFootprint;
    if (!self.toolbar_rect.isEmpty()) list.add(foot(self, self.toolbar_rect.expand(self.sc(1)), th.bar_shadow));
    if (strip.footprint(self)) |r| list.add(r);
    if (!self.panel_rect.isEmpty()) list.add(foot(self, self.panel_rect.expand(self.sc(1)), th.bar_shadow));
    if (!self.pop_rect.isEmpty()) list.add(foot(self, self.pop_rect.expand(self.sc(1)), th.popover_shadow));
    if (!pop_fade.rect(self).isEmpty()) list.add(pop_fade.rect(self));
    if (tooltip.tooltipRect(self)) |r| list.add(r.expand(self.sc(6)));
    if (self.picker.open and !self.toolbar_rect.isEmpty()) list.add(foot(self, self.picker.rect.expand(self.sc(1)), th.popover_shadow));
    if (self.copy_notice != .none) list.add(foot(self, notice.noticeRect(self), th.bar_shadow));
    if (self.help_open) list.add(foot(self, help.rect(self), th.popover_shadow));
}
