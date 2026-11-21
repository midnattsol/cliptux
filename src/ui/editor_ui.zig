//! Editor chrome in the "Glass" look (theme.zig): the selection overlay,
//! one floating toolbar over a blurred copy of the screenshot, the colour
//! and size popover, the More menu, the beautify panel, the custom colour
//! picker, the magnifier loupe, tooltips, the help overlay and the copy
//! notice. Every piece has a footprint so the editor repaints only those
//! rectangles (collectOverlays must cover everything drawChrome draws).

const std = @import("std");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const effects = @import("../gfx/effects.zig");
const config = @import("../app/config.zig");
const window = @import("window.zig");
const shapes_mod = @import("shapes.zig");
const doc_mod = @import("doc.zig");
const editor_mod = @import("editor.zig");
const theme = @import("theme.zig");
const motion = @import("motion.zig");
const icons = @import("icons.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const RectList = editor_mod.RectList;
const Tool = shapes_mod.Tool;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;
const palette = shapes_mod.palette;
const handlePoints = shapes_mod.handlePoints;
const Icon = icons.Icon;

/// Segments of the popover's segmented controls.
pub const Seg = enum {
    outline,
    filled,
    rounded,
    plain,
    pill,
    mode_blur,
    mode_pixelate,
    mode_solid,
    width_fit,
    width_fixed,
};

pub const ButtonKind = union(enum) {
    tool: Tool,
    color: u4,
    custom_color,
    /// the toolbar's colour and size button: opens the popover
    colors,
    /// the size slider in the popover
    thickness,
    seg: Seg,
    /// F: cycle the target's style (kept for keyboard and scripts)
    style,
    /// a text's width: fits the text, or fixed (lines wrap)
    text_width,
    beautify,
    background,
    padding,
    corners,
    shadow,
    undo,
    redo,
    copy,
    save,
    save_as,
    more,
    help,
    cancel,
    // other capture modes (app/modes/): the editor closes and they start
    capture_window,
    capture_scroll,
    capture_timer,
};

/// Which floating surface a control sits on.
pub const Layer = enum { bar, panel, popover, menu };

pub const Button = struct {
    rect: Rect,
    kind: ButtonKind,
    group: u8 = 0,
    row: u8 = 0,
    layer: Layer = .bar,
};

pub const Popover = enum { none, colors, more };

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

/// Per-pane caches of one floating surface: its blurred backdrop and its
/// shadow mask. Rebuilt only when what lies behind it (or its size) changes.
pub const Backdrop = struct {
    rect: Rect = Rect.empty,
    hash: u64 = 0,
    /// the material over the blurred backdrop, r.w x r.h
    px: []u32 = &.{},
    /// scratch: what lies behind, composed each frame to see if it changed
    src: []u32 = &.{},
    sh_key: [6]i32 = @splat(0),
    sh_mask: []u8 = &.{},
    /// the pane's content generation when `src` was last composed
    gen: u64 = 0,

    pub fn release(self: *Backdrop, alloc: std.mem.Allocator) void {
        alloc.free(self.px);
        alloc.free(self.src);
        alloc.free(self.sh_mask);
        self.* = .{};
    }
};

pub const Slot = enum(u3) { bar, panel, popover, picker, help, notice };
pub const n_slots = @typeInfo(Slot).@"enum".field_names.len;

/// The ten tool buttons; Blur stands for blur, pixelate and solid.
pub const tool_list = [_]Tool{ .select, .pen, .arrow, .rect, .ellipse, .line, .highlight, .blur, .counter, .text };

pub fn buttonName(kind: ButtonKind) []const u8 {
    return switch (kind) {
        .tool => |t| @tagName(t),
        .color => |c| shapes_mod.palette_names[c],
        .seg => |s| @tagName(s),
        else => @tagName(kind),
    };
}

/// Whether `name` lives in the colour popover or the More menu (the
/// script's `button` command opens them first).
pub fn nameLayer(name: []const u8) ?Layer {
    for (shapes_mod.palette_names) |n| if (std.mem.eql(u8, n, name)) return .popover;
    inline for (@typeInfo(Seg).@"enum".field_names) |n| if (std.mem.eql(u8, n, name)) return .popover;
    for ([_][]const u8{ "custom_color", "thickness" }) |n| if (std.mem.eql(u8, n, name)) return .popover;
    for ([_][]const u8{ "save_as", "help", "cancel", "beautify", "capture_window", "capture_scroll", "capture_timer" }) |n| if (std.mem.eql(u8, n, name)) return .menu;
    return null;
}

const Label = struct { name: []const u8, key: []const u8 = "" };

/// A control's name and its shortcut, for tooltips and menu rows.
fn buttonLabel(self: *const Editor, kind: ButtonKind, kb: []u8) Label {
    const name: []const u8, const action: ?config.Action, const fixed: []const u8 = switch (kind) {
        .tool => |t| switch (t) {
            .select => .{ "Select", .select, "" },
            .pen => .{ "Pencil", .pen, "" },
            .line => .{ "Line", .line, "" },
            .arrow => .{ "Arrow", .arrow, "" },
            .rect => .{ "Rectangle", .rect, "" },
            .ellipse => .{ "Ellipse", .ellipse, "" },
            .highlight => .{ "Highlighter", .highlight, "" },
            .blur, .pixelate, .redact => .{ "Blur, pixelate, redact", .pixelate, "" },
            .counter => .{ "Counter", .counter, "" },
            .text => .{ "Text", .text, "" },
        },
        .color => |c| return .{ .name = shapes_mod.palette_labels[c], .key = if (c < 8) (std.fmt.bufPrint(kb, "{d}", .{@as(u8, c) + 1}) catch "") else "" },
        .custom_color => .{ "Custom colour", null, "9" },
        .colors => .{ "Colour and size", null, "" },
        .thickness => .{ "Size", null, "- =" },
        .seg => |s| .{ switch (s) {
            .outline => "Outline",
            .filled => "Filled",
            .rounded => "Rounded",
            .plain => "Plain",
            .pill => "Background",
            .mode_blur => "Blur",
            .mode_pixelate => "Pixelate",
            .mode_solid => "Solid",
            .width_fit => "Fit text",
            .width_fixed => "Wrap",
        }, null, "" },
        .style => .{ "Fill / rounded / text background", .style, "" },
        .text_width => .{ "Text width", null, "Alt+W" },
        .beautify => .{ "Beautify", .beautify, "" },
        .background => return .{ .name = self.beautify.background().name },
        .padding => return .{ .name = switch (self.beautify.padding) {
            0 => "No padding",
            1 => "Small padding",
            2 => "Medium padding",
            3 => "Large padding",
        } },
        .corners => .{ "Rounded corners", null, "" },
        .shadow => .{ "Shadow", null, "" },
        .undo => .{ "Undo", .undo, "" },
        .redo => .{ "Redo", .redo, "" },
        .copy => .{ "Copy and close", null, "Enter" },
        .save => .{ "Save", .save, "" },
        .save_as => .{ "Save as\u{2026}", .save_as, "" },
        .more => .{ "More", null, "" },
        .help => .{ "Shortcuts", null, "?" },
        .cancel => .{ "Close", null, "Esc" },
        .capture_window => .{ "Capture window", null, "" },
        .capture_scroll => .{ "Scrolling capture", null, "" },
        .capture_timer => .{ "Timer\u{2026}", null, "" },
    };
    const key = if (action) |a| config.bindName(self.binds[@backingInt(a)], kb) else fixed;
    return .{ .name = name, .key = if (std.mem.eql(u8, key, "unset")) "" else key };
}

/// The tool whose options the popover shows: the edited/selected shape's.
fn targetTool(self: *const Editor) Tool {
    if (self.text) |t| return self.doc.shapes.items[t.idx].tool;
    if (self.selected) |i| return self.doc.shapes.items[i].tool;
    return self.tool;
}

fn ff(v: i32) f64 {
    return @floatFromInt(v);
}

// --- layout ---

const Item = struct { kind: ButtonKind, w: i32, group: u8 };

fn copyButtonWidth(self: *const Editor) i32 {
    return self.sc(10) + self.sc(16) + self.sc(6) + text_mod.widthStyled(theme.font_label * self.uf(), .bold, "Copy") + self.sc(14);
}

/// Lay out `items` in rows of at most `max_w`, groups kept together and
/// separated; returns the content size and fills xs/rows/seps.
fn flow(self: *const Editor, items: []const Item, max_w: i32, xs: []i32, rows: []u8, seps: *[8][2]i32) struct { w: i32, rows: i32, n_seps: usize } {
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
                if (n_seps < seps.len) {
                    seps[n_seps] = .{ x + gap + self.sc(theme.sep_margin), row };
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
            xs[k] = x;
            rows[k] = row;
            x += it.w;
            content_w = @max(content_w, x);
            x += gap;
        }
        x -= gap;
        i = j;
    }
    return .{ .w = content_w, .rows = @as(i32, row) + 1, .n_seps = n_seps };
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
    if (sel_b == null or dragging) {
        self.toolbar_rect = Rect.empty;
        self.panel_rect = Rect.empty;
        self.popover = .none;
        self.picker.open = false;
        self.focus = null;
        return;
    }
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const btn = self.sc(theme.button);
    const gap = self.sc(theme.bar_gap);
    const pad = self.sc(theme.bar_pad);
    const margin = self.sc(8);

    var items: [24]Item = undefined;
    var n: usize = 0;
    for (tool_list) |t| {
        items[n] = .{ .kind = .{ .tool = t }, .w = btn, .group = 0 };
        n += 1;
    }
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
    items[n] = .{ .kind = .copy, .w = copyButtonWidth(self) + self.sc(2), .group = 3 };
    n += 1;

    var xs: [24]i32 = undefined;
    var rows: [24]u8 = undefined;
    var seps: [8][2]i32 = undefined;
    const fl = flow(self, items[0..n], @max(btn, w - 2 * margin - 2 * pad), &xs, &rows, &seps);
    const tb_w = fl.w + 2 * pad;
    const tb_h = fl.rows * btn + (fl.rows - 1) * gap + 2 * pad;

    // under the selection; above when there is no room; inside at worst
    const s = self.frameRect(sel_b.?);
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

    // glide to the new place; fade in (rising a little) when appearing
    const fresh = self.toolbar_rect.isEmpty() or self.tb_layout_pane != self.pane_i;
    self.tb_layout_pane = self.pane_i;
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
    const ax: i32 = @intFromFloat(@round(self.tb_x.at(now)));
    const ay: i32 = @intFromFloat(@round(self.tb_y.at(now)));
    self.toolbar_rect = .{ .x = ax, .y = ay, .w = tb_w, .h = tb_h };
    for (items[0..n], 0..) |it, k| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = ax + pad + xs[k], .y = ay + pad + @as(i32, rows[k]) * (btn + gap), .w = it.w, .h = btn },
            .kind = it.kind,
            .group = it.group,
            .row = rows[k],
        });
    }
    // the copy button sits 2 px apart from More
    const cb = &self.buttons.items[self.buttons.items.len - 1];
    cb.rect.x += self.sc(2);
    cb.rect.w -= self.sc(2);
    for (seps[0..fl.n_seps]) |sp| {
        if (self.n_seps == self.seps.len) break;
        const sy = ay + pad + sp[1] * (btn + gap) + @divTrunc(btn - self.sc(theme.sep_h), 2);
        self.seps[self.n_seps] = .{ .x = ax + pad + sp[0], .y = sy, .w = 1, .h = self.sc(theme.sep_h) };
        self.n_seps += 1;
    }

    // the active tool's accent fill slides between buttons
    for (self.buttons.items) |b| {
        if (b.kind == .tool and toolButtonActive(self, b.kind.tool)) {
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

    try layoutPanel(self);
    if (self.popover != .none) try layoutPopover(self) else self.pop_rect = Rect.empty;
    if (self.picker.open) layoutPicker(self);
    // the controls moved: what is under a still pointer may have changed
    const hv: i32 = if (self.drag == .none) (if (buttonAt(self, self.mouse)) |bi| @intCast(bi) else -1) else -1;
    if (hv != self.hover_btn) {
        self.hover_prev = -1;
        self.hover_btn = hv;
        self.hover_since_ms = now;
        self.hov.snap(0);
        self.hov.to(1, now);
    }
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
    const kinds = [_]ButtonKind{ .background, .padding, .corners, .shadow };
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

fn anchorButton(self: *const Editor, kind: std.meta.Tag(ButtonKind)) ?Rect {
    for (self.buttons.items) |b| if (b.kind == kind and b.layer == .bar) return b.rect;
    return null;
}

/// Segments shown for the target tool: up to two rows.
fn segRows(self: *const Editor, out: *[2][3]?Seg) usize {
    out.* = @splat(@splat(null));
    var n: usize = 0;
    switch (targetTool(self)) {
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
        else => {},
    }
    if (self.textHandleShape() != null) {
        out[n] = .{ .width_fit, .width_fixed, null };
        n += 1;
    }
    return n;
}

const menu_items = [_]ButtonKind{ .beautify, .save_as, .capture_window, .capture_scroll, .capture_timer, .help, .cancel };

fn layoutPopover(self: *Editor) !void {
    const f = self.uf();
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const margin = self.sc(8);
    const tb = self.toolbar_rect;
    var pw: i32 = 0;
    var ph: i32 = 0;
    const anchor: Rect = switch (self.popover) {
        .none => return,
        .colors => anchorButton(self, .colors) orelse tb,
        .more => anchorButton(self, .more) orelse tb,
    };
    const pad = self.sc(theme.popover_pad);
    const sw = self.sc(28);
    const sgap = self.sc(10);
    var segs: [2][3]?Seg = undefined;
    const n_seg_rows = segRows(self, &segs);
    switch (self.popover) {
        .none => return,
        .colors => {
            pw = 2 * pad + 6 * sw + 5 * sgap;
            ph = pad + 2 * sw + sgap + self.sc(14) + text_mod.height(theme.font_small * f) + self.sc(8) + self.sc(20) + pad;
            ph += @as(i32, @intCast(n_seg_rows)) * (self.sc(10) + self.sc(30));
        },
        .more => {
            const mp = self.sc(theme.menu_pad);
            var kb: [32]u8 = undefined;
            var widest: i32 = 0;
            for (menu_items) |k| {
                const l = buttonLabel(self, k, &kb);
                const lw = text_mod.width(theme.font_label * f, l.name) + text_mod.width(theme.font_small * f, l.key);
                widest = @max(widest, lw);
            }
            pw = @max(self.sc(220), 2 * mp + self.sc(10 + 16 + 10) + widest + self.sc(28 + 10));
            ph = 2 * mp + @as(i32, menu_items.len) * self.sc(theme.menu_row) + self.sc(9);
        },
    }
    const x = std.math.clamp(anchor.x + @divTrunc(anchor.w - pw, 2), margin, @max(margin, w - pw - margin));
    const above = tb.y - ph - self.sc(10);
    const under = tb.bottom() + self.sc(10);
    var y = if (self.tb_below) above else under;
    if (y < margin or y + ph > h - margin) y = if (self.tb_below) under else above;
    y = std.math.clamp(y, margin, @max(margin, h - ph - margin));
    self.pop_rect = .{ .x = x, .y = y, .w = pw, .h = ph };

    switch (self.popover) {
        .none => {},
        .colors => {
            for (shapes_mod.swatch_order, 0..) |ci, k| {
                const col: i32 = @intCast(k % 6);
                const row: i32 = @intCast(k / 6);
                try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad + col * (sw + sgap), .y = y + pad + row * (sw + sgap), .w = sw, .h = sw }, .kind = .{ .color = ci }, .layer = .popover });
            }
            try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad + 5 * (sw + sgap), .y = y + pad + sw + sgap, .w = sw, .h = sw }, .kind = .custom_color, .layer = .popover });
            var cy = y + pad + 2 * sw + sgap + self.sc(14);
            const lh = text_mod.height(theme.font_small * f);
            // slider: the whole row is the hit area
            try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + pad, .y = cy + lh + self.sc(8), .w = pw - 2 * pad, .h = self.sc(20) }, .kind = .thickness, .layer = .popover });
            cy += lh + self.sc(8) + self.sc(20);
            for (segs[0..n_seg_rows]) |row| {
                cy += self.sc(10);
                var cnt: i32 = 0;
                for (row) |sg| cnt += @intFromBool(sg != null);
                const inner = pw - 2 * pad - self.sc(4);
                const segw = @divTrunc(inner - (cnt - 1) * self.sc(2), cnt);
                var sx = x + pad + self.sc(2);
                for (row) |sg| {
                    const sv = sg orelse continue;
                    try self.buttons.append(self.alloc, .{ .rect = .{ .x = sx, .y = cy + self.sc(2), .w = segw, .h = self.sc(26) }, .kind = .{ .seg = sv }, .layer = .popover });
                    sx += segw + self.sc(2);
                }
                cy += self.sc(30);
            }
        },
        .more => {
            const mp = self.sc(theme.menu_pad);
            var ry = y + mp;
            for (menu_items, 0..) |k, i| {
                if (i == menu_items.len - 1) ry += self.sc(9); // separator before Close
                try self.buttons.append(self.alloc, .{ .rect = .{ .x = x + mp, .y = ry, .w = pw - 2 * mp, .h = self.sc(theme.menu_row) }, .kind = k, .layer = .menu });
                ry += self.sc(theme.menu_row);
            }
        },
    }
}

