//! The keyboard shortcuts overlay (? or F1 in the editor).

const std = @import("std");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const ui = @import("editor_ui.zig");
const Editor = @import("editor.zig").Editor;
const Canvas = render.Canvas;
const Rect = @import("shapes.zig").Rect;

const help_lines = [_][2][]const u8{
    .{ "Drag", "Select a region; drag inside to move it" },
    .{ "Shift / Alt + drag", "Square, circle, 45\u{00B0} lines; from the centre" },
    .{ "Space + drag", "Move the region or shape while drawing it" },
    .{ "Arrows / Shift", "Move selection or shape by 1 / 10 px" },
    .{ "Alt+Arrows", "Resize the selection" },
    .{ "V P L A R E M", "Select, pen, line, arrow, rect, ellipse, marker" },
    .{ "X (again)", "Blur, then pixelate, then solid redaction" },
    .{ "N  T", "Counter badge, text" },
    .{ "S  U", "Spotlight (dims the rest); ruler (snaps to edges, Alt: free)" },
    .{ "I", "Colour picker: click copies #RRGGBB, Shift rgb(), Alt uses it" },
    .{ "C", "Crop the picture: 1:1, 16:9, 4:3; Enter applies, Esc cancels" },
    .{ "Ctrl+Shift+C / R", "Copy the text (OCR); redact sensitive data" },
    .{ "Ctrl+P", "Pin to the screen" },
    .{ "F", "Fill / rounded corners / text background" },
    .{ "1-8, 9", "Preset colours, custom colour" },
    .{ "Scroll, - =", "Stroke and text size" },
    .{ "Click / double-click", "Select a shape (select tool) / edit text" },
    .{ "Delete", "Delete selected shape" },
    .{ "Ctrl+D  Ctrl+]", "Duplicate, bring to front" },
    .{ "Ctrl+Z / Ctrl+Shift+Z, Ctrl+Y", "Undo / redo" },
    .{ "Text: Enter", "New line; Ctrl+Enter, Esc or click outside ends" },
    .{ "Text: Shift+arrows, Ctrl+A", "Select text; Ctrl+C/X/V copy, cut, paste" },
    .{ "Text: side handle, Alt+W", "Drag to wrap at a width; double-click / Alt+W: fit text" },
    .{ "B", "Beautify frame (padding, background, shadow)" },
    .{ "Tab / Shift+Tab", "Move focus on the toolbar; Enter activates" },
    .{ "Enter  Ctrl+C", "Copy to clipboard and close" },
    .{ "Ctrl+S  Ctrl+Shift+S", "Save, save as" },
    .{ "Right click / Esc", "Cancel current action; Esc again closes" },
};

pub fn rect(self: *const Editor) Rect {
    const fs = theme.font_label * self.uf();
    const lh = text_mod.height(fs) + self.sc(7);
    const pw = self.sc(620);
    const ph = lh * @as(i32, help_lines.len) + self.sc(76);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    return .{ .x = @divTrunc(w - pw, 2), .y = @max(4, @divTrunc(h - ph, 2)), .w = pw, .h = ph };
}

pub fn draw(self: *Editor, canvas: *Canvas) void {
    const r = rect(self);
    const f = self.uf();
    const th = self.theme;
    ui.drawMaterial(self, canvas, .help, r, theme.popover_radius * f, th.popover_shadow);
    const fs = theme.font_label * f;
    const lh = text_mod.height(fs) + self.sc(7);
    const pad = self.sc(24);
    icons.draw(canvas, .keyboard, r.x + pad, r.y + self.sc(20), self.sc(18), th.fg);
    text_mod.drawStyled(canvas, r.x + pad + self.sc(26), r.y + self.sc(20) + @divTrunc(self.sc(18) - text_mod.heightStyled(15 * f, .bold), 2), 15.0 * f, th.fg, .bold, "Keyboard shortcuts");
    var y = r.y + self.sc(58);
    const ks = theme.font_small * f;
    for (help_lines) |l| {
        // the keys as a cap, the meaning beside it
        const kw = text_mod.width(ks, l[0]) + self.sc(12);
        canvas.fillRoundRectAA(r.x + pad, y + @divTrunc(lh - self.sc(20), 2) - self.sc(1), kw, self.sc(20), 5 * f, th.track);
        text_mod.draw(canvas, r.x + pad + self.sc(6), y + @divTrunc(lh - text_mod.height(ks), 2) - self.sc(1), ks, th.fg, l[0]);
        text_mod.draw(canvas, r.x + pad + self.sc(232), y + @divTrunc(lh - text_mod.height(fs), 2) - self.sc(1), fs, th.muted, l[1]);
        y += lh;
    }
}
