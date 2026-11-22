//! The controls of every floating bar (the editor's toolbar, its beautify
//! and crop bars, the record picker's bar), drawn one way: square or
//! text buttons on the bar's material, a separator between groups, and
//! one prominent button that does the bar's job (Copy, Crop, Record).
//! Sizes are the theme's metrics (ui/theme.zig) times the scale `f`.
//!
//! Stable API:
//!   Look                             how a button shows its state
//!   fill(canvas, r, f, th, look, hover)   its background
//!   ink(th, look, disabled)               its icon or label colour
//!   Lead, primaryWidth(f, label), primary(canvas, r, f, colours, lead, label)
//!   separator(canvas, x, y, h, th)

const std = @import("std");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const Rect = @import("shapes.zig").Rect;

const Canvas = render.Canvas;
const Theme = theme.Theme;

pub const Look = enum {
    /// nothing to show but hover
    plain,
    /// held down: its popover or menu is open, or its segment is chosen
    pressed,
    /// an option that is on (Shadow, Microphone, 16:9): pressed, accent ink
    toggled,
    /// the active tool: the accent itself
    selected,
};

/// The background of a button in `look`, `hover` (0..1) over it.
pub fn fill(cv: *Canvas, r: Rect, f: f64, th: Theme, look: Look, hover: f64) void {
    const rad = theme.button_radius * f;
    switch (look) {
        .selected => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.accent_fill),
        .pressed, .toggled => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.pressed),
        .plain => {},
    }
    if (hover > 0 and look != .selected) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hover));
}

/// The colour of a button's icon or label.
pub fn ink(th: Theme, look: Look, disabled: bool) u32 {
    if (disabled) return th.muted;
    return switch (look) {
        .selected => th.on_accent,
        .toggled => th.accent_text,
        .plain, .pressed => th.fg,
    };
}

/// What leads a prominent button's label.
pub const Lead = union(enum) {
    icon: icons.Icon,
    /// a filled dot (Record)
    dot,
};

const lead_px = 16;

/// The width of a prominent button with `label`.
pub fn primaryWidth(f: f64, label: []const u8) i32 {
    return sc(10 + lead_px + 6, f) + text.widthStyled(theme.font_label * f, .semibold, label) + sc(14, f);
}

/// The prominent button: `bg` filled, `lead` and a bold `label` in `fg`.
pub fn primary(cv: *Canvas, r: Rect, f: f64, bg: u32, fg: u32, lead: Lead, label: []const u8) void {
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, theme.button_radius * f, bg);
    const is = sc(lead_px, f);
    const lx = r.x + sc(10, f);
    switch (lead) {
        .icon => |ic| icons.draw(cv, ic, lx, r.y + @divTrunc(r.h - is, 2), is, fg),
        .dot => {
            const rr = 5 * f;
            cv.fillCircleAA(@as(f64, @floatFromInt(lx)) + @as(f64, @floatFromInt(is)) / 2, @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2, rr, fg);
        },
    }
    const fs = theme.font_label * f;
    text.drawStyled(cv, lx + is + sc(6, f), r.y + @divTrunc(r.h - text.heightStyled(fs, .semibold), 2), fs, fg, .semibold, label);
}

/// A group separator 1 px wide at x, from y, `h` tall.
pub fn separator(cv: *Canvas, x: i32, y: i32, h: i32, th: Theme) void {
    cv.fillRect(x, y, 1, h, th.hairline);
}

fn sc(v: f64, f: f64) i32 {
    return @intFromFloat(@round(v * f));
}

test "a prominent button fits its label and the inks read on their fills" {
    const th = Theme.get(false, null);
    try std.testing.expect(primaryWidth(1, "Record") > primaryWidth(1, "Crop"));
    try std.testing.expectEqual(th.on_accent, ink(th, .selected, false));
    try std.testing.expectEqual(th.accent_text, ink(th, .toggled, false));
    try std.testing.expectEqual(th.muted, ink(th, .toggled, true));
}