/// Tab order: the popover or menu while one is open, else the bars.
pub fn moveFocus(self: *Editor, dir: i32) void {
    const top = self.popover != .none;
    var list: [64]usize = undefined;
    var n: usize = 0;
    for (self.buttons.items, 0..) |b, i| {
        const on_top = b.layer == .popover or b.layer == .menu;
        if (on_top != top or n == list.len) continue;
        list[n] = i;
        n += 1;
    }
    if (n == 0) return;
    var cur: i32 = if (dir > 0) -1 else @intCast(n);
    if (self.focus) |f| for (list[0..n], 0..) |li, k| {
        if (li == f) cur = @intCast(k);
    };
    const ni: usize = @intCast(@mod(cur + dir, @as(i32, @intCast(n))));
    self.focus = list[ni];
}

/// The control under buffer point `m` (pointer pane must be the toolbar's).
pub fn buttonAt(self: *const Editor, m: Point) ?usize {
    if (self.mouse_pane != self.tb_pane) return null;
    // the popover is on top
    var i = self.buttons.items.len;
    while (i > 0) {
        i -= 1;
        const b = self.buttons.items[i];
        if (b.rect.contains(m.x, m.y)) return i;
    }
    return null;
}

/// Is `m` on any floating surface (toolbar, panel, popover, picker)?
pub fn onChrome(self: *const Editor, m: Point) bool {
    if (self.mouse_pane != self.tb_pane) return false;
    for ([_]Rect{ self.toolbar_rect, self.panel_rect, self.pop_rect }) |r| {
        if (!r.isEmpty() and r.contains(m.x, m.y)) return true;
    }
    return self.picker.open and self.picker.rect.contains(m.x, m.y);
}

pub fn popoverContains(self: *const Editor, m: Point) bool {
    return self.popover != .none and self.mouse_pane == self.tb_pane and self.pop_rect.contains(m.x, m.y);
}

/// Thickness for a pointer at `m` on the size slider.
pub fn sliderValue(self: *const Editor, m: Point) i32 {
    for (self.buttons.items) |b| {
        if (b.kind != .thickness) continue;
        const knob = self.sc(9);
        const t = std.math.clamp(ff(m.x - b.rect.x - knob) / ff(@max(1, b.rect.w - 2 * knob)), 0, 1);
        return @intFromFloat(@round(1 + t * 31));
    }
    return self.thickness;
}

// --- footprints ---

