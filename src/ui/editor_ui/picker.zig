//! The custom colour picker: a saturation/value square, a hue strip and
//! a hex field, floating beside the popover.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const theme = @import("../theme.zig");
const hsv_mod = @import("../hsv.zig");
const material = @import("material.zig");
const ff = @import("common.zig").ff;

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

pub const hsvToRgb = hsv_mod.hsvToRgb;
pub const rgbToHsv = hsv_mod.rgbToHsv;

pub const PickPart = enum { sv, hue };

pub const Picker = struct {
    open: bool = false,
    rect: Rect = Rect.empty,
    h: f64 = 190,
    s: f64 = 0.9,
    v: f64 = 0.75,
    hex: [6]u8 = "15AABF".*,
    hex_len: u8 = 6,
};

pub fn layoutPicker(self: *Editor) void {
    const anchor = if (!self.pop_rect.isEmpty()) self.pop_rect else self.toolbar_rect;
    const pw = self.sc(220);
    const ph = self.sc(216);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const m = self.sc(8);
    // beside the popover, else above or below the toolbar
    var x = anchor.right() + m;
    var y = anchor.bottom() - ph;
    if (x + pw > w - 4) x = anchor.x - pw - m;
    if (x < 4) {
        x = std.math.clamp(anchor.x + @divTrunc(anchor.w - pw, 2), 4, @max(4, w - pw - 4));
        y = self.toolbar_rect.y - ph - m;
        if (y < 4) y = self.toolbar_rect.bottom() + m;
    }
    y = std.math.clamp(y, 4, @max(4, h - ph - 4));
    self.picker.rect = .{ .x = x, .y = y, .w = pw, .h = ph };
}

fn svRect(self: *const Editor) Rect {
    const p = self.picker.rect;
    return .{ .x = p.x + self.sc(12), .y = p.y + self.sc(12), .w = self.sc(160), .h = self.sc(160) };
}

fn hueRect(self: *const Editor) Rect {
    const sv = svRect(self);
    return .{ .x = sv.right() + self.sc(12), .y = sv.y, .w = self.sc(24), .h = sv.h };
}

pub fn pickPartAt(self: *const Editor, m: Point) ?PickPart {
    if (svRect(self).expand(3).contains(m.x, m.y)) return .sv;
    if (hueRect(self).expand(3).contains(m.x, m.y)) return .hue;
    return null;
}

pub fn pickAt(self: *Editor, part: PickPart, m: Point) void {
    switch (part) {
        .sv => {
            const r = svRect(self);
            self.picker.s = std.math.clamp(ff(m.x - r.x) / ff(r.w), 0, 1);
            self.picker.v = 1.0 - std.math.clamp(ff(m.y - r.y) / ff(r.h), 0, 1);
        },
        .hue => {
            const r = hueRect(self);
            self.picker.h = 359.9 * std.math.clamp(ff(m.y - r.y) / ff(r.h), 0, 1);
        },
    }
    setHex(self, pickerColor(self));
    self.needs_render = true;
}

fn setHex(self: *Editor, c: u32) void {
    _ = std.fmt.bufPrint(&self.picker.hex, "{X:0>6}", .{c & 0xFFFFFF}) catch {};
    self.picker.hex_len = 6;
}

pub fn pickerColor(self: *const Editor) u32 {
    return hsvToRgb(self.picker.h, self.picker.s, self.picker.v);
}

pub fn pickerFrom(self: *Editor, c: u32) void {
    const hsv = rgbToHsv(c);
    self.picker.h = hsv[0];
    self.picker.s = hsv[1];
    self.picker.v = hsv[2];
    setHex(self, c);
    layoutPicker(self);
}

/// Hex entry while the picker is open. null: not a picker key; true: the
/// colour changed; false: consumed without a colour change.
pub fn pickerKey(self: *Editor, k: window.Key) ?bool {
    if (k.ctrl or k.alt) return null;
    switch (k.code) {
        .escape, .enter => {
            self.picker.open = false;
            return false;
        },
        .backspace => {
            if (self.picker.hex_len > 0) self.picker.hex_len -= 1;
            return false;
        },
        else => {},
    }
    const t = k.text();
    if (t.len != 1) return null;
    if (t[0] == '#') return false;
    _ = std.fmt.charToDigit(t[0], 16) catch return null;
    if (self.picker.hex_len >= 6) self.picker.hex_len = 0;
    self.picker.hex[self.picker.hex_len] = std.ascii.toUpper(t[0]);
    self.picker.hex_len += 1;
    if (self.picker.hex_len < 6) return false;
    const v = std.fmt.parseInt(u32, &self.picker.hex, 16) catch return false;
    const hsv = rgbToHsv(0xFF000000 | v);
    self.picker.h = hsv[0];
    self.picker.s = hsv[1];
    self.picker.v = hsv[2];
    return true;
}

