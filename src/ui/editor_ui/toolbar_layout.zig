//! Toolbar layout: the main bar's controls flowed into rows, placed by
//! the selection and animated there, plus the beautify panel beside it.

const std = @import("std");
const text_mod = @import("../../gfx/text.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const motion = @import("../motion.zig");
const tui = @import("../tools/tui.zig");
const buttons = @import("buttons.zig");
const popover = @import("popover_layout.zig");
const picker = @import("picker.zig");
const hit = @import("hit.zig");
const barkit = @import("../barkit.zig");
const strip = @import("strip.zig");
const capmode = @import("../editor/capmode.zig");
const ff = @import("common.zig").ff;

const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;
const ButtonKind = buttons.ButtonKind;

pub const Item = struct { kind: ButtonKind, w: i32, group: u8 };

/// Where `flow` put the items: each one's x and row, and the separators.
const Flow = struct {
    xs: [24]i32 = undefined,
    rows: [24]u8 = undefined,
    seps: [8][2]i32 = undefined,
    w: i32 = 0,
    n_rows: i32 = 0,
    n_seps: usize = 0,
};

/// Lay out `items` in rows of at most `max_w`, groups kept together and
/// separated; fills `out` with the positions and the content size.
fn flow(self: *const Editor, items: []const Item, max_w: i32, out: *Flow) void {
    const gap = self.sc(theme.bar_gap);
    const sep_w = 1 + 2 * self.sc(theme.sep_margin);
    var x: i32 = 0;
    var row: u8 = 0;
    var content_w: i32 = 0;
    var n_seps: usize = 0;
    var i: usize = 0;
    while (i < items.len) {
        var j = i;
        var gw: i32 = 0;
        while (j < items.len and items[j].group == items[i].group) : (j += 1) gw += items[j].w + gap;
        gw -= gap;
        if (x > 0) {
            if (x + gap + sep_w + gap + gw > max_w) {
                row += 1;
                x = 0;
            } else {
                if (n_seps < out.seps.len) {
                    out.seps[n_seps] = .{ x + gap + self.sc(theme.sep_margin), row };
                    n_seps += 1;
                }
                x += gap + sep_w + gap;
            }
        }
        for (items[i..j], i..) |it, k| {
            if (x > 0 and x + it.w > max_w) {
                row += 1;
                x = 0;
            }
            out.xs[k] = x;
            out.rows[k] = row;
            x += it.w;
            content_w = @max(content_w, x);
            x += gap;
        }
        x -= gap;
        i = j;
    }
    out.w = content_w;
    out.n_rows = @as(i32, row) + 1;
    out.n_seps = n_seps;
}

pub fn layoutToolbar(self: *Editor) !void {
    self.buttons.clearRetainingCapacity();
    self.n_seps = 0;
    const now = motion.now();
    const sel_b = self.selBuf();
    const dragging = switch (self.drag) {
        .none, .picking, .size_slider => false,
        else => true,
    };
    if (sel_b == null or dragging or tui.hideBar(self)) {
        hideChrome(self);
        try strip.layout(self);
        refreshHover(self, now);
        return settleFocus(self);
    }
    const w: i32 = @intCast(self.pn().width);
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    const margin = self.sc(8);

    var items: [24]Item = undefined;
    const n = tui.barItems(self, &items) orelse mainItems(self, &items);

    var fl: Flow = .{};
    flow(self, items[0..n], @max(btn, w - 2 * margin - 2 * pad), &fl);
    const tb_w = fl.w + 2 * pad;
    const tb_h = fl.n_rows * btn + (fl.n_rows - 1) * gap + 2 * pad;

    const spot = placeToolbar(self, self.frameRect(sel_b.?), tb_w, tb_h);
    const fresh = self.toolbar_rect.isEmpty() or self.tb_layout_pane != self.pane_i;
    self.tb_layout_pane = self.pane_i;
    glideToolbar(self, spot, fresh, now);
    const ax: i32 = @intFromFloat(@round(self.tb_x.at(now)));
    const ay: i32 = @intFromFloat(@round(self.tb_y.at(now)));
    self.toolbar_rect = .{ .x = ax, .y = ay, .w = tb_w, .h = tb_h };
    try appendBarButtons(self, items[0..n], &fl, ax, ay);
    addBarSeps(self, &fl, ax, ay);
    slideActiveFill(self, fresh, ax, ay, now);

    try layoutPanel(self);
    try strip.layout(self);
    if (self.popover != .none) try popover.layoutPopover(self) else self.pop_rect = Rect.empty;
    if (self.picker.open) picker.layoutPicker(self);
    refreshHover(self, now);
    settleFocus(self);
}

/// No selection, a drag or a tool that hides the bar: no chrome but
/// the mode strip (whose button may keep the focus).
fn hideChrome(self: *Editor) void {
    self.toolbar_rect = Rect.empty;
    self.panel_rect = Rect.empty;
    self.popover = .none;
    self.picker.open = false;
    if (!capmode.wanted(self)) self.focus = null;
}

/// Where a `tb_w` x `tb_h` toolbar goes for the selection frame `s`:
/// under it; above when there is no room; inside at worst. Sets tb_below.
fn placeToolbar(self: *Editor, s: Rect, tb_w: i32, tb_h: i32) [2]i32 {
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const margin = self.sc(8);
    const off = self.sc(14);
    const bx = std.math.clamp(s.x + @divTrunc(s.w - tb_w, 2), margin, @max(margin, w - tb_w - margin));
    var by = s.bottom() + off;
    var below = true;
    if (by + tb_h > h - margin) {
        by = s.y - tb_h - off;
        below = false;
    }
    if (by < margin) {
        by = s.bottom() - tb_h - off;
        below = false;
    }
    by = std.math.clamp(by, margin, @max(margin, h - tb_h - margin));
    self.tb_below = below;
    return .{ bx, by };
}

/// Glide to the new place; fade in (rising a little) when appearing.
fn glideToolbar(self: *Editor, spot: [2]i32, fresh: bool, now: i64) void {
    const bx = spot[0];
    const by = spot[1];
    if (fresh) {
        self.tb_x.snap(ff(bx));
        self.tb_y.snap(ff(by + self.sc(6)));
        self.tb_y.dur_ms = theme.motion_slow;
        self.tb_y.to(ff(by), now);
        self.tb_alpha.snap(0);
        self.tb_alpha.dur_ms = theme.motion_slow;
        self.tb_alpha.to(1, now);
    } else {
        self.tb_x.dur_ms = theme.motion_slow;
        self.tb_y.dur_ms = theme.motion_slow;
        self.tb_x.to(ff(bx), now);
        self.tb_y.to(ff(by), now);
    }
}

fn appendBarButtons(self: *Editor, items: []const Item, fl: *const Flow, ax: i32, ay: i32) !void {
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    for (items, 0..) |it, k| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = ax + pad + fl.xs[k], .y = ay + pad + @as(i32, fl.rows[k]) * (btn + gap), .w = it.w, .h = btn },
            .kind = it.kind,
            .group = it.group,
            .row = fl.rows[k],
        });
    }
    // the copy button sits 2 px apart from More
    const cb = &self.buttons.items[self.buttons.items.len - 1];
    if (cb.kind == .copy) {
        cb.rect.x += self.sc(2);
        cb.rect.w -= self.sc(2);
    }
}