fn addOutline(list: *RectList, r: Rect, pad: i32) void {
    list.add(.{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.bottom() - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
    list.add(.{ .x = r.right() - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
}

fn handleDrawRadius(self: *const Editor) f64 {
    return 5.0 * self.uf();
}

fn chromePad(self: *const Editor) i32 {
    return @as(i32, @intFromFloat(@ceil(handleDrawRadius(self) + 3.0 * self.uf()))) + 3;
}

/// What a floating surface with `sh` covers: itself plus its shadow.
fn shadowFootprint(self: *const Editor, r: Rect, sh: theme.Shadow) Rect {
    const b = self.sc(sh.blur);
    const dy = self.sc(sh.dy);
    return .{ .x = r.x - b, .y = r.y - b + @min(0, dy), .w = r.w + 2 * b, .h = r.h + 2 * b + @as(i32, @intCast(@abs(dy))) };
}

pub fn collectOverlays(self: *Editor, list: *RectList) void {
    list.add(self.liveBounds());
    if (self.text) |t| {
        const f = self.pn().view.rectToBuf(self.doc.shapes.items[t.idx].frame()).expand(self.sc(3));
        addOutline(list, f, 2);
        if (self.isMousePane()) if (preeditRect(self)) |r| list.add(r.expand(2));
    }
    if (self.selected) |i| {
        if (shapeChromeRect(self, i)) |r| addOutline(list, r, chromePad(self));
    }
    if (self.textHandleShape()) |i| list.add(textHandleRect(self, i).expand(2));
    if (self.selBuf()) |s| {
        addOutline(list, s, chromePad(self));
        list.add(dimsPillRect(self, s).expand(1));
    }
    if (self.show_hint) list.add(hintRect(self).expand(1));
    if (self.isMousePane()) {
        if (loupeRect(self)) |r| list.add(r.expand(2));
    }
    if (!self.isTbPane()) return;
    const th = self.theme;
    if (!self.toolbar_rect.isEmpty()) list.add(shadowFootprint(self, self.toolbar_rect.expand(self.sc(1)), th.bar_shadow));
    if (!self.panel_rect.isEmpty()) list.add(shadowFootprint(self, self.panel_rect.expand(self.sc(1)), th.bar_shadow));
    if (!self.pop_rect.isEmpty()) list.add(shadowFootprint(self, self.pop_rect.expand(self.sc(1)), th.popover_shadow));
    if (tooltipRect(self)) |r| list.add(r.expand(self.sc(6)));
    if (self.picker.open and !self.toolbar_rect.isEmpty()) list.add(shadowFootprint(self, self.picker.rect.expand(self.sc(1)), th.popover_shadow));
    if (self.copy_notice != .none) list.add(shadowFootprint(self, noticeRect(self), th.bar_shadow));
    if (self.help_open) list.add(shadowFootprint(self, helpRect(self), th.popover_shadow));
}

fn shapeChromeRect(self: *const Editor, i: usize) ?Rect {
    const s = &self.doc.shapes.items[i];
    return switch (s.handleKind()) {
        .endpoints => Rect.fromCorners(self.pn().view.toBuf(s.p0), self.pn().view.toBuf(s.p1)),
        else => self.pn().view.rectToBuf(s.frame()).expand(self.sc(3)),
    };
}

/// Are animations running that need more frames?
pub fn animating(self: *const Editor) bool {
    const t = motion.now();
    if (self.toolbar_rect.isEmpty()) return false;
    return self.tb_x.busy(t) or self.tb_y.busy(t) or self.tb_alpha.busy(t) or self.act_x.busy(t) or
        self.act_y.busy(t) or self.hov.busy(t) or (self.popover != .none and self.pop_open.busy(t));
}

// --- chrome ---

pub fn drawChrome(self: *Editor, canvas: *Canvas) void {
    if (self.text) |t| {
        const f = self.pn().view.rectToBuf(self.doc.shapes.items[t.idx].frame()).expand(self.sc(3));
        dashedRect(canvas, f, 0xCCFFFFFF, 0xCC000000);
        if (self.isMousePane()) drawPreedit(self, canvas);
    }
    if (self.selected) |i| drawShapeChrome(self, canvas, i);
    if (self.textHandleShape()) |i| drawTextHandle(self, canvas, i);
    drawSelectionChrome(self, canvas);
    if (self.isMousePane()) drawLoupe(self, canvas);
    if (!self.isTbPane()) return;
    drawToolbar(self, canvas);
    if (self.popover != .none and !self.pop_rect.isEmpty()) drawPopover(self, canvas);
    if (self.picker.open and !self.toolbar_rect.isEmpty()) drawPicker(self, canvas);
    drawTooltip(self, canvas);
    if (self.copy_notice != .none) drawCopyNotice(self, canvas);
    if (self.help_open) drawHelp(self, canvas);
}

fn preeditFs(self: *const Editor) f64 {
    const t = self.text.?;
    return self.doc.shapes.items[t.idx].fontPx() * self.pn().view.scale;
}

/// Where the input method's in-progress composition shows (at the caret).
fn preeditRect(self: *Editor) ?Rect {
    const pe = self.win.preedit();
    if (pe.len == 0) return null;
    const c = self.caretRect() orelse return null;
    const fs = preeditFs(self);
    return .{ .x = c.x, .y = c.y, .w = text_mod.width(fs, pe) + self.sc(4), .h = c.h + self.sc(3) };
}

fn drawPreedit(self: *Editor, canvas: *Canvas) void {
    const r = preeditRect(self) orelse return;
    const fs = preeditFs(self);
    canvas.fillRect(r.x, r.y, r.w, r.h, 0xE61C1C1E);
    text_mod.draw(canvas, r.x + self.sc(2), r.y, fs, 0xFFFFFFFF, self.win.preedit());
    canvas.fillRect(r.x, r.bottom() - self.sc(2), r.w, @max(1, self.sc(1)), self.theme.accent);
}

fn dashedRect(canvas: *Canvas, r: Rect, a: u32, b: u32) void {
    const dash: i32 = 4;
    var x = r.x;
    while (x < r.right()) : (x += 1) {
        const c = if (@mod(@divFloor(x - r.x, dash), 2) == 0) a else b;
        canvas.blend(x, r.y, c);
        canvas.blend(x, r.bottom() - 1, c);
    }
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        const c = if (@mod(@divFloor(y - r.y, dash), 2) == 0) a else b;
        canvas.blend(r.x, y, c);
        canvas.blend(r.right() - 1, y, c);
    }
}

/// Footprint of a text box's width handle: a short vertical pill.
fn textHandleRect(self: *const Editor, i: usize) Rect {
    const h = self.textWidthHandle(i);
    const hw: i32 = @intFromFloat(@ceil(3.5 * self.uf()));
    const hh: i32 = @intFromFloat(@ceil(9.0 * self.uf()));
    return .{ .x = h.x - hw, .y = h.y - hh, .w = 2 * hw, .h = 2 * hh };
}

/// The width handle: drag to fix the box width, double-click for auto.
/// Filled when the width is fixed, hollow when the box fits its text.
fn drawTextHandle(self: *Editor, canvas: *Canvas, i: usize) void {
    const r = textHandleRect(self, i);
    const fixed = self.doc.shapes.items[i].box_w > 0;
    const rad = ff(r.w) / 2.0;
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, 0xB3000000);
    const in = @max(1, self.sc(1));
    canvas.fillRoundRectAA(r.x + in, r.y + in, r.w - 2 * in, r.h - 2 * in, rad - 1, if (fixed) self.theme.accent else 0xFFFFFFFF);
}

/// A white handle with a soft shadow, like the selection's corners.
fn drawHandle(self: *const Editor, canvas: *Canvas, x: f64, y: f64, r: f64) void {
    const f = self.uf();
    canvas.fillCircleAA(x, y + 1.0 * f, r + 1.5 * f, 0x1F000000);
    canvas.fillCircleAA(x, y + 1.0 * f, r + 0.5 * f, 0x40000000);
    canvas.fillCircleAA(x, y, r, self.theme.handle);
}

fn drawShapeChrome(self: *Editor, canvas: *Canvas, i: usize) void {
    const s = &self.doc.shapes.items[i];
    const f = self.uf();
    const hr = handleDrawRadius(self) * 0.9;
    const accent = self.theme.accent;
    switch (s.handleKind()) {
        .endpoints => {
            for ([_]Point{ s.p0, s.p1 }) |p| {
                const b = self.pn().view.toBuf(p);
                drawHandle(self, canvas, ff(b.x), ff(b.y), hr);
                canvas.ringAA(ff(b.x), ff(b.y), hr - 0.75 * f, 1.5 * f, accent);
            }
        },
        else => {
            const r = shapeChromeRect(self, i).?;
            dashedRect(canvas, r, accent, 0x80FFFFFF);
            if (s.handleKind() == .box) {
                for (handlePoints(r)) |p| {
                    drawHandle(self, canvas, ff(p.x), ff(p.y), hr);
                    canvas.ringAA(ff(p.x), ff(p.y), hr - 0.75 * f, 1.5 * f, accent);
                }
            }
        },
    }
}

fn dimsLabel(self: *const Editor, buf: []u8) []const u8 {
    const s = self.doc.sel.?.normalized();
    const x = if (text_mod.available()) "\u{00D7}" else "x";
    if (self.beautify.enabled) {
        const g = self.beautify.geometry(@intCast(@max(1, s.w)), @intCast(@max(1, s.h)));
        return std.fmt.bufPrint(buf, "{d} {s} {d}  \u{2192}  {d} {s} {d}", .{ s.w, x, s.h, g.out_w, x, g.out_h }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ s.w, x, s.h }) catch "?";
}

fn dimsPillRect(self: *const Editor, s: Rect) Rect {
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

fn hintRect(self: *const Editor) Rect {
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
        canvas.rectOutline(s.x - 1, s.y - 1, s.w + 2, s.h + 2, 1, th.sel_edge);
        if (self.tool == .select and self.drag == .none and self.selected == null) {
            for (handlePoints(s), 0..) |p, i| {
                if (!showHandle(self, s, i)) continue;
                drawHandle(self, canvas, ff(p.x), ff(p.y), handleDrawRadius(self));
            }
        }
        // one size label, on the monitor with the toolbar (the one the
        // pointer is on, else the one showing most of the selection)
        if (self.isTbPane()) {
            var buf: [64]u8 = undefined;
            const label = dimsLabel(self, &buf);
            const r = dimsPillRect(self, s);
            canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.pill_bg);
            text_mod.draw(canvas, r.x + self.sc(10), r.y + self.sc(4), theme.font_small * f, th.pill_fg, label);
        }
    }
    if (self.show_hint) {
        // first run only: a quiet pill, gone at the first click or key
        self.hint_seen = true;
        const r = hintRect(self);
        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, ff(r.h) / 2.0, th.pill_bg);
        text_mod.draw(canvas, r.x + self.sc(16), r.y + self.sc(7), theme.font_label * f, th.pill_fg, hintText());
    }
}

