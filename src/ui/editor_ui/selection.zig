//! The editor's selection chrome (ui/selchrome.zig draws it): which
//! handles show, the size pill's text and place, and the first-run hint.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const selchrome = @import("../selchrome.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;

fn dimsLabel(self: *const Editor, buf: []u8) []const u8 {
    const s = self.doc.sel.?.normalized();
    if (!self.beautify.enabled) return selchrome.sizeLabel(buf, s.w, s.h);
    const x = if (text_mod.available()) "\u{00D7}" else "x";
    const g = self.beautify.geometry(@intCast(@max(1, s.w)), @intCast(@max(1, s.h)));
    return std.fmt.bufPrint(buf, "{d} {s} {d}  \u{2192}  {d} {s} {d}", .{ s.w, x, s.h, g.out_w, x, g.out_h }) catch "?";
}

pub fn dimsPillRect(self: *const Editor, s: Rect) Rect {
    var buf: [64]u8 = undefined;
    return selchrome.sizePillRect(dimsLabel(self, &buf), self.frameRect(s), @intCast(self.pn().width), self.uf());
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
    // above the mode strip, where that shows
    const strip = self.capmode.rect;
    if (self.isTbPane() and !strip.isEmpty())
        return .{ .x = strip.x + @divTrunc(strip.w - tw, 2) - self.sc(16), .y = strip.y - ph - self.sc(12), .w = tw + self.sc(32), .h = ph };
    return .{ .x = @divTrunc(w - tw, 2) - self.sc(16), .y = h - ph - self.sc(48), .w = tw + self.sc(32), .h = ph };
}

/// The pointer, on the pane it is over (null elsewhere).
fn mouseHere(self: *const Editor) ?shapes_mod.Point {
    return if (self.isMousePane()) self.mouse else null;
}

/// Index of the mid-edge handle the pointer is near, for repaints.
pub fn hoverHandle(self: *const Editor) i8 {
    const s = self.selBuf() orelse return -1;
    for (0..8) |i| {
        if (i % 2 == 1 and selchrome.handleShown(s, i, mouseHere(self), self.handleRadius())) return @intCast(i);
    }
    return -1;
}

pub fn drawSelectionChrome(self: *Editor, canvas: *Canvas) void {
    const f = self.uf();
    const th = self.theme;
    if (self.selBuf()) |s| {
        selchrome.edge(canvas, s, th);
        if (self.tool == .select and self.drag == .none and self.selected == null and self.tools.mode == .none)
            selchrome.handles(canvas, s, mouseHere(self), self.handleRadius(), f, th);
        // one size label, on the monitor with the toolbar (the one the
        // pointer is on, else the one showing most of the selection)
        if (self.isTbPane()) {
            var buf: [64]u8 = undefined;
            selchrome.sizePill(canvas, dimsPillRect(self, s), f, th, dimsLabel(self, &buf));
        }
    }
    if (self.show_hint) {
        // first run only: a quiet pill, gone at the first click or key
        self.hint_seen = true;
        const r = hintRect(self);
        selchrome.pill(canvas, r, ff(r.h) / 2.0, th);
        text_mod.draw(canvas, r.x + self.sc(16), r.y + self.sc(7), theme.font_label * f, th.pill_fg, hintText());
    }
}
