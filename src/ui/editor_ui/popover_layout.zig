//! Popover layout: the colour and size popover (swatches, size slider,
//! segmented style controls) and the More menu, next to the toolbar.

const std = @import("std");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const tools = @import("../tools/mod.zig");
const tui = @import("../tools/tui.zig");
const buttons = @import("buttons.zig");

const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const ButtonKind = buttons.ButtonKind;
const Seg = buttons.Seg;

/// Up to two rows of up to three segments.
const SegRows = [2][3]?Seg;

fn anchorButton(self: *const Editor, kind: std.meta.Tag(ButtonKind)) ?Rect {
    for (self.buttons.items) |b| if (b.kind == kind and b.layer == .bar) return b.rect;
    return null;
}

/// Segments shown for the target tool: up to two rows.
fn segRows(self: *const Editor, out: *SegRows) usize {
    out.* = @splat(@splat(null));
    var n: usize = 0;
    switch (buttons.targetTool(self)) {
        .rect => {
            out[n] = .{ .outline, .filled, .rounded };
            n += 1;
        },
        .ellipse => {
            out[n] = .{ .outline, .filled, null };
            n += 1;
        },
        .text => {
            out[n] = .{ .plain, .pill, null };
            n += 1;
        },
        .blur, .pixelate, .redact => {
            out[n] = .{ .mode_blur, .mode_pixelate, .mode_solid };
            n += 1;
        },
        else => |t| n += tools.segRows(self, t, out[n..]),
    }
    if (self.textHandleShape() != null) {
        out[n] = .{ .width_fit, .width_fixed, null };
        n += 1;
    }
    return n;
}

pub const menu_items = [_]ButtonKind{ .{ .ext = .copy_text }, .{ .ext = .redact_sensitive }, .{ .ext = .pin }, .beautify, .save_as, .help, .cancel };

pub fn layoutPopover(self: *Editor) !void {
    const tb = self.toolbar_rect;
    const anchor: Rect = switch (self.popover) {
        .none => return,
        .colors => anchorButton(self, .colors) orelse tb,
        .more => anchorButton(self, .more) orelse tb,
    };
    var segs: SegRows = undefined;
    const n_seg_rows = segRows(self, &segs);
    const pw: i32, const ph: i32 = switch (self.popover) {
        .none => return,
        .colors => colorsSize(self, n_seg_rows),
        .more => menuSize(self),
    };
    self.pop_rect = placePopover(self, anchor, pw, ph);
    switch (self.popover) {
        .none => {},
        .colors => try layoutColors(self, segs[0..n_seg_rows]),
        .more => try layoutMenu(self),
    }
}

fn colorsSize(self: *const Editor, n_seg_rows: usize) [2]i32 {
    const pad = self.sc(theme.popover_pad);
    const sw = self.sc(28);
    const sgap = self.sc(10);
    const pw = 2 * pad + 6 * sw + 5 * sgap;
    var ph = pad + 2 * sw + sgap + self.sc(14) + text_mod.height(theme.font_small * self.uf()) + self.sc(8) + self.sc(20) + pad;
    ph += tui.historyHeight(self);
    ph += @as(i32, @intCast(n_seg_rows)) * (self.sc(10) + self.sc(30));
    return .{ pw, ph };
}

/// Wide enough for the widest label and its shortcut.
fn menuSize(self: *const Editor) [2]i32 {
    const f = self.uf();
    const mp = self.sc(theme.menu_pad);
    var kb: [32]u8 = undefined;
    var widest: i32 = 0;
    for (menu_items) |k| {
        const l = buttons.buttonLabel(self, k, &kb);
        const lw = text_mod.width(theme.font_label * f, l.name) + text_mod.width(theme.font_small * f, l.key);
        widest = @max(widest, lw);
    }
    const pw = @max(self.sc(220), 2 * mp + self.sc(10 + 16 + 10) + widest + self.sc(28 + 10));
    const ph = 2 * mp + @as(i32, menu_items.len) * self.sc(theme.menu_row) + self.sc(9);
    return .{ pw, ph };
}