// --- material: blurred backdrop, tint, hairline, shadow ---

/// Signed-distance coverage of pixel (x, y) by a rounded rectangle.
inline fn roundCov(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r: f64) f64 {
    const qx = @max(@max(x0 + r - px, px - (x1 - r)), 0.0);
    const qy = @max(@max(y0 + r - py, py - (y1 - r)), 0.0);
    const d = if (qx == 0 and qy == 0) @max(@max(x0 - px, px - x1), @max(y0 - py, py - y1)) else @sqrt(qx * qx + qy * qy) - r;
    return d;
}

/// The pixels behind `r`, blurred and a little more saturated; cached
/// while they stay the same.
fn backdrop(self: *Editor, slot: Slot, r: Rect) ?[]const u32 {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    const rad: i32 = @max(2, self.sc(theme.backdrop_blur));
    const scr = self.screenRect();
    const src = Rect.intersect(r.expand(rad * 2), scr) orelse return null;
    // nothing behind changed since last time: no need to even look
    if (bd.gen == self.pn().gen and bd.hash != 0 and Rect.eql(bd.rect, r) and bd.px.len == @as(usize, @intCast(r.w * r.h))) return bd.px;
    bd.gen = self.pn().gen;
    const n: usize = @intCast(src.w * src.h);
    if (bd.src.len < n) {
        self.alloc.free(bd.src);
        bd.src = &.{};
        bd.src = self.alloc.alloc(u32, n) catch return null;
    }
    const scratch = bd.src[0..n];
    self.composeRegionTo(scratch, @intCast(src.w), .{ .x = src.x, .y = src.y }, src);
    var hasher = std.hash.Wyhash.init(0x5107);
    hasher.update(std.mem.sliceAsBytes(scratch));
    hasher.update(std.mem.asBytes(&r));
    hasher.update(std.mem.asBytes(&src));
    hasher.update(std.mem.asBytes(&self.theme.material));
    const hash = hasher.final();
    if (bd.hash == hash and bd.px.len == @as(usize, @intCast(r.w * r.h)) and Rect.eql(bd.rect, r)) return bd.px;

    // blur at half resolution: cheaper, and nobody can tell
    const sw: usize = @intCast(@divTrunc(src.w + 1, 2));
    const sh: usize = @intCast(@divTrunc(src.h + 1, 2));
    const small = self.alloc.alloc(u32, sw * sh) catch return null;
    defer self.alloc.free(small);
    const srcw: usize = @intCast(src.w);
    const srch: usize = @intCast(src.h);
    for (0..sh) |y| for (0..sw) |x| {
        var acc: [3]u32 = .{ 0, 0, 0 };
        for (0..2) |dy| for (0..2) |dx| {
            const p = scratch[@min(srch - 1, y * 2 + dy) * srcw + @min(srcw - 1, x * 2 + dx)];
            acc[0] += (p >> 16) & 0xFF;
            acc[1] += (p >> 8) & 0xFF;
            acc[2] += p & 0xFF;
        };
        small[y * sw + x] = 0xFF000000 | ((acc[0] / 4) << 16) | ((acc[1] / 4) << 8) | (acc[2] / 4);
    };
    effects.softBlur(self.alloc, small, @intCast(sw), @intCast(sh), .{ .x = 0, .y = 0, .w = @intCast(sw), .h = @intCast(sh) }, @intCast(@max(1, @divTrunc(rad, 2)))) catch return null;

    const need: usize = @intCast(r.w * r.h);
    if (bd.px.len != need) {
        self.alloc.free(bd.px);
        bd.px = &.{};
        bd.px = self.alloc.alloc(u32, need) catch return null;
    }
    // saturate a little, like vibrancy, and tint with the material, at
    // the small size; then scale up (bilinear, 8-bit fixed point)
    for (small) |*p| {
        const cr: i32 = @intCast((p.* >> 16) & 0xFF);
        const cg: i32 = @intCast((p.* >> 8) & 0xFF);
        const cb: i32 = @intCast(p.* & 0xFF);
        const lum = @divTrunc(54 * cr + 183 * cg + 19 * cb, 256);
        var out: u32 = 0xFF000000;
        inline for (.{ cr, cg, cb }, 0..) |cc, k| {
            const v = std.math.clamp(lum + @divTrunc((cc - lum) * 346, 256), 0, 255);
            out |= @as(u32, @intCast(v)) << @intCast(16 - 8 * k);
        }
        p.* = Canvas.blendPixel(out, self.theme.material);
    }
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |y| {
        // source position in 1/256ths of a small pixel
        const fy = std.math.clamp(@as(i32, @intCast(y)) * 128 + (r.y - src.y) * 128 - 64, 0, @as(i32, @intCast(sh - 1)) * 256);
        const y0: usize = @intCast(@divTrunc(fy, 256));
        const y1 = @min(sh - 1, y0 + 1);
        const ty: u32 = @intCast(@mod(fy, 256));
        const row0 = small[y0 * sw ..][0..sw];
        const row1 = small[y1 * sw ..][0..sw];
        for (0..rw) |x| {
            const fx = std.math.clamp(@as(i32, @intCast(x)) * 128 + (r.x - src.x) * 128 - 64, 0, @as(i32, @intCast(sw - 1)) * 256);
            const x0: usize = @intCast(@divTrunc(fx, 256));
            const x1 = @min(sw - 1, x0 + 1);
            const tx: u32 = @intCast(@mod(fx, 256));
            const a = row0[x0];
            const b = row0[x1];
            const c = row1[x0];
            const d = row1[x1];
            var out: u32 = 0xFF000000;
            inline for (.{ 16, 8, 0 }) |sh_| {
                const top = ((a >> sh_) & 0xFF) * (256 - tx) + ((b >> sh_) & 0xFF) * tx;
                const bot = ((c >> sh_) & 0xFF) * (256 - tx) + ((d >> sh_) & 0xFF) * tx;
                out |= (((top * (256 - ty) + bot * ty) >> 16) & 0xFF) << sh_;
            }
            bd.px[y * rw + x] = out;
        }
    }
    bd.rect = r;
    bd.hash = hash;
    return bd.px;
}

/// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
fn erf(x: f64) f64 {
    const s: f64 = if (x < 0) -1 else 1;
    const a = @abs(x);
    const t = 1.0 / (1.0 + 0.3275911 * a);
    const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-a * a);
    return s * y;
}

/// A CSS-like box shadow around the rounded rect `r`, outside it only
/// (the material is translucent: no shadow shows through it).
fn drawShadow(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow, alpha: f64) void {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    const b = self.sc(sh.blur);
    const dy = self.sc(sh.dy);
    const sigma = @max(0.5, ff(b) / 2.0);
    const fr = Rect{ .x = r.x - b, .y = r.y - b + @min(0, dy), .w = r.w + 2 * b, .h = r.h + 2 * b + @as(i32, @intCast(@abs(dy))) };
    const key = [6]i32{ r.w, r.h, @intFromFloat(radius * 16), b, dy, 1 };
    const n: usize = @intCast(fr.w * fr.h);
    if (!std.mem.eql(i32, &key, &bd.sh_key) or bd.sh_mask.len != n) {
        self.alloc.free(bd.sh_mask);
        bd.sh_mask = &.{};
        bd.sh_mask = self.alloc.alloc(u8, n) catch return;
        bd.sh_key = key;
        // in mask coordinates
        const x0 = ff(r.x - fr.x);
        const y0 = ff(r.y - fr.y);
        const x1 = x0 + ff(r.w);
        const y1 = y0 + ff(r.h);
        const fdy = ff(dy);
        const inv = 1.0 / (sigma * std.math.sqrt2);
        for (0..@intCast(fr.h)) |yy| for (0..@intCast(fr.w)) |xx| {
            const px = ff(@intCast(xx)) + 0.5;
            const py = ff(@intCast(yy)) + 0.5;
            const inside = roundCov(px, py, x0, y0, x1, y1, radius);
            if (inside < -0.5) {
                bd.sh_mask[yy * @as(usize, @intCast(fr.w)) + xx] = 0;
                continue;
            }
            const d = roundCov(px, py - fdy, x0, y0, x1, y1, radius);
            var a = 0.5 * (1.0 - erf(d * inv));
            // fade into the edge of the material itself
            if (inside < 0.5) a *= inside + 0.5;
            bd.sh_mask[yy * @as(usize, @intCast(fr.w)) + xx] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
        };
    }
    const ca: u32 = @intFromFloat(@round(ff(@intCast(sh.color >> 24)) * alpha));
    const rgb = sh.color & 0x00FFFFFF;
    const fw: usize = @intCast(fr.w);
    const xa: usize = @intCast(@max(0, -fr.x));
    const xb: usize = @intCast(std.math.clamp(canvas.w - fr.x, 0, fr.w));
    const cw: usize = @intCast(canvas.w);
    for (0..@intCast(fr.h)) |yy| {
        const y = fr.y + @as(i32, @intCast(yy));
        if (y < 0 or y >= canvas.h) continue;
        const row = canvas.px[@as(usize, @intCast(y)) * cw ..];
        const mrow = bd.sh_mask[yy * fw ..][0..fw];
        if (rgb == 0) {
            // black: darken by the coverage, two multiplies a pixel
            for (xa..xb) |xx| {
                const m: u32 = mrow[xx];
                if (m == 0) continue;
                const keep = 256 - ((ca * m + 127) >> 8);
                const i: usize = @intCast(fr.x + @as(i32, @intCast(xx)));
                const p = row[i];
                row[i] = 0xFF000000 | (((p & 0xFF00FF) * keep >> 8) & 0xFF00FF) | (((p & 0x00FF00) * keep >> 8) & 0x00FF00);
            }
            continue;
        }
        for (xa..xb) |xx| {
            const m: u32 = mrow[xx];
            if (m == 0) continue;
            const a = (ca * m + 127) / 255;
            if (a == 0) continue;
            const i: usize = @intCast(fr.x + @as(i32, @intCast(xx)));
            row[i] = Canvas.blendPixel(row[i], rgb | (a << 24));
        }
    }
}

