//! The selection's chrome: its edge, resize handles, the size pill, and
//! the first-run hint.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const draw_chrome = @import("draw_chrome.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const handlePoints = shapes_mod.handlePoints;

fn dimsLabel(self: *const Editor, buf: []u8) []const u8 {
    const s = self.doc.sel.?.normalized();
    const x = if (text_mod.available()) "\u{00D7}" else "x";
    if (self.beautify.enabled) {
        const g = self.beautify.geometry(@intCast(@max(1, s.w)), @intCast(@max(1, s.h)));
        return std.fmt.bufPrint(buf, "{d} {s} {d}  \u{2192}  {d} {s} {d}", .{ s.w, x, s.h, g.out_w, x, g.out_h }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ s.w, x, s.h }) catch "?";
}

pub fn dimsPillRect(self: *const Editor, s: Rect) Rect {
    var buf: [64]u8 = undefined;
    const label = dimsLabel(self, &buf);
    const w: i32 = @intCast(self.pn().width);
    const fs = theme.font_small * self.uf();
    const tw = text_mod.width(fs, label);
    const ph = text_mod.height(fs) + self.sc(8);
    const pw = tw + self.sc(20);
    const fr = self.frameRect(s);
    var lx = fr.x;
    var ly = fr.y - ph - self.sc(10);
    if (ly < 6) ly = fr.y + self.sc(10);
    if (lx + pw > w - 6) lx = w - pw - 6;
    if (lx < 6) lx = 6;
    return .{ .x = lx, .y = ly, .w = pw, .h = ph };
}

fn hintText() []const u8 {
    return if (text_mod.available())
        "Drag to select  \u{00B7}  Enter to copy  \u{00B7}  ? for shortcuts"
    else
        "Drag to select  -  Enter to copy  -  ? for shortcuts";
}

pub fn hintRect(self: *const Editor) Rect {
    const fs = theme.font_label * self.uf();
    const tw = text_mod.width(fs, hintText());
    const ph = text_mod.height(fs) + self.sc(14);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    return .{ .x = @divTrunc(w - tw, 2) - self.sc(16), .y = h - ph - self.sc(48), .w = tw + self.sc(32), .h = ph };
}

/// Which selection handles show: the corners always, an edge's middle
/// only while the pointer is near it.
fn showHandle(self: *const Editor, s: Rect, i: usize) bool {
    if (i % 2 == 0) return true;
    if (!self.isMousePane()) return false;
    const small = s.w < 4 * self.handleRadius() or s.h < 4 * self.handleRadius();
    if (small) return false;
    const p = handlePoints(s)[i];
    const reach = self.handleRadius() * 2;
    return @abs(self.mouse.x - p.x) <= reach and @abs(self.mouse.y - p.y) <= reach;
}

/// Index of the mid-edge handle the pointer is near, for repaints.
pub fn hoverHandle(self: *const Editor) i8 {
    const s = self.selBuf() orelse return -1;
    for (0..8) |i| {
        if (i % 2 == 1 and showHandle(self, s, i)) return @intCast(i);
    }
    return -1;
}

pub fn drawSelectionChrome(self: *Editor, canvas: *Canvas) void {
    const f = self.uf();
    const th = self.theme;
    if (self.selBuf()) |s| {
        // two tones: the light line shows on dark captures, the dark one
        // around it on light ones
        canvas.rectOutline(s.x - 2, s.y - 2, s.w + 4, s.h + 4, 1, th.sel_edge_outer);
        canvas.rectOutline(s.x - 1, s.y - 1, s.w + 2, s.h + 2, 1, th.sel_edge);
        if (self.tool == .select and self.drag == .none and self.selected == null and self.tools.mode == .none) {
            for (handlePoints(s), 0..) |p, i| {
                if (!showHandle(self, s, i)) continue;
                draw_chrome.drawHandle(self, canvas, ff(p.x), ff(p.y), draw_chrome.handleDrawRadius(self));
            }
        }
        // one size label, on the monitor with the toolbar (the one the
        // pointer is on, else the one showing most of the selection)
        if (self.isTbPane()) {
            var buf: [64]u8 = undefined;
            const label = dimsLabel(self, &buf);
            const r = dimsPillRect(self, s);
            draw_chrome.drawPill(self, canvas, r, 7.0 * f);
            text_mod.draw(canvas, r.x + self.sc(10), r.y + self.sc(4), theme.font_small * f, th.pill_fg, label);
        }
    }
    if (self.show_hint) {
        // first run only: a quiet pill, gone at the first click or key
        self.hint_seen = true;
        const r = hintRect(self);
        draw_chrome.drawPill(self, canvas, r, ff(r.h) / 2.0);
        text_mod.draw(canvas, r.x + self.sc(16), r.y + self.sc(7), theme.font_label * f, th.pill_fg, hintText());
    }
}