fn addBarSeps(self: *Editor, fl: *const Flow, ax: i32, ay: i32) void {
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    for (fl.seps[0..fl.n_seps]) |sp| {
        if (self.n_seps == self.seps.len) break;
        const sy = ay + pad + sp[1] * (btn + gap) + @divTrunc(btn - self.sc(theme.sep_h), 2);
        self.seps[self.n_seps] = .{ .x = ax + pad + sp[0], .y = sy, .w = 1, .h = self.sc(theme.sep_h) };
        self.n_seps += 1;
    }
}

/// The active tool's accent fill slides between buttons.
fn slideActiveFill(self: *Editor, fresh: bool, ax: i32, ay: i32, now: i64) void {
    for (self.buttons.items) |b| {
        if (b.kind == .tool and buttons.toolButtonActive(self, b.kind.tool)) {
            self.act_x.dur_ms = theme.motion;
            self.act_y.dur_ms = theme.motion;
            if (fresh) {
                self.act_x.snap(ff(b.rect.x - ax));
                self.act_y.snap(ff(b.rect.y - ay));
            } else {
                self.act_x.to(ff(b.rect.x - ax), now);
                self.act_y.to(ff(b.rect.y - ay), now);
            }
        }
    }
}

/// The controls moved: what is under a still pointer may have changed.
fn refreshHover(self: *Editor, now: i64) void {
    const hv: i32 = if (self.drag == .none) (if (hit.buttonAt(self, self.mouse)) |bi| @intCast(bi) else -1) else -1;
    if (hv != self.hover_btn) {
        self.hover_prev = -1;
        self.hover_btn = hv;
        self.hover_since_ms = now;
        self.hov.snap(0);
        self.hov.to(1, now);
    }
}