/// The floating material: shadow, the tinted blurred backdrop clipped to
/// the rounded rect, and a hairline edge.
fn drawMaterial(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow) void {
    if (r.w <= 0 or r.h <= 0) return;
    const th = self.theme;
    drawShadow(self, canvas, slot, r, radius, sh, 1);
    if (backdrop(self, slot, r)) |bdp| {
        blitRoundRect(canvas, bdp, r, radius);
    } else canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, th.material);
    // 0.5 px hairline: one pixel at half strength on a 1x screen
    hairline(canvas, r, radius, theme.fade(th.hairline, @min(1.0, 0.5 * self.uf())));
}

/// Copy `src` (r.w x r.h) into `r` with rounded, anti-aliased corners.
fn blitRoundRect(canvas: *Canvas, src: []const u32, r: Rect, radius: f64) void {
    const c = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    const rw: usize = @intCast(r.w);
    const cw: usize = @intCast(canvas.w);
    const band: i32 = @intFromFloat(@ceil(radius));
    const x0 = ff(r.x);
    const y0 = ff(r.y);
    const x1 = x0 + ff(r.w);
    const y1 = y0 + ff(r.h);
    var y = c.y;
    while (y < c.bottom()) : (y += 1) {
        const sy: usize = @intCast(y - r.y);
        const srow = src[sy * rw ..][0..rw];
        const drow = canvas.px[@as(usize, @intCast(y)) * cw ..][0..cw];
        const corner_row = y < r.y + band or y >= r.bottom() - band;
        // the straight middle: a plain copy
        const ma = if (corner_row) @max(c.x, r.x + band) else c.x;
        const mb = if (corner_row) @min(c.right(), r.right() - band) else c.right();
        if (mb > ma) @memcpy(drow[@intCast(ma)..@intCast(mb)], srow[@intCast(ma - r.x)..@intCast(mb - r.x)]);
        if (!corner_row) continue;
        for ([2][2]i32{ .{ c.x, @min(ma, c.right()) }, .{ @max(mb, c.x), c.right() } }) |span| {
            var x = span[0];
            while (x < span[1]) : (x += 1) {
                const d = roundCov(ff(x) + 0.5, ff(y) + 0.5, x0, y0, x1, y1, radius);
                const cov = std.math.clamp(0.5 - d, 0, 1);
                if (cov <= 0) continue;
                const a: u32 = @intFromFloat(@round(cov * 255));
                const p = srow[@intCast(x - r.x)];
                drow[@intCast(x)] = Canvas.blendPixel(drow[@intCast(x)], (p & 0x00FFFFFF) | (a << 24));
            }
        }
    }
}

/// A one-pixel line just inside the rounded rect `r`.
fn hairline(canvas: *Canvas, r: Rect, radius: f64, color: u32) void {
    const rad: i32 = @intFromFloat(@ceil(radius));
    canvas.fillRect(r.x + rad, r.y, r.w - 2 * rad, 1, color);
    canvas.fillRect(r.x + rad, r.bottom() - 1, r.w - 2 * rad, 1, color);
    canvas.fillRect(r.x, r.y + rad, 1, r.h - 2 * rad, color);
    canvas.fillRect(r.right() - 1, r.y + rad, 1, r.h - 2 * rad, color);
    // the corners: a ring of radius - 0.5 around each corner's centre
    const corners = [4][4]f64{
        .{ ff(r.x) + radius, ff(r.y) + radius, -1, -1 },
        .{ ff(r.right()) - radius, ff(r.y) + radius, 1, -1 },
        .{ ff(r.x) + radius, ff(r.bottom()) - radius, -1, 1 },
        .{ ff(r.right()) - radius, ff(r.bottom()) - radius, 1, 1 },
    };
    const ca = ff(@intCast(color >> 24));
    for (corners) |k| {
        const bx: i32 = if (k[2] < 0) r.x else r.right() - rad;
        const by: i32 = if (k[3] < 0) r.y else r.bottom() - rad;
        var y = by;
        while (y < by + rad) : (y += 1) {
            var x = bx;
            while (x < bx + rad) : (x += 1) {
                const dx = ff(x) + 0.5 - k[0];
                const dy = ff(y) + 0.5 - k[1];
                const d = @sqrt(dx * dx + dy * dy);
                const cov = std.math.clamp(1.0 - @abs(d - (radius - 0.5)), 0, 1);
                if (cov <= 0) continue;
                canvas.blend(x, y, (color & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(ca * cov))) << 24));
            }
        }
    }
}

/// Opacity for whatever is drawn between snapshot and restore: keeps a
/// copy of `r`, and mixes it back in afterwards.
const Snapshot = struct {
    r: Rect,
    px: []u32,
    fn take(alloc: std.mem.Allocator, canvas: *Canvas, r_in: Rect) ?Snapshot {
        const r = Rect.intersect(r_in, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return null;
        const px = alloc.alloc(u32, @intCast(r.w * r.h)) catch return null;
        const rw: usize = @intCast(r.w);
        for (0..@intCast(r.h)) |yy| {
            const off = @as(usize, @intCast(r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(r.x));
            @memcpy(px[yy * rw ..][0..rw], canvas.px[off..][0..rw]);
        }
        return .{ .r = r, .px = px };
    }
    fn restore(self: Snapshot, alloc: std.mem.Allocator, canvas: *Canvas, alpha: f64) void {
        defer alloc.free(self.px);
        if (alpha >= 1) return;
        const k: u32 = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 256));
        const rw: usize = @intCast(self.r.w);
        for (0..@intCast(self.r.h)) |yy| {
            const off = @as(usize, @intCast(self.r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(self.r.x));
            for (canvas.px[off..][0..rw], self.px[yy * rw ..][0..rw]) |*d, old| {
                const rb = ((d.* & 0xFF00FF) * k + (old & 0xFF00FF) * (256 - k)) >> 8;
                const g = ((d.* & 0x00FF00) * k + (old & 0x00FF00) * (256 - k)) >> 8;
                d.* = 0xFF000000 | (rb & 0xFF00FF) | (g & 0x00FF00);
            }
        }
    }
};

// --- toolbar ---

fn toolButtonActive(self: *const Editor, t: Tool) bool {
    if (t == .blur) return self.tool.isRedaction();
    return t == self.tool;
}

fn buttonActive(self: *const Editor, kind: ButtonKind) bool {
    return switch (kind) {
        .tool => |t| toolButtonActive(self, t),
        .colors => self.popover == .colors,
        .more => self.popover == .more,
        .corners => self.beautify.rounded,
        .shadow => self.beautify.shadow,
        .beautify => self.beautify.enabled,
        .help => self.help_open,
        else => false,
    };
}

/// Hover highlight strength of button `bi` (fades in and out).
fn hoverAmount(self: *const Editor, bi: usize) f64 {
    const t = motion.now();
    const k = self.hov.at(t);
    if (self.hover_btn >= 0 and bi == @as(usize, @intCast(self.hover_btn))) return k;
    if (self.hover_prev >= 0 and bi == @as(usize, @intCast(self.hover_prev))) return 1 - k;
    return 0;
}

fn focusRing(self: *const Editor, canvas: *Canvas, r: Rect, radius: f64) void {
    const g = self.sc(theme.focus_gap);
    const fw = theme.focus_w * self.uf();
    const rr = r.expand(g + @as(i32, @intFromFloat(@ceil(fw / 2))));
    shapes_mod.roundRectRing(canvas, rr, radius + ff(g) + fw / 2, fw, self.theme.accent);
}

fn toolIcon(self: *const Editor, t: Tool) Icon {
    return switch (t) {
        .select => .select,
        .pen => .pen,
        .arrow => .arrow,
        .rect => .rect,
        .ellipse => .ellipse,
        .line => .line,
        .highlight => .highlight,
        .blur, .pixelate, .redact => switch (self.tool) {
            .pixelate => .pixelate,
            .redact => .redact,
            else => .blur,
        },
        .counter => .counter,
        .text => .text,
    };
}

fn kindIcon(self: *const Editor, kind: ButtonKind) ?Icon {
    return switch (kind) {
        .tool => |t| toolIcon(self, t),
        .undo => .undo,
        .redo => .redo,
        .save => .save,
        .save_as => .save_as,
        .more => .more,
        .copy => .copy,
        .help => .keyboard,
        .cancel => .close,
        .beautify => .beautify,
        .background => .background,
        .padding => .padding,
        .corners => .corners,
        .shadow => .shadow,
        .capture_window => .capture_window,
        .capture_scroll => .capture_scroll,
        .capture_timer => .timer,
        else => null,
    };
}

fn drawIconIn(self: *const Editor, canvas: *Canvas, icon: Icon, r: Rect, size: f64, color: u32) void {
    const s = self.sc(size);
    icons.draw(canvas, icon, r.x + @divTrunc(r.w - s, 2), r.y + @divTrunc(r.h - s, 2), s, color);
}

pub fn drawToolbar(self: *Editor, canvas: *Canvas) void {
    if (self.toolbar_rect.isEmpty()) return;
    const now = motion.now();
    const alpha = self.tb_alpha.at(now);
    const th = self.theme;
    const f = self.uf();
    const tb = self.toolbar_rect;
    var foot = shadowFootprint(self, tb, th.bar_shadow);
    if (!self.panel_rect.isEmpty()) foot = Rect.unite(foot, shadowFootprint(self, self.panel_rect, th.bar_shadow));
    const snap = if (alpha < 1) Snapshot.take(self.alloc, canvas, foot) else null;

    if (!self.panel_rect.isEmpty()) {
        drawMaterial(self, canvas, .panel, self.panel_rect, theme.bar_radius * f, th.bar_shadow);
        const pad = self.sc(theme.bar_pad);
        const fs = theme.font_small * f;
        text_mod.draw(canvas, self.panel_rect.x + pad + self.sc(8), self.panel_rect.y + @divTrunc(self.panel_rect.h - text_mod.height(fs), 2), fs, th.muted, "Beautify");
    }
    drawMaterial(self, canvas, .bar, tb, theme.bar_radius * f, th.bar_shadow);
    for (self.seps[0..self.n_seps]) |sp| canvas.fillRect(sp.x, sp.y, sp.w, sp.h, th.hairline);

    // the sliding accent fill of the active tool
    for (self.buttons.items) |b| {
        if (b.kind == .tool and toolButtonActive(self, b.kind.tool)) {
            const ax = tb.x + @as(i32, @intFromFloat(@round(self.act_x.at(now))));
            const ay = tb.y + @as(i32, @intFromFloat(@round(self.act_y.at(now))));
            canvas.fillRoundRectAA(ax, ay, b.rect.w, b.rect.h, theme.button_radius * f, th.accent);
        }
    }

    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .bar and b.layer != .panel) continue;
        const active = buttonActive(self, b.kind);
        const hv = hoverAmount(self, bi);
        const rad = theme.button_radius * f;
        const r = b.rect;
        switch (b.kind) {
            .copy => {
                canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.mix(th.accent, th.accent_hover, hv));
                const is = self.sc(16);
                icons.draw(canvas, .copy, r.x + self.sc(10), r.y + @divTrunc(r.h - is, 2), is, th.on_accent);
                const fs = theme.font_label * f;
                text_mod.drawStyled(canvas, r.x + self.sc(10) + is + self.sc(6), r.y + @divTrunc(r.h - text_mod.heightStyled(fs, .bold), 2), fs, th.on_accent, .bold, "Copy");
            },
            .colors => {
                canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.mix(th.hover, th.pressed, if (active) 1 else hv));
                const cx = ff(r.x) + 8.0 * f + 9.0 * f;
                const cy = ff(r.y) + ff(r.h) / 2.0;
                const col = self.color();
                canvas.ringAA(cx, cy, 10.5 * f, 3.0 * f, theme.withAlpha(col, 0x99));
                canvas.ringAA(cx, cy, 10.0 * f, 2.0 * f, th.material_solid);
                canvas.fillCircleAA(cx, cy, 9.0 * f, col);
                if (col & 0xFFFFFF == 0xFFFFFF or (col & 0xFFFFFF) == 0x1C1C1E) canvas.ringAA(cx, cy, 8.5 * f, 1.0 * f, 0x59808080);
                const cs = self.sc(12);
                icons.draw(canvas, .chevron_down, r.x + self.sc(8 + 18 + 8), r.y + @divTrunc(r.h - cs, 2), cs, th.muted);
            },
            .background => {
                if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hv));
                drawBackgroundSwatch(self, canvas, r.expand(-self.sc(8)));
            },
            else => {
                const on_accent = active and b.kind == .tool;
                if (!on_accent) {
                    if (active) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.pressed);
                    if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hv));
                }
                const fg: u32 = if (on_accent) th.on_accent else if (active and b.layer == .panel) th.accent else th.fg;
                if (kindIcon(self, b.kind)) |ic| drawIconIn(self, canvas, ic, r, theme.icon, fg);
            },
        }
        if (self.focus == bi) focusRing(self, canvas, r, rad);
    }
    if (snap) |s| s.restore(self.alloc, canvas, alpha);
}

