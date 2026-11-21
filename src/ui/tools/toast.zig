//! The tools' toast: a small Glass pill at the bottom of the screen
//! ("#FF453A copied", "Copied: first line of the text", how to install
//! Tesseract), gone after a few seconds.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const ui = @import("../editor_ui.zig");
const editor_mod = @import("../editor.zig");
const floatui = @import("../floatui.zig");

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = @import("../shapes.zig").Rect;

pub const Kind = enum { info, done, busy, problem };

pub const Toast = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,
    kind: Kind = .info,
    /// a colour swatch before the text (the colour picker)
    swatch: ?u32 = null,
    /// hidden at (monotonic ms); 0 while busy (until replaced)
    until_ms: i64 = 0,

    pub fn visible(self: *const Toast) bool {
        return self.len > 0;
    }

    pub fn text(self: *const Toast) []const u8 {
        return self.buf[0..self.len];
    }

    /// Show `msg` for `ms` (0: until the next show or hide).
    pub fn show(self: *Toast, kind: Kind, msg: []const u8, ms: i64) void {
        var eb: [240]u8 = undefined;
        const fit = floatui.ellipsize(&eb, 15, msg, 900);
        self.len = @min(fit.len, self.buf.len);
        @memcpy(self.buf[0..self.len], fit[0..self.len]);
        self.kind = kind;
        self.swatch = null;
        self.until_ms = if (ms > 0) now() + ms else 0;
    }

    pub fn hide(self: *Toast) void {
        self.len = 0;
    }

    /// Hide when due; how long until then (ms), for the event wait.
    pub fn tick(self: *Toast, t: i64) ?i64 {
        if (self.len == 0 or self.until_ms == 0) return null;
        if (t >= self.until_ms) {
            self.len = 0;
            return 0;
        }
        return self.until_ms - t;
    }
};

fn now() i64 {
    return @import("../../platform/sys.zig").monoMs();
}

const icon_box = 22;

pub fn rect(ed: *const Editor) ?Rect {
    const t = &ed.tools.toast;
    if (!t.visible() or !ed.isTbPane()) return null;
    const fs = theme.font_label * ed.uf();
    const w: i32 = @intCast(ed.pn().width);
    const h: i32 = @intCast(ed.pn().height);
    const tw = @min(text_mod.width(fs, t.text()), w - ed.sc(120));
    const pw = ed.sc(14) + ed.sc(icon_box) + ed.sc(10) + tw + ed.sc(18);
    const ph = ed.sc(44);
    const low: Rect = .{ .x = @divTrunc(w - pw, 2), .y = h - ph - ed.sc(28), .w = pw, .h = ph };
    // at the top when the toolbar (or what it opened) is down there
    for ([_]Rect{ ed.toolbar_rect, ed.panel_rect, ed.pop_rect }) |c| {
        if (!c.isEmpty() and Rect.intersect(c.expand(ed.sc(12)), low) != null) return .{ .x = low.x, .y = ed.sc(28), .w = pw, .h = ph };
    }
    return low;
}

pub fn footprint(ed: *const Editor) ?Rect {
    const r = rect(ed) orelse return null;
    return ui.shadowFootprint(ed, r, ed.theme.bar_shadow);
}

pub fn draw(ed: *Editor, canvas: *Canvas) void {
    const r = rect(ed) orelse return;
    const t = &ed.tools.toast;
    const f = ed.uf();
    const th = ed.theme;
    ui.drawMaterial(ed, canvas, .notice, r, @as(f64, @floatFromInt(r.h)) / 2.0, th.bar_shadow);
    const cx: f64 = @floatFromInt(r.x + ed.sc(14) + @divTrunc(ed.sc(icon_box), 2));
    const cy = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2.0;
    drawBadge(ed, canvas, t, cx, cy, f);
    const fs = theme.font_label * f;
    const tx = r.x + ed.sc(14) + ed.sc(icon_box) + ed.sc(10);
    text_mod.draw(canvas, tx, r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, th.fg, t.text());
}

fn drawBadge(ed: *Editor, canvas: *Canvas, t: *const Toast, cx: f64, cy: f64, f: f64) void {
    const th = ed.theme;
    const is = ed.sc(14);
    const ix: i32 = @as(i32, @intFromFloat(cx)) - @divTrunc(is, 2);
    const iy: i32 = @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2);
    if (t.swatch) |c| {
        canvas.fillCircleAA(cx, cy, 10.0 * f, c | 0xFF000000);
        canvas.ringAA(cx, cy, 10.0 * f, 1.0 * f, 0x59808080);
        return;
    }
    switch (t.kind) {
        .busy => canvas.ringAA(cx, cy, 9.0 * f, 2.0 * f, theme.withAlpha(th.accent, 0x80)),
        .done => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, th.accent);
            icons.drawStroke(canvas, .check, ix, iy, is, 3, 0xFFFFFFFF);
        },
        .problem => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, th.destructive);
            icons.drawStroke(canvas, .close, ix, iy, is, 3, 0xFFFFFFFF);
        },
        .info => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, th.accent);
            text_mod.drawStyled(canvas, ix + @divTrunc(is - text_mod.widthStyled(13 * f, .bold, "i"), 2), iy + @divTrunc(is - text_mod.heightStyled(13 * f, .bold), 2), 13 * f, 0xFFFFFFFF, .bold, "i");
        },
    }
}