/// Centred on `anchor`, on the toolbar's side away from the selection
/// (the other side when that does not fit).
fn placePopover(self: *const Editor, anchor: Rect, pw: i32, ph: i32) Rect {
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const margin = self.sc(8);
    const tb = self.toolbar_rect;
    const x = std.math.clamp(anchor.x + @divTrunc(anchor.w - pw, 2), margin, @max(margin, w - pw - margin));
    const above = tb.y - ph - self.sc(10);
    const under = tb.bottom() + self.sc(10);
    var y = if (self.tb_below) above else under;
    if (y < margin or y + ph > h - margin) y = if (self.tb_below) under else above;
    y = std.math.clamp(y, margin, @max(margin, h - ph - margin));
    return .{ .x = x, .y = y, .w = pw, .h = ph };
}

/// Swatches, the custom colour, the colour history, the size slider and
/// the segment rows, top to bottom.
fn layoutColors(self: *Editor, segs: []const [3]?Seg) !void {
    const pr = self.pop_rect;
    const x = pr.x;
    const y = pr.y;
    const pad = self.sc(theme.popover_pad);
    const sw = self.sc(28);
    const sgap = self.sc(10);
    for (shapes_mod.swatch_order, 0..) |ci, k| {
        const col: i32 = @intCast(k % 6);
        const row: i32 = @intCast(k / 6);
        try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad + col * (sw + sgap), .y = y + pad + row * (sw + sgap), .w = sw, .h = sw }, .kind = .{ .color = ci }, .layer = .popover });
    }
    try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad + 5 * (sw + sgap), .y = y + pad + sw + sgap, .w = sw, .h = sw }, .kind = .custom_color, .layer = .popover });
    var cy = y + pad + 2 * sw + sgap + self.sc(14);
    cy = try tui.layoutHistory(self, x + pad, cy, pr.w - 2 * pad);
    const lh = text_mod.height(theme.font_small * self.uf());
    // slider: the whole row is the hit area
    try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad, .y = cy + lh + self.sc(8), .w = pr.w - 2 * pad, .h = self.sc(20) }, .kind = .thickness, .layer = .popover });
    cy += lh + self.sc(8) + self.sc(20);
    for (segs) |row| {
        cy += self.sc(10);
        try layoutSegRow(self, row, cy);
        cy += self.sc(30);
    }
}

/// One row of segments sharing the popover's width.
fn layoutSegRow(self: *Editor, row: [3]?Seg, cy: i32) !void {
    const pr = self.pop_rect;
    const pad = self.sc(theme.popover_pad);
    var cnt: i32 = 0;
    for (row) |sg| cnt += @intFromBool(sg != null);
    const inner = pr.w - 2 * pad - self.sc(4);
    const segw = @divTrunc(inner - (cnt - 1) * self.sc(2), cnt);
    var sx = pr.x + pad + self.sc(2);
    for (row) |sg| {
        const sv = sg orelse continue;
        try self.buttons.append(self.alloc, .{ .rect = .{ .x = sx, .y = cy + self.sc(2), .w = segw, .h = self.sc(26) }, .kind = .{ .seg = sv }, .layer = .popover });
        sx += segw + self.sc(2);
    }
}

fn layoutMenu(self: *Editor) !void {
    const pr = self.pop_rect;
    const mp = self.sc(theme.menu_pad);
    var ry = pr.y + mp;
    for (menu_items, 0..) |k, i| {
        if (i == menu_items.len - 1) ry += self.sc(9); // separator before Close
        try self.buttons.append(self.alloc, .{ .rect = .{ .x = pr.x + mp, .y = ry, .w = pr.w - 2 * mp, .h = self.sc(theme.menu_row) }, .kind = k, .layer = .menu });
        ry += self.sc(theme.menu_row);
    }
}