fn drawBackgroundSwatch(self: *const Editor, canvas: *Canvas, r: Rect) void {
    const bg = self.beautify.background();
    const s: u32 = @intCast(@min(64, @min(r.w, r.h)));
    var px: [64 * 64]u32 = @splat(0);
    if (bg.transparent()) {
        const cell = @max(2, s / 4);
        for (0..s) |yy| for (0..s) |xx| {
            px[yy * s + xx] = if ((xx / cell + yy / cell) % 2 == 0) 0xFFFFFFFF else 0xFFB8BEC6;
        };
    } else effects.gradient(&px, s, s, .{ .x = 0, .y = 0, .w = @intCast(s), .h = @intCast(s) }, bg.from, bg.to);
    effects.blitRounded(canvas.px, @intCast(canvas.w), @intCast(canvas.h), &px, s, s, r.x, r.y, @intFromFloat(5 * self.uf()));
    shapes_mod.roundRectRing(canvas, .{ .x = r.x, .y = r.y, .w = @intCast(s), .h = @intCast(s) }, 5 * self.uf(), 1, 0x40808080);
}

// --- popover and menu ---

fn segOn(self: *const Editor, s: Seg) bool {
    const target = targetTool(self);
    const st = self.styles.get(target);
    const fixed = if (self.textHandleShape()) |i| self.doc.shapes.items[i].box_w > 0 else false;
    const mode = if (self.selected) |i| self.doc.shapes.items[i].tool else self.tool;
    return switch (s) {
        .outline => st & 1 == 0,
        .filled, .pill => st & 1 != 0,
        .plain => st & 1 == 0,
        .rounded => st & 2 != 0,
        .mode_blur => mode == .blur,
        .mode_pixelate => mode == .pixelate,
        .mode_solid => mode == .redact,
        .width_fit => !fixed,
        .width_fixed => fixed,
    };
}

fn drawPopover(self: *Editor, canvas: *Canvas) void {
    const now = motion.now();
    const p = self.pop_open.at(now);
    const th = self.theme;
    const f = self.uf();
    const pr = self.pop_rect;
    // grow from 96% around the side facing the toolbar
    const sc_k = 0.96 + 0.04 * p;
    const gw: i32 = @intFromFloat(@round(ff(pr.w) * sc_k));
    const gh: i32 = @intFromFloat(@round(ff(pr.h) * sc_k));
    const gy = if (pr.y < self.toolbar_rect.y) pr.bottom() - gh else pr.y;
    const grown = Rect{ .x = pr.x + @divTrunc(pr.w - gw, 2), .y = gy, .w = gw, .h = gh };
    const sh = th.popover_shadow;
    const snap = if (p < 1) Snapshot.take(self.alloc, canvas, shadowFootprint(self, pr, sh)) else null;
    const radius = (if (self.popover == .more) theme.menu_radius else theme.popover_radius) * f;
    drawMaterial(self, canvas, .popover, grown, radius, sh);
    switch (self.popover) {
        .none => {},
        .colors => drawColorsContent(self, canvas),
        .more => drawMenuContent(self, canvas),
    }
    if (snap) |s| s.restore(self.alloc, canvas, p);
}

fn drawColorsContent(self: *Editor, canvas: *Canvas) void {
    const th = self.theme;
    const f = self.uf();
    const pr = self.pop_rect;
    const pad = self.sc(theme.popover_pad);
    var seg_bg_drawn: [4]i32 = @splat(std.math.minInt(i32));
    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .popover) continue;
        const r = b.rect;
        const cx = ff(r.x) + ff(r.w) / 2.0;
        const cy = ff(r.y) + ff(r.h) / 2.0;
        const hv = hoverAmount(self, bi);
        switch (b.kind) {
            .color => |ci| {
                const col = palette[ci];
                const rad = ff(r.w) / 2.0;
                const sel = !self.custom_active and self.color_idx == ci;
                if (sel) {
                    canvas.ringAA(cx, cy, rad + 3.0 * f, 2.0 * f, th.accent);
                } else if (hv > 0) {
                    canvas.ringAA(cx, cy, rad + 2.5 * f, 1.5 * f, theme.fade(th.hairline, 2 * hv));
                }
                canvas.fillCircleAA(cx, cy, rad, col);
                canvas.ringAA(cx, cy, rad - 0.5 * f, 1.0 * f, 0x59808080);
                if (self.focus == bi) focusRing(self, canvas, r.expand(self.sc(2)), rad + 2 * f);
            },
            .custom_color => {
                const rad = ff(r.w) / 2.0;
                drawConic(canvas, cx, cy, rad);
                if (self.custom_active) {
                    canvas.fillCircleAA(cx, cy, rad * 0.42, self.custom_color);
                    canvas.ringAA(cx, cy, rad * 0.42, 1.5 * f, 0xFFFFFFFF);
                    canvas.ringAA(cx, cy, rad + 3.0 * f, 2.0 * f, th.accent);
                } else if (hv > 0) canvas.ringAA(cx, cy, rad + 2.5 * f, 1.5 * f, theme.fade(th.hairline, 2 * hv));
                if (self.focus == bi) focusRing(self, canvas, r.expand(self.sc(2)), rad + 2 * f);
            },
            .thickness => {
                const fs = theme.font_small * f;
                const ly = r.y - self.sc(8) - text_mod.height(fs);
                text_mod.draw(canvas, pr.x + pad, ly, fs, th.muted, "Size");
                var buf: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&buf, "{d} px", .{self.thickness}) catch "?";
                text_mod.draw(canvas, pr.right() - pad - text_mod.width(fs, v), ly, fs, th.muted, v);
                const knob = 9.0 * f;
                const t = ff(self.thickness - 1) / 31.0;
                const track_h = self.sc(4);
                const ty = r.y + @divTrunc(r.h - track_h, 2);
                canvas.fillRoundRectAA(r.x, ty, r.w, track_h, ff(track_h) / 2, th.track);
                const kx = ff(r.x) + knob + t * (ff(r.w) - 2 * knob);
                canvas.fillRoundRectAA(r.x, ty, @intFromFloat(@round(kx - ff(r.x))), track_h, ff(track_h) / 2, th.accent);
                canvas.fillCircleAA(kx, cy + 1.0 * f, knob + 1.0 * f, 0x26000000);
                canvas.fillCircleAA(kx, cy + 0.5 * f, knob + 0.5 * f, 0x33000000);
                canvas.fillCircleAA(kx, cy, knob, 0xFFFFFFFF);
                if (self.focus == bi) focusRing(self, canvas, .{ .x = @intFromFloat(kx - knob), .y = @intFromFloat(cy - knob), .w = @intFromFloat(2 * knob), .h = @intFromFloat(2 * knob) }, knob);
            },
            .seg => |s| {
                // the trough behind each row, once
                const row_key = r.y;
                var seen = false;
                for (seg_bg_drawn) |k| seen = seen or k == row_key;
                if (!seen) {
                    for (&seg_bg_drawn) |*k| if (k.* == std.math.minInt(i32)) {
                        k.* = row_key;
                        break;
                    };
                    canvas.fillRoundRectAA(pr.x + pad, r.y - self.sc(2), pr.w - 2 * pad, r.h + self.sc(4), 9.0 * f, th.track);
                }
                const on = segOn(self, s);
                if (on) {
                    canvas.fillRoundRectAA(r.x, r.y + self.sc(1), r.w, r.h, 7.0 * f, 0x26000000);
                    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.seg_on);
                } else if (hv > 0) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, theme.fade(th.hover, hv));
                var kb: [32]u8 = undefined;
                const l = buttonLabel(self, b.kind, &kb).name;
                const fs = theme.font_small * f;
                const tw = text_mod.width(fs, l);
                text_mod.draw(canvas, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, if (on) th.fg else th.muted, l);
                if (self.focus == bi) focusRing(self, canvas, r, 7.0 * f);
            },
            else => {},
        }
    }
}