pub fn drawPicker(self: *Editor, canvas: *Canvas) void {
    const p = self.picker.rect;
    const th = self.theme;
    material.drawMaterial(self, canvas, .picker, p, theme.popover_radius * self.uf(), th.popover_shadow);
    const sv = svRect(self);
    const hr = hueRect(self);
    drawSvSquare(self, canvas, sv);
    shapes_mod.roundRectRing(canvas, sv, 2, 1, th.hairline);
    drawHueStrip(canvas, hr);
    drawMarkers(self, canvas, sv, hr);
    drawHexField(self, canvas, sv);
}

/// Saturation left to right, value top to bottom, at the current hue.
fn drawSvSquare(self: *const Editor, canvas: *Canvas, sv: Rect) void {
    var y: i32 = 0;
    while (y < sv.h) : (y += 1) {
        const v = 1.0 - ff(y) / ff(sv.h - 1);
        var x: i32 = 0;
        while (x < sv.w) : (x += 1) {
            const s = ff(x) / ff(sv.w - 1);
            canvas.set(sv.x + x, sv.y + y, hsvToRgb(self.picker.h, s, v));
        }
    }
}

fn drawHueStrip(canvas: *Canvas, hr: Rect) void {
    var y: i32 = 0;
    while (y < hr.h) : (y += 1) {
        const hue = 359.9 * ff(y) / ff(hr.h - 1);
        canvas.fillRect(hr.x, hr.y + y, hr.w, 1, hsvToRgb(hue, 1, 1));
    }
}

/// A ring on the chosen saturation and value, a bar on the chosen hue.
fn drawMarkers(self: *const Editor, canvas: *Canvas, sv: Rect, hr: Rect) void {
    const f = self.uf();
    const mx: f64 = ff(sv.x) + self.picker.s * ff(sv.w);
    const my: f64 = ff(sv.y) + (1.0 - self.picker.v) * ff(sv.h);
    canvas.ringAA(mx, my, 7.5 * f, 1.0 * f, 0x66000000);
    canvas.ringAA(mx, my, 6.0 * f, 2.0 * f, 0xFFFFFFFF);
    const hy: i32 = hr.y + @as(i32, @intFromFloat(self.picker.h / 360.0 * ff(hr.h)));
    canvas.fillRoundRectAA(hr.x - self.sc(2), hy - self.sc(3), hr.w + self.sc(4), self.sc(6), 3 * f, 0x66000000);
    canvas.fillRoundRectAA(hr.x - self.sc(1), hy - self.sc(2), hr.w + self.sc(2), self.sc(4), 2 * f, 0xFFFFFFFF);
}

/// The colour preview and the hex being typed, with its caret.
fn drawHexField(self: *const Editor, canvas: *Canvas, sv: Rect) void {
    const p = self.picker.rect;
    const f = self.uf();
    const th = self.theme;
    const fy = sv.bottom() + self.sc(10);
    const fh = self.sc(24);
    canvas.fillRoundRectAA(sv.x, fy, fh, fh, 6.0 * f, pickerColor(self));
    canvas.fillRoundRectAA(sv.x + fh + self.sc(8), fy, p.right() - self.sc(12) - (sv.x + fh + self.sc(8)), fh, 6.0 * f, th.track);
    var buf: [16]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{s}", .{self.picker.hex[0..self.picker.hex_len]}) catch "#";
    const fs = theme.font_label * f;
    const tx = sv.x + fh + self.sc(16);
    const ty = fy + @divTrunc(fh - text_mod.height(fs), 2);
    text_mod.draw(canvas, tx, ty, fs, th.fg, label);
    canvas.fillRect(tx + text_mod.width(fs, label) + 1, ty, @max(1, self.sc(1)), text_mod.height(fs), th.accent);
}
