//! Layout of the "Recent captures" panel in logical pixels, relative to
//! the panel's top-left: header, search field, the two-column grid and
//! the action bar of the picked capture.

const shapes = @import("../../ui/shapes.zig");
const fui = @import("../../ui/floatui.zig");
const Panel = @import("panel.zig").Panel;
const Rect = shapes.Rect;

// layout, logical pixels (the mockup's panel)
pub const panel_w = 300;
pub const pad = 18; // shadow room around the panel
pub const inset = 14;
pub const header_h = 20;
pub const field_h = 32;
pub const col_gap = 10;
pub const thumb_h = 82;
pub const label_h = 18;
pub const row_gap = 10;
pub const actions_h = 40;
pub const footer_button_h = 28;
pub const max_panel_h = 620;

pub const Action = enum { copy, save, annotate, pin, delete };
pub const action_icons = [_]fui.Icon{ .copy, .save, .pencil, .pin, .trash };
pub const action_names = [_][]const u8{ "Copy", "Save", "Annotate", "Pin", "Delete" };

pub fn searchTop(self: *const Panel) i32 {
    _ = self;
    return inset + header_h + 10;
}

pub fn gridTop(self: *const Panel) i32 {
    return self.searchTop() + if (self.searchable) @as(i32, field_h + 12) else 0;
}

pub fn colW() i32 {
    return @divTrunc(panel_w - 2 * inset - col_gap, 2);
}

pub fn itemH() i32 {
    return thumb_h + 6 + label_h;
}

pub fn contentH(self: *const Panel) i32 {
    const rows: i32 = @intCast((self.shown.items.len + 1) / 2);
    return @max(60, rows * itemH() + @max(0, rows - 1) * row_gap);
}

pub fn panelH(self: *const Panel) i32 {
    const h = self.gridTop() + self.contentH() + inset + actions_h;
    return @min(h, max_panel_h);
}

pub fn gridViewH(self: *const Panel) i32 {
    return self.panelH() - self.gridTop() - inset - actions_h;
}

/// Item n of `shown` (grid order), in panel coordinates (scrolled).
pub fn itemRect(self: *const Panel, n: usize) Rect {
    const col: i32 = @intCast(n % 2);
    const row: i32 = @intCast(n / 2);
    return .{ .x = inset + col * (colW() + col_gap), .y = self.gridTop() + row * (itemH() + row_gap) - self.scroll, .w = colW(), .h = itemH() };
}

pub fn actionRect(self: *const Panel, i: usize) Rect {
    const w = @divTrunc(panel_w - 2 * inset, @as(i32, action_names.len));
    return .{ .x = inset + @as(i32, @intCast(i)) * w, .y = self.panelH() - actions_h - 4, .w = w, .h = actions_h };
}

/// "Clear history…" in the footer while nothing is picked: away from the
/// close button, and only ever a first step (see confirmRect).
pub fn clearRect(self: *const Panel) Rect {
    const w = 120;
    return .{ .x = @divTrunc(panel_w - w, 2), .y = self.panelH() - actions_h + 4, .w = w, .h = footer_button_h };
}

/// Clearing asks first: the footer turns into "Clear N captures?" with
/// Cancel and a destructive Clear.
pub const Confirm = enum { cancel, clear };

pub fn confirmRect(self: *const Panel, c: Confirm) Rect {
    const y = self.panelH() - actions_h + 4;
    const clear: Rect = .{ .x = panel_w - inset - 60, .y = y, .w = 60, .h = footer_button_h };
    return switch (c) {
        .clear => clear,
        .cancel => .{ .x = clear.x - 8 - 64, .y = y, .w = 64, .h = footer_button_h },
    };
}

pub fn closeRect(self: *const Panel) Rect {
    _ = self;
    return .{ .x = panel_w - inset - 22, .y = inset - 1, .w = 22, .h = 22 };
}

/// Size the window to the panel plus its shadow; only the panel takes input.
pub fn resize(self: *Panel) !void {
    const w: u32 = panel_w + 2 * pad;
    const h: u32 = @intCast(self.panelH() + 2 * pad);
    try self.win.resizeTo(0, w, h);
    try self.win.setWindowGeometry(0, .{ .x = pad, .y = pad, .w = panel_w, .h = @intCast(h - 2 * pad) });
    try self.win.setInputRegion(0, &.{.{ .x = pad, .y = pad, .w = panel_w, .h = @intCast(h - 2 * pad) }});
}