/// A hue wheel disc: the custom colour swatch.
fn drawConic(canvas: *Canvas, cx: f64, cy: f64, r: f64) void {
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const n: i32 = @intFromFloat(@ceil(2 * r + 2));
    var y = y0;
    while (y < y0 + n) : (y += 1) {
        var x = x0;
        while (x < x0 + n) : (x += 1) {
            const dx = ff(x) + 0.5 - cx;
            const dy = ff(y) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            const cov = std.math.clamp(r - d + 0.5, 0, 1);
            if (cov <= 0) continue;
            var hue = std.math.atan2(dx, -dy) * 180.0 / std.math.pi;
            if (hue < 0) hue += 360;
            const c = hsvToRgb(hue, 0.85, 1);
            canvas.blend(x, y, (c & 0xFFFFFF) | (@as(u32, @intFromFloat(@round(cov * 255))) << 24));
        }
    }
}

fn drawMenuContent(self: *Editor, canvas: *Canvas) void {
    const th = self.theme;
    const f = self.uf();
    for (self.buttons.items, 0..) |b, bi| {
        if (b.layer != .menu) continue;
        const r = b.rect;
        if (b.kind == .cancel) {
            canvas.fillRect(r.x + self.sc(10), r.y - self.sc(5), r.w - self.sc(20), 1, th.hairline);
        }
        const hot = (self.hover_btn >= 0 and @as(usize, @intCast(self.hover_btn)) == bi) or self.focus == bi;
        if (hot) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.accent);
        const fg = if (hot) th.on_accent else th.fg;
        const sub = if (hot) theme.withAlpha(th.on_accent, 0xBF) else th.muted;
        const is = self.sc(16);
        const checked = b.kind == .beautify and self.beautify.enabled;
        const icon: Icon = if (checked) .check else kindIcon(self, b.kind) orelse .more;
        icons.draw(canvas, icon, r.x + self.sc(10), r.y + @divTrunc(r.h - is, 2), is, if (checked and !hot) th.accent else fg);
        var kb: [32]u8 = undefined;
        const l = buttonLabel(self, b.kind, &kb);
        const fs = theme.font_label * f;
        text_mod.draw(canvas, r.x + self.sc(10) + is + self.sc(10), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, fg, l.name);
        const ks = theme.font_small * f;
        if (l.key.len > 0) text_mod.draw(canvas, r.right() - self.sc(10) - text_mod.width(ks, l.key), r.y + @divTrunc(r.h - text_mod.height(ks), 2), ks, sub, l.key);
    }
}

// --- tooltips ---

fn tooltipButton(self: *const Editor) ?Button {
    if (self.drag != .none) return null;
    if (self.focus) |fi| {
        if (fi < self.buttons.items.len) {
            const b = self.buttons.items[fi];
            if (b.layer != .menu) return b;
        }
    }
    if (self.mouse_pane == self.tb_pane and self.hover_btn >= 0 and self.hover_btn < self.buttons.items.len) {
        if (motion.now() - self.hover_since_ms < theme.tooltip_delay) return null;
        const b = self.buttons.items[@intCast(self.hover_btn)];
        if (b.layer == .menu or b.kind == .seg or b.kind == .thickness) return null;
        return b;
    }
    return null;
}

/// When the pending tooltip is due (0: none pending).
pub fn tooltipDueMs(self: *const Editor) i64 {
    if (self.hover_btn < 0 or self.hover_btn >= self.buttons.items.len or self.drag != .none) return 0;
    if (self.tip_drawn_for == self.hover_since_ms or self.mouse_pane != self.tb_pane) return 0;
    const b = self.buttons.items[@intCast(self.hover_btn)];
    if (b.layer == .menu or b.kind == .seg or b.kind == .thickness) return 0;
    return self.hover_since_ms + theme.tooltip_delay;
}

fn tooltipRect(self: *const Editor) ?Rect {
    const b = tooltipButton(self) orelse return null;
    var kb: [32]u8 = undefined;
    const l = buttonLabel(self, b.kind, &kb);
    const fs = theme.font_small * self.uf();
    var tw = text_mod.width(fs, l.name);
    if (l.key.len > 0) tw += self.sc(8) + text_mod.width(fs, l.key);
    const th = text_mod.height(fs) + self.sc(8);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const pw = tw + self.sc(20);
    const x = std.math.clamp(b.rect.x + @divTrunc(b.rect.w - pw, 2), 4, @max(4, w - pw - 4));
    // away from the selection: outside the toolbar, beyond the popover
    var top = b.rect.y;
    var bottom = b.rect.bottom();
    if (b.layer == .bar or b.layer == .panel) {
        top = self.toolbar_rect.y;
        bottom = self.toolbar_rect.bottom();
        if (!self.panel_rect.isEmpty()) {
            top = @min(top, self.panel_rect.y);
            bottom = @max(bottom, self.panel_rect.bottom());
        }
    }
    var y = if (self.tb_below) bottom + self.sc(8) else top - th - self.sc(8);
    if (y + th > h - 2 or y < 2) y = if (self.tb_below) top - th - self.sc(8) else bottom + self.sc(8);
    if (self.popover != .none and b.layer != .popover and Rect.intersect(.{ .x = x, .y = y, .w = pw, .h = th }, self.pop_rect) != null) return null;
    return .{ .x = x, .y = y, .w = pw, .h = th };
}

fn drawTooltip(self: *Editor, canvas: *Canvas) void {
    const b = tooltipButton(self) orelse return;
    self.tip_drawn_for = self.hover_since_ms;
    const r = tooltipRect(self) orelse return;
    var kb: [32]u8 = undefined;
    const l = buttonLabel(self, b.kind, &kb);
    const f = self.uf();
    const th = self.theme;
    const fs = theme.font_small * f;
    canvas.fillRoundRectAA(r.x, r.y + self.sc(2), r.w, r.h, 7.0 * f, 0x1F000000);
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 7.0 * f, th.pill_bg);
    const ty = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    text_mod.draw(canvas, r.x + self.sc(10), ty, fs, th.pill_fg, l.name);
    if (l.key.len > 0) text_mod.draw(canvas, r.right() - self.sc(10) - text_mod.width(fs, l.key), ty, fs, 0x99EBEBF5, l.key);
}

// --- colour picker ---