/// Move focus into a just-opened popover, and keep it on a control.
fn settleFocus(self: *Editor) void {
    if (self.focus_into_popover) {
        self.focus_into_popover = false;
        for (self.buttons.items, 0..) |b, i| {
            if (b.layer == .popover or b.layer == .menu) {
                self.focus = i;
                break;
            }
        }
    }
    if (self.focus) |f| {
        if (f >= self.buttons.items.len) self.focus = if (self.buttons.items.len > 0) self.buttons.items.len - 1 else null;
    }
}

/// The toolbar's usual controls: tools, colour and size, undo and redo,
/// save, More and Copy.
fn mainItems(self: *const Editor, items: *[24]Item) usize {
    const btn = self.sc(theme.button);
    var n: usize = 0;
    for (buttons.tool_list) |t| {
        items[n] = .{ .kind = .{ .tool = t }, .w = btn, .group = 0 };
        n += 1;
    }
    n = tui.barTools(self, items, n);
    items[n] = .{ .kind = .colors, .w = self.sc(8 + 18 + 8 + 12 + 8), .group = 1 };
    n += 1;
    for ([_]ButtonKind{ .undo, .redo }) |k| {
        items[n] = .{ .kind = k, .w = btn, .group = 2 };
        n += 1;
    }
    for ([_]ButtonKind{ .save, .more }) |k| {
        items[n] = .{ .kind = k, .w = btn, .group = 3 };
        n += 1;
    }
    items[n] = .{ .kind = .copy, .w = barkit.primaryWidth(self.uf(), "Copy") + self.sc(2), .group = 3 };
    n += 1;
    return n;
}

/// The beautify panel: its own small bar beside the toolbar while
/// beautify is on.
fn layoutPanel(self: *Editor) !void {
    if (!self.beautify.enabled) {
        self.panel_rect = Rect.empty;
        return;
    }
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    const sep_w = 1 + 2 * self.sc(theme.sep_margin);
    const label_w = text_mod.width(theme.font_small * self.uf(), "Beautify") + self.sc(16);
    const kinds = [_]ButtonKind{ .background, .padding, .corners, .shadow, .beautify_always };
    const pw = 2 * pad + label_w + gap + @as(i32, kinds.len) * (btn + gap) + sep_w + gap + btn;
    const ph = 2 * pad + btn;
    const tb = self.toolbar_rect;
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const margin = self.sc(8);
    const px = std.math.clamp(tb.x + @divTrunc(tb.w - pw, 2), margin, @max(margin, w - pw - margin));
    var py = if (self.tb_below) tb.bottom() + self.sc(8) else tb.y - ph - self.sc(8);
    if (py + ph > h - margin or py < margin) py = if (self.tb_below) tb.y - ph - self.sc(8) else tb.bottom() + self.sc(8);
    py = std.math.clamp(py, margin, @max(margin, h - ph - margin));
    self.panel_rect = .{ .x = px, .y = py, .w = pw, .h = ph };
    var x = px + pad + label_w + gap;
    for (kinds) |k| {
        try self.buttons.append(self.alloc, .{ .rect = .{ .x = x, .y = py + pad, .w = btn, .h = btn }, .kind = k, .group = 5, .layer = .panel });
        x += btn + gap;
    }
    if (self.n_seps < self.seps.len) {
        self.seps[self.n_seps] = .{ .x = x + self.sc(theme.sep_margin), .y = py + pad + @divTrunc(btn - self.sc(theme.sep_h), 2), .w = 1, .h = self.sc(theme.sep_h) };
        self.n_seps += 1;
    }
    x += sep_w + gap;
    try self.buttons.append(self.alloc, .{ .rect = .{ .x = x, .y = py + pad, .w = btn, .h = btn }, .kind = .beautify, .group = 6, .layer = .panel });
}
