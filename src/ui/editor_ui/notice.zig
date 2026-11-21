//! The copy notice: a pill in the corner saying the copy is under way,
//! done, or failed.

const text_mod = @import("../../gfx/text.zig");
const render = @import("../../gfx/render.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const material = @import("material.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;

fn noticeMessage(self: *const Editor) []const u8 {
    return switch (self.copy_notice) {
        .none => "",
        .copying => "Copying\u{2026}",
        .copied => "Copied to clipboard",
        .failed => "Copy failed",
    };
}

pub fn noticeRect(self: *const Editor) Rect {
    const window_width: i32 = @intCast(self.pn().width);
    const window_height: i32 = @intCast(self.pn().height);
    const fs = theme.font_label * self.uf();
    const mw = text_mod.width(fs, noticeMessage(self));
    const icon_size = self.sc(22);
    const margin = self.sc(24);
    var nw = icon_size + self.sc(10) + mw + self.sc(14) * 2;
    nw = @min(nw, @max(self.sc(160), window_width - margin * 2));
    const nh = self.sc(44);
    var nx = window_width - nw - margin;
    if (nx < margin) nx = @divTrunc(window_width - nw, 2);
    if (nx < margin) nx = margin;
    var ny = window_height - nh - margin;
    if (ny < margin) ny = margin;
    return .{ .x = nx, .y = ny, .w = nw, .h = nh };
}

pub fn drawCopyNotice(self: *Editor, canvas: *Canvas) void {
    const f = self.uf();
    const th = self.theme;
    const r = noticeRect(self);
    const message = noticeMessage(self);
    const fs = theme.font_label * f;
    const accent: u32 = switch (self.copy_notice) {
        .none => return,
        .copying, .copied => th.accent,
        .failed => th.destructive,
    };
    material.drawMaterial(self, canvas, .notice, r, ff(r.h) / 2.0, th.bar_shadow);
    const icon_size = self.sc(22);
    const cx = ff(r.x + self.sc(14) + @divTrunc(icon_size, 2));
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const is = self.sc(14);
    switch (self.copy_notice) {
        .none => {},
        .copying => canvas.ringAA(cx, cy, 9.0 * f, 2.0 * f, theme.withAlpha(accent, 0x80)),
        .copied, .failed => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, accent);
            const icon: icons.Icon = if (self.copy_notice == .copied) .check else .close;
            icons.drawStroke(canvas, icon, @as(i32, @intFromFloat(cx)) - @divTrunc(is, 2), @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2), is, 3, 0xFFFFFFFF);
        },
    }
    text_mod.draw(canvas, r.x + self.sc(14) + icon_size + self.sc(10), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, th.fg, message);
}