fn layoutPicker(self: *Editor) void {
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
        window.KEY_ESC, window.KEY_ENTER => {
            self.picker.open = false;
            return false;
        },
        window.KEY_BACKSPACE => {
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

fn drawPicker(self: *Editor, canvas: *Canvas) void {
    const p = self.picker.rect;
    const f = self.uf();
    const th = self.theme;
    drawMaterial(self, canvas, .picker, p, theme.popover_radius * f, th.popover_shadow);
    const sv = svRect(self);
    var y: i32 = 0;
    while (y < sv.h) : (y += 1) {
        const v = 1.0 - ff(y) / ff(sv.h - 1);
        var x: i32 = 0;
        while (x < sv.w) : (x += 1) {
            const s = ff(x) / ff(sv.w - 1);
            canvas.set(sv.x + x, sv.y + y, hsvToRgb(self.picker.h, s, v));
        }
    }
    shapes_mod.roundRectRing(canvas, sv, 2, 1, th.hairline);
    const hr = hueRect(self);
    y = 0;
    while (y < hr.h) : (y += 1) {
        const hue = 359.9 * ff(y) / ff(hr.h - 1);
        canvas.fillRect(hr.x, hr.y + y, hr.w, 1, hsvToRgb(hue, 1, 1));
    }
    // markers
    const mx: f64 = ff(sv.x) + self.picker.s * ff(sv.w);
    const my: f64 = ff(sv.y) + (1.0 - self.picker.v) * ff(sv.h);
    canvas.ringAA(mx, my, 7.5 * f, 1.0 * f, 0x66000000);
    canvas.ringAA(mx, my, 6.0 * f, 2.0 * f, 0xFFFFFFFF);
    const hy: i32 = hr.y + @as(i32, @intFromFloat(self.picker.h / 360.0 * ff(hr.h)));
    canvas.fillRoundRectAA(hr.x - self.sc(2), hy - self.sc(3), hr.w + self.sc(4), self.sc(6), 3 * f, 0x66000000);
    canvas.fillRoundRectAA(hr.x - self.sc(1), hy - self.sc(2), hr.w + self.sc(2), self.sc(4), 2 * f, 0xFFFFFFFF);
    // hex field and preview
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

pub fn hsvToRgb(h: f64, s: f64, v: f64) u32 {
    const c = v * s;
    const hp = @mod(h, 360.0) / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = v - c;
    const ri: u32 = @intFromFloat(@round((r + m) * 255.0));
    const gi: u32 = @intFromFloat(@round((g + m) * 255.0));
    const bi: u32 = @intFromFloat(@round((b + m) * 255.0));
    return 0xFF000000 | ri << 16 | gi << 8 | bi;
}

pub fn rgbToHsv(c: u32) [3]f64 {
    const r = ff(@intCast((c >> 16) & 0xFF)) / 255.0;
    const g = ff(@intCast((c >> 8) & 0xFF)) / 255.0;
    const b = ff(@intCast(c & 0xFF)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f64 = 0;
    if (d > 0) {
        if (mx == r) {
            h = 60.0 * @mod((g - b) / d, 6.0);
        } else if (mx == g) {
            h = 60.0 * ((b - r) / d + 2.0);
        } else {
            h = 60.0 * ((r - g) / d + 4.0);
        }
    }
    return .{ h, if (mx == 0) 0 else d / mx, mx };
}

// --- loupe ---

pub fn loupeVisible(self: *const Editor) bool {
    if (self.help_open) return false;
    const m = self.mouse;
    if (!self.screenRect().contains(m.x, m.y)) return false;
    return switch (self.drag) {
        .selecting, .resizing_sel => true,
        .none => self.doc.sel == null,
        else => false,
    };
}

const loupe_cells = 15;

fn loupeRect(self: *const Editor) ?Rect {
    if (!loupeVisible(self)) return null;
    const cell = @max(4, self.sc(8));
    const size = cell * loupe_cells;
    const label_h = text_mod.height(theme.font_small * self.uf()) + self.sc(8);
    const total_h = size + self.sc(6) + label_h;
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const off = self.sc(24);
    var x = self.mouse.x + off;
    var y = self.mouse.y + off;
    if (x + size > w) x = self.mouse.x - off - size;
    if (y + total_h > h) y = self.mouse.y - off - total_h;
    return .{ .x = x, .y = y, .w = size, .h = total_h };
}

fn drawLoupe(self: *Editor, canvas: *Canvas) void {
    const r = loupeRect(self) orelse return;
    const f = self.uf();
    const th = self.theme;
    const cell = @max(4, self.sc(8));
    const size = cell * loupe_cells;
    const ip = self.pn().view.toImg(self.mouse);
    const half: i32 = loupe_cells / 2;
    const iw: i32 = @intCast(self.img.width);
    const ih: i32 = @intCast(self.img.height);
    canvas.fillRoundRectAA(r.x - self.sc(2), r.y - self.sc(1), size + self.sc(4), size + self.sc(4), 10 * f, 0x40000000);
    var cy: i32 = 0;
    while (cy < loupe_cells) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < loupe_cells) : (cx += 1) {
            const sx = ip.x - half + cx;
            const sy = ip.y - half + cy;
            const c: u32 = if (sx < 0 or sy < 0 or sx >= iw or sy >= ih)
                0xFF101010
            else
                self.layer[@as(usize, @intCast(sy)) * self.img.width + @as(usize, @intCast(sx))];
            canvas.fillRect(r.x + cx * cell, r.y + cy * cell, cell, cell, c | 0xFF000000);
        }
    }
    // pixel grid and crosshair on the centre pixel
    var g: i32 = 1;
    while (g < loupe_cells) : (g += 1) {
        canvas.fillRect(r.x + g * cell, r.y, 1, size, 0x14FFFFFF);
        canvas.fillRect(r.x, r.y + g * cell, size, 1, 0x14FFFFFF);
    }
    const c0x = r.x + half * cell;
    const c0y = r.y + half * cell;
    canvas.fillRect(r.x, c0y, size, cell, theme.withAlpha(th.accent, 0x26));
    canvas.fillRect(c0x, r.y, cell, size, theme.withAlpha(th.accent, 0x26));
    canvas.rectOutline(c0x - 1, c0y - 1, cell + 2, cell + 2, 1, 0xFFFFFFFF);
    // rounded window onto the pixels: mask the corners with a ring
    const lr = Rect{ .x = r.x, .y = r.y, .w = size, .h = size };
    shapes_mod.roundRectRing(canvas, lr.expand(self.sc(3)), 10 * f + ff(self.sc(3)), ff(self.sc(6)) + 1, 0xFF1C1C1E);
    shapes_mod.roundRectRing(canvas, lr, 8 * f, 1.5 * f, 0xE6FFFFFF);
    // coordinates, and the selection size while dragging
    var buf: [64]u8 = undefined;
    const x_sym = if (text_mod.available()) "\u{00D7}" else "x";
    const label = if (self.drag != .none and self.doc.sel != null) blk: {
        const s = self.doc.sel.?.normalized();
        break :blk std.fmt.bufPrint(&buf, "{d} {s} {d}", .{ s.w, x_sym, s.h }) catch "?";
    } else std.fmt.bufPrint(&buf, "{d}, {d}", .{ std.math.clamp(ip.x, 0, iw), std.math.clamp(ip.y, 0, ih) }) catch "?";
    const fs = theme.font_small * f;
    const lh = text_mod.height(fs) + self.sc(8);
    const lw = text_mod.width(fs, label) + self.sc(20);
    const ly = r.y + size + self.sc(6);
    canvas.fillRoundRectAA(r.x + @divTrunc(size - lw, 2), ly, lw, lh, 7 * f, th.pill_bg);
    text_mod.draw(canvas, r.x + @divTrunc(size - text_mod.width(fs, label), 2), ly + self.sc(4), fs, th.pill_fg, label);
}

// --- help ---

const help_lines = [_][2][]const u8{
    .{ "Drag", "Select a region; drag inside to move it" },
    .{ "Shift / Alt + drag", "Square, circle, 45\u{00B0} lines; from the centre" },
    .{ "Space + drag", "Move the region or shape while drawing it" },
    .{ "Arrows / Shift", "Move selection or shape by 1 / 10 px" },
    .{ "Alt+Arrows", "Resize the selection" },
    .{ "V P L A R E M", "Select, pen, line, arrow, rect, ellipse, marker" },
    .{ "X (again)", "Blur, then pixelate, then solid redaction" },
    .{ "N  T", "Counter badge, text" },
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

fn helpRect(self: *const Editor) Rect {
    const fs = theme.font_label * self.uf();
    const lh = text_mod.height(fs) + self.sc(7);
    const pw = self.sc(620);
    const ph = lh * @as(i32, help_lines.len) + self.sc(76);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    return .{ .x = @divTrunc(w - pw, 2), .y = @max(4, @divTrunc(h - ph, 2)), .w = pw, .h = ph };
}

fn drawHelp(self: *Editor, canvas: *Canvas) void {
    const r = helpRect(self);
    const f = self.uf();
    const th = self.theme;
    drawMaterial(self, canvas, .help, r, theme.popover_radius * f, th.popover_shadow);
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

// --- copy notice ---

fn noticeMessage(self: *const Editor) []const u8 {
    return switch (self.copy_notice) {
        .none => "",
        .copying => "Copying\u{2026}",
        .copied => "Copied to clipboard",
        .failed => "Copy failed",
    };
}

fn noticeRect(self: *const Editor) Rect {
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
    drawMaterial(self, canvas, .notice, r, ff(r.h) / 2.0, th.bar_shadow);
    const icon_size = self.sc(22);
    const cx = ff(r.x + self.sc(14) + @divTrunc(icon_size, 2));
    const cy = ff(r.y) + ff(r.h) / 2.0;
    const is = self.sc(14);
    switch (self.copy_notice) {
        .none => {},
        .copying => canvas.ringAA(cx, cy, 9.0 * f, 2.0 * f, theme.withAlpha(accent, 0x80)),
        .copied => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, accent);
            icons.drawStroke(canvas, .check, @as(i32, @intFromFloat(cx)) - @divTrunc(is, 2), @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2), is, 3, 0xFFFFFFFF);
        },
        .failed => {
            canvas.fillCircleAA(cx, cy, 11.0 * f, accent);
            icons.drawStroke(canvas, .close, @as(i32, @intFromFloat(cx)) - @divTrunc(is, 2), @as(i32, @intFromFloat(cy)) - @divTrunc(is, 2), is, 3, 0xFFFFFFFF);
        },
    }
    text_mod.draw(canvas, r.x + self.sc(14) + icon_size + self.sc(10), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, th.fg, message);
}

test "hsv round trip" {
    for ([_]u32{ 0xFFE03131, 0xFF339AF0, 0xFFFFFFFF, 0xFF000000, 0xFF51CF66, 0xFF15AABF }) |c| {
        const hsv = rgbToHsv(c);
        const back = hsvToRgb(hsv[0], hsv[1], hsv[2]);
        inline for (.{ 16, 8, 0 }) |sh| {
            const a: i32 = @intCast((c >> sh) & 0xFF);
            const b: i32 = @intCast((back >> sh) & 0xFF);
            try std.testing.expect(@abs(a - b) <= 1);
        }
    }
}

test "every button has a script name and popover names are known" {
    try std.testing.expectEqualStrings("blur", buttonName(.{ .tool = .blur }));
    try std.testing.expectEqualStrings("red", buttonName(.{ .color = 0 }));
    try std.testing.expectEqualStrings("grey", buttonName(.{ .color = 10 }));
    try std.testing.expectEqualStrings("filled", buttonName(.{ .seg = .filled }));
    try std.testing.expectEqual(Layer.popover, nameLayer("cyan").?);
    try std.testing.expectEqual(Layer.menu, nameLayer("save_as").?);
    try std.testing.expect(nameLayer("copy") == null);
}
