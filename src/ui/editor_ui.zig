//! Editor chrome: selection overlay, responsive toolbar, colour picker,
//! magnifier loupe, help overlay and the procedural button icons. Every
//! piece has a footprint function so the editor repaints only those
//! rectangles (collectOverlays must cover everything drawChrome draws).

const std = @import("std");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const config = @import("../app/config.zig");
const window = @import("window.zig");
const shapes_mod = @import("shapes.zig");
const doc_mod = @import("doc.zig");
const editor_mod = @import("editor.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const RectList = editor_mod.RectList;
const Tool = shapes_mod.Tool;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;
const palette = shapes_mod.palette;
const handlePoints = shapes_mod.handlePoints;

pub const ui_bg: u32 = 0xF21D2126;
pub const ui_bg_hover: u32 = 0xFF3A3F42;
pub const ui_accent: u32 = 0xFF4DABF7;
pub const ui_fg: u32 = 0xFFE9ECEF;

pub const ButtonKind = union(enum) {
    tool: Tool,
    color: u3,
    custom_color,
    style,
    /// a text's width: fits the text, or fixed (lines wrap)
    text_width,
    thickness,
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
    help,
    cancel,
};

pub const Button = struct {
    rect: Rect,
    kind: ButtonKind,
    group: u8 = 0,
    row: u8 = 0,
};

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

pub const tool_list = [_]Tool{ .select, .pen, .line, .arrow, .rect, .ellipse, .highlight, .blur, .pixelate, .redact, .counter, .text };

pub fn buttonName(kind: ButtonKind) []const u8 {
    return switch (kind) {
        .tool => |t| @tagName(t),
        .color => |c| ([_][]const u8{ "red", "orange", "yellow", "green", "blue", "magenta", "white", "black" })[c],
        else => @tagName(kind),
    };
}

fn buttonLabel(self: *const Editor, kind: ButtonKind, buf: []u8) []const u8 {
    const label: []const u8, const action: ?config.Action, const fixed: []const u8 = switch (kind) {
        .tool => |t| switch (t) {
            .select => .{ "Select and move", .select, "" },
            .pen => .{ "Pen", .pen, "" },
            .line => .{ "Line", .line, "" },
            .arrow => .{ "Arrow", .arrow, "" },
            .rect => .{ "Rectangle", .rect, "" },
            .ellipse => .{ "Ellipse", .ellipse, "" },
            .highlight => .{ "Highlighter", .highlight, "" },
            .blur => .{ "Blur", .pixelate, "" },
            .pixelate => .{ "Pixelate", .pixelate, "" },
            .redact => .{ "Redact (solid box)", .pixelate, "" },
            .counter => .{ "Counter badge", .counter, "" },
            .text => .{ "Text", .text, "" },
        },
        .color => |c| return std.fmt.bufPrint(buf, "{s}  {d}", .{ ([_][]const u8{ "Red", "Orange", "Yellow", "Green", "Blue", "Magenta", "White", "Black" })[c], @as(u8, c) + 1 }) catch "Colour",
        .custom_color => .{ "Custom colour", null, "9" },
        .style => .{ "Fill / rounded / text background", .style, "" },
        .text_width => {
            const fixed = if (self.textHandleShape()) |i| self.doc.shapes.items[i].box_w > 0 else false;
            const what = if (fixed) "Width: fixed, lines wrap (click: fit text)" else "Width: fits text (click: fix it, lines wrap)";
            return std.fmt.bufPrint(buf, "{s}  Alt+W", .{what}) catch what;
        },
        .thickness => .{ "Size (wheel)", null, "- =" },
        .beautify => .{ "Beautify frame", .beautify, "" },
        .background => return std.fmt.bufPrint(buf, "Background: {s}", .{self.beautify.background().name}) catch "Background",
        .padding => return std.fmt.bufPrint(buf, "Padding: {s}", .{config.padding_names[self.beautify.padding]}) catch "Padding",
        .corners => .{ "Rounded corners", null, "" },
        .shadow => .{ "Shadow", null, "" },
        .undo => .{ "Undo", .undo, "" },
        .redo => .{ "Redo", .redo, "" },
        .copy => .{ "Copy and close", .copy, "" },
        .save => .{ "Save", .save, "" },
        .save_as => .{ "Save as...", .save_as, "" },
        .help => .{ "Shortcuts", null, "?" },
        .cancel => .{ "Close", null, "Esc" },
    };
    var kb: [32]u8 = undefined;
    const key = if (action) |a| config.bindName(self.binds[@backingInt(a)], &kb) else fixed;
    if (key.len == 0 or std.mem.eql(u8, key, "unset")) return std.fmt.bufPrint(buf, "{s}", .{label}) catch label;
    return std.fmt.bufPrint(buf, "{s}  {s}", .{ label, key }) catch label;
}

/// The tool whose options the toolbar shows: the edited/selected shape's.
fn targetTool(self: *const Editor) Tool {
    if (self.text) |t| return self.doc.shapes.items[t.idx].tool;
    if (self.selected) |i| return self.doc.shapes.items[i].tool;
    return self.tool;
}

// --- toolbar layout ---

pub fn layoutToolbar(self: *Editor) !void {
    self.buttons.clearRetainingCapacity();
    const sel_b = self.selBuf();
    const dragging = self.drag != .none and self.drag != .picking;
    if (sel_b == null or dragging) {
        self.toolbar_rect = Rect.empty;
        self.focus = null;
        return;
    }
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const btn = self.sc(34);
    const gap = self.sc(4);
    const ggap = self.sc(13);
    const pad = self.sc(8);
    const margin = self.sc(8);
    const chip_w = self.sc(48);

    const Item = struct { kind: ButtonKind, w: i32, group: u8 };
    var items: [48]Item = undefined;
    var n: usize = 0;
    for (tool_list) |t| {
        items[n] = .{ .kind = .{ .tool = t }, .w = btn, .group = 0 };
        n += 1;
    }
    switch (targetTool(self)) {
        .rect, .ellipse, .text => {
            items[n] = .{ .kind = .style, .w = btn, .group = 1 };
            n += 1;
        },
        else => {},
    }
    if (self.textHandleShape() != null) {
        items[n] = .{ .kind = .text_width, .w = btn, .group = 1 };
        n += 1;
    }
    items[n] = .{ .kind = .thickness, .w = chip_w, .group = 1 };
    n += 1;
    for (0..palette.len) |i| {
        items[n] = .{ .kind = .{ .color = @intCast(i) }, .w = btn, .group = 2 };
        n += 1;
    }
    items[n] = .{ .kind = .custom_color, .w = btn, .group = 2 };
    n += 1;
    items[n] = .{ .kind = .beautify, .w = btn, .group = 3 };
    n += 1;
    if (self.beautify.enabled) {
        for ([_]ButtonKind{ .background, .padding, .corners, .shadow }) |k| {
            items[n] = .{ .kind = k, .w = btn, .group = 3 };
            n += 1;
        }
    }
    for ([_]ButtonKind{ .undo, .redo, .copy, .save, .save_as, .help, .cancel }) |k| {
        items[n] = .{ .kind = k, .w = btn, .group = 4 };
        n += 1;
    }

    // flow layout: keep groups together, wrap inside one only if it is
    // wider than the screen
    const max_w = @max(btn, w - 2 * margin - 2 * pad);
    var xs: [48]i32 = undefined;
    var rows: [48]u8 = undefined;
    var x: i32 = 0;
    var row: u8 = 0;
    var content_w: i32 = 0;
    var i: usize = 0;
    while (i < n) {
        var j = i;
        var gw: i32 = 0;
        while (j < n and items[j].group == items[i].group) : (j += 1) gw += items[j].w + gap;
        gw -= gap;
        if (x > 0) {
            if (x + ggap + gw > max_w) {
                row += 1;
                x = 0;
            } else x += ggap;
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
    const nrows: i32 = @as(i32, row) + 1;
    const tb_w = content_w + 2 * pad;
    const tb_h = nrows * btn + (nrows - 1) * gap + 2 * pad;

    const s = self.frameRect(sel_b.?);
    const bx = std.math.clamp(s.x + @divTrunc(s.w - tb_w, 2), margin, @max(margin, w - tb_w - margin));
    var by = s.bottom() + self.sc(12);
    if (by + tb_h > h - margin) by = s.y - tb_h - self.sc(12);
    if (by < margin) by = s.bottom() - tb_h - self.sc(12);
    by = std.math.clamp(by, margin, @max(margin, h - tb_h - margin));
    self.toolbar_rect = .{ .x = bx, .y = by, .w = tb_w, .h = tb_h };
    for (items[0..n], 0..) |it, k| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = bx + pad + xs[k], .y = by + pad + @as(i32, rows[k]) * (btn + gap), .w = it.w, .h = btn },
            .kind = it.kind,
            .group = it.group,
            .row = rows[k],
        });
    }
    if (self.focus) |f| {
        if (f >= self.buttons.items.len) self.focus = self.buttons.items.len - 1;
    }
    if (self.picker.open) layoutPicker(self);
}

pub fn moveFocus(self: *Editor, dir: i32) void {
    const n: i32 = @intCast(self.buttons.items.len);
    if (n == 0) return;
    const cur: i32 = if (self.focus) |f| @intCast(f) else if (dir > 0) -1 else n;
    self.focus = @intCast(@mod(cur + dir, n));
}

// --- footprints ---

fn addOutline(list: *RectList, r: Rect, pad: i32) void {
    list.add(.{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.bottom() - pad, .w = r.w + 2 * pad, .h = 2 * pad });
    list.add(.{ .x = r.x - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
    list.add(.{ .x = r.right() - pad, .y = r.y + pad, .w = 2 * pad, .h = r.h - 2 * pad });
}

fn handleDrawRadius(self: *const Editor) f64 {
    return 5.5 * self.uf();
}

fn chromePad(self: *const Editor) i32 {
    return @as(i32, @intFromFloat(@ceil(handleDrawRadius(self) + 1.5 * self.uf()))) + 3;
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
    if (!self.toolbar_rect.isEmpty()) list.add(self.toolbar_rect.expand(self.sc(4)));
    if (tooltipRect(self)) |r| list.add(r.expand(1));
    if (self.picker.open and !self.toolbar_rect.isEmpty()) list.add(self.picker.rect.expand(self.sc(4)));
    if (self.copy_notice != .none) list.add(noticeRect(self).expand(self.sc(6)));
    if (self.help_open) list.add(helpRect(self).expand(self.sc(4)));
}

fn shapeChromeRect(self: *const Editor, i: usize) ?Rect {
    const s = &self.doc.shapes.items[i];
    return switch (s.handleKind()) {
        .endpoints => Rect.fromCorners(self.pn().view.toBuf(s.p0), self.pn().view.toBuf(s.p1)),
        else => self.pn().view.rectToBuf(s.frame()).expand(self.sc(3)),
    };
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
    if (self.picker.open and !self.toolbar_rect.isEmpty()) drawPicker(self, canvas);
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
    canvas.fillRect(r.x, r.y, r.w, r.h, 0xE61D2126);
    text_mod.draw(canvas, r.x + self.sc(2), r.y, fs, 0xFFFFFFFF, self.win.preedit());
    canvas.fillRect(r.x, r.bottom() - self.sc(2), r.w, @max(1, self.sc(1)), ui_accent);
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
    const rad = @as(f64, @floatFromInt(r.w)) / 2.0;
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, 0xB3000000);
    const in = @max(1, self.sc(1));
    canvas.fillRoundRectAA(r.x + in, r.y + in, r.w - 2 * in, r.h - 2 * in, rad - 1, if (fixed) ui_accent else 0xFFFFFFFF);
}

fn drawShapeChrome(self: *Editor, canvas: *Canvas, i: usize) void {
    const s = &self.doc.shapes.items[i];
    const f = self.uf();
    const hr = handleDrawRadius(self) * 0.85;
    switch (s.handleKind()) {
        .endpoints => {
            for ([_]Point{ s.p0, s.p1 }) |p| {
                const b = self.pn().view.toBuf(p);
                canvas.fillCircleAA(@floatFromInt(b.x), @floatFromInt(b.y), hr, 0xFFFFFFFF);
                canvas.ringAA(@floatFromInt(b.x), @floatFromInt(b.y), hr, 1.5 * f, ui_accent);
            }
        },
        else => {
            const r = shapeChromeRect(self, i).?;
            dashedRect(canvas, r, 0xFF4DABF7, 0x80FFFFFF);
            if (s.handleKind() == .box) {
                for (handlePoints(r)) |p| {
                    canvas.fillCircleAA(@floatFromInt(p.x), @floatFromInt(p.y), hr, 0xFFFFFFFF);
                    canvas.ringAA(@floatFromInt(p.x), @floatFromInt(p.y), hr, 1.5 * f, ui_accent);
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
        return std.fmt.bufPrint(buf, "{d} {s} {d}  ({d} {s} {d} framed)", .{ s.w, x, s.h, g.out_w, x, g.out_h }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} {s} {d}", .{ s.w, x, s.h }) catch "?";
}

fn dimsPillRect(self: *const Editor, s: Rect) Rect {
    var buf: [64]u8 = undefined;
    const label = dimsLabel(self, &buf);
    const w: i32 = @intCast(self.pn().width);
    const fs = 13.0 * self.uf();
    const tw = text_mod.width(fs, label);
    const ph = text_mod.height(fs) + self.sc(8);
    const fr = self.frameRect(s);
    var lx = fr.x;
    var ly = fr.y - ph - self.sc(8);
    if (ly < 6) ly = fr.y + self.sc(8);
    if (lx + tw + self.sc(18) > w) lx = w - tw - self.sc(18);
    if (lx < 6) lx = 6;
    return .{ .x = lx, .y = ly, .w = tw + self.sc(16), .h = ph };
}

fn hintText() []const u8 {
    return if (text_mod.available())
        "Drag to select  \u{00B7}  Enter to copy  \u{00B7}  ? for shortcuts"
    else
        "Drag to select  -  Enter to copy  -  ? for shortcuts";
}

fn hintRect(self: *const Editor) Rect {
    const fs = 14.0 * self.uf();
    const tw = text_mod.width(fs, hintText());
    const ph = text_mod.height(fs) + self.sc(14);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    return .{ .x = @divTrunc(w - tw, 2) - self.sc(18), .y = h - ph - self.sc(48), .w = tw + self.sc(36), .h = ph };
}

pub fn drawSelectionChrome(self: *Editor, canvas: *Canvas) void {
    const f = self.uf();
    if (self.selBuf()) |s| {
        canvas.rectOutline(s.x - 2, s.y - 2, s.w + 4, s.h + 4, 1, 0x59000000);
        canvas.rectOutline(s.x - 1, s.y - 1, s.w + 2, s.h + 2, 1, 0xFFFFFFFF);
        if (self.tool == .select and self.drag == .none and self.selected == null) {
            const small = s.w < 4 * self.handleRadius() or s.h < 4 * self.handleRadius();
            for (handlePoints(s), 0..) |p, i| {
                if (small and i % 2 == 1) continue;
                const px: f64 = @floatFromInt(p.x);
                const py: f64 = @floatFromInt(p.y);
                canvas.fillCircleAA(px, py, handleDrawRadius(self), 0xFFFFFFFF);
                canvas.ringAA(px, py, handleDrawRadius(self), 1.5 * f, 0xB3000000);
            }
        }
        var buf: [64]u8 = undefined;
        const label = dimsLabel(self, &buf);
        const r = dimsPillRect(self, s);
        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, @as(f64, @floatFromInt(r.h)) / 2.0, 0xE6191D21);
        text_mod.draw(canvas, r.x + self.sc(8), r.y + self.sc(4), 13.0 * f, ui_fg, label);
    }
    if (self.show_hint) {
        // first run only: a quiet pill, gone at the first click or key
        self.hint_seen = true;
        const r = hintRect(self);
        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, @as(f64, @floatFromInt(r.h)) / 2.0, 0xD91D2126);
        text_mod.draw(canvas, r.x + self.sc(18), r.y + self.sc(7), 14.0 * f, ui_fg, hintText());
    }
}

pub fn drawToolbar(self: *Editor, canvas: *Canvas) void {
    if (self.toolbar_rect.isEmpty()) return;
    const tb = self.toolbar_rect;
    const f = self.uf();
    canvas.fillRoundRectAA(tb.x - 1, tb.y + self.sc(2), tb.w + 2, tb.h + self.sc(2), 14.0 * f, 0x38000000);
    canvas.fillRoundRectAA(tb.x, tb.y, tb.w, tb.h, 13.0 * f, ui_bg);

    const target = targetTool(self);
    for (self.buttons.items, 0..) |b, bi| {
        if (bi > 0) {
            const p = self.buttons.items[bi - 1];
            if (p.group != b.group and p.row == b.row) {
                const sx = @divTrunc(p.rect.right() + b.rect.x, 2);
                canvas.fillRect(sx, b.rect.y + self.sc(8), 1, b.rect.h - self.sc(16), 0x26FFFFFF);
            }
        }
        const hovered = self.mouse_pane == self.tb_pane and b.rect.contains(self.mouse.x, self.mouse.y);
        const active = switch (b.kind) {
            .tool => |t| t == self.tool,
            .color => |c| c == self.color_idx and !self.custom_active,
            .custom_color => self.custom_active or self.picker.open,
            .beautify => self.beautify.enabled,
            .corners => self.beautify.rounded,
            .shadow => self.beautify.shadow,
            .help => self.help_open,
            .text_width => if (self.textHandleShape()) |i| self.doc.shapes.items[i].box_w > 0 else false,
            else => false,
        };
        const swatch = switch (b.kind) {
            .color, .custom_color, .thickness, .background => true,
            else => false,
        };
        if (active and !swatch) {
            canvas.fillRoundRectAA(b.rect.x, b.rect.y, b.rect.w, b.rect.h, 9.0 * f, ui_accent);
        } else if (hovered) {
            canvas.fillRoundRectAA(b.rect.x, b.rect.y, b.rect.w, b.rect.h, 9.0 * f, 0x24FFFFFF);
        }
        const fg: u32 = if (active and !swatch) 0xFF14181C else ui_fg;
        drawButtonIcon(self, canvas, b, fg, active, target);
        if (self.focus == bi) {
            const r = b.rect.expand(-1);
            canvas.fillRoundRectAA(r.x, r.y, r.w, 2, 1, 0xFFFFFFFF);
            canvas.fillRoundRectAA(r.x, r.bottom() - 2, r.w, 2, 1, 0xFFFFFFFF);
            canvas.fillRect(r.x, r.y + 2, 2, r.h - 4, 0xFFFFFFFF);
            canvas.fillRect(r.right() - 2, r.y + 2, 2, r.h - 4, 0xFFFFFFFF);
        }
    }
    drawTooltip(self, canvas);
}

fn tooltipButton(self: *const Editor) ?Button {
    if (self.drag != .none) return null;
    if (self.mouse_pane == self.tb_pane and self.hover_btn >= 0 and self.hover_btn < self.buttons.items.len) return self.buttons.items[@intCast(self.hover_btn)];
    if (self.focus) |fi| {
        if (fi < self.buttons.items.len) return self.buttons.items[fi];
    }
    return null;
}

fn tooltipRect(self: *const Editor) ?Rect {
    const b = tooltipButton(self) orelse return null;
    var buf: [96]u8 = undefined;
    const label = buttonLabel(self, b.kind, &buf);
    const fs = 12.5 * self.uf();
    const tw = text_mod.width(fs, label);
    const th = text_mod.height(fs) + self.sc(8);
    const w: i32 = @intCast(self.pn().width);
    var x = b.rect.x + @divTrunc(b.rect.w - tw, 2) - self.sc(8);
    x = std.math.clamp(x, 2, @max(2, w - tw - self.sc(16) - 2));
    var y = self.toolbar_rect.y - th - self.sc(6);
    if (y < 2) y = self.toolbar_rect.bottom() + self.sc(6);
    return .{ .x = x, .y = y, .w = tw + self.sc(16), .h = th };
}

fn drawTooltip(self: *Editor, canvas: *Canvas) void {
    const b = tooltipButton(self) orelse return;
    const r = tooltipRect(self).?;
    var buf: [96]u8 = undefined;
    const label = buttonLabel(self, b.kind, &buf);
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 6.0 * self.uf(), 0xF2101316);
    text_mod.draw(canvas, r.x + self.sc(8), r.y + self.sc(4), 12.5 * self.uf(), ui_fg, label);
}

// --- colour picker ---

fn layoutPicker(self: *Editor) void {
    var anchor = self.toolbar_rect;
    for (self.buttons.items) |b| {
        if (b.kind == .custom_color) anchor = b.rect;
    }
    const pw = self.sc(220);
    const ph = self.sc(216);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    const x = std.math.clamp(anchor.x + @divTrunc(anchor.w - pw, 2), 4, @max(4, w - pw - 4));
    var y = self.toolbar_rect.y - ph - self.sc(8);
    if (y < 4) y = self.toolbar_rect.bottom() + self.sc(8);
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
            self.picker.s = std.math.clamp(@as(f64, @floatFromInt(m.x - r.x)) / @as(f64, @floatFromInt(r.w)), 0, 1);
            self.picker.v = 1.0 - std.math.clamp(@as(f64, @floatFromInt(m.y - r.y)) / @as(f64, @floatFromInt(r.h)), 0, 1);
        },
        .hue => {
            const r = hueRect(self);
            self.picker.h = 359.9 * std.math.clamp(@as(f64, @floatFromInt(m.y - r.y)) / @as(f64, @floatFromInt(r.h)), 0, 1);
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
    canvas.fillRoundRectAA(p.x, p.y + self.sc(2), p.w, p.h, 12.0 * f, 0x40000000);
    canvas.fillRoundRectAA(p.x, p.y, p.w, p.h, 12.0 * f, 0xFA1D2126);
    const sv = svRect(self);
    var y: i32 = 0;
    while (y < sv.h) : (y += 1) {
        const v = 1.0 - @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(sv.h - 1));
        var x: i32 = 0;
        while (x < sv.w) : (x += 1) {
            const s = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(sv.w - 1));
            canvas.set(sv.x + x, sv.y + y, hsvToRgb(self.picker.h, s, v));
        }
    }
    const hr = hueRect(self);
    y = 0;
    while (y < hr.h) : (y += 1) {
        const hue = 359.9 * @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(hr.h - 1));
        canvas.fillRect(hr.x, hr.y + y, hr.w, 1, hsvToRgb(hue, 1, 1));
    }
    // markers
    const mx: f64 = @as(f64, @floatFromInt(sv.x)) + self.picker.s * @as(f64, @floatFromInt(sv.w));
    const my: f64 = @as(f64, @floatFromInt(sv.y)) + (1.0 - self.picker.v) * @as(f64, @floatFromInt(sv.h));
    canvas.ringAA(mx, my, 6.0 * f, 2.0 * f, 0xFFFFFFFF);
    canvas.ringAA(mx, my, 7.5 * f, 1.0 * f, 0x80000000);
    const hy: i32 = hr.y + @as(i32, @intFromFloat(self.picker.h / 360.0 * @as(f64, @floatFromInt(hr.h))));
    canvas.rectOutline(hr.x - 2, hy - 2, hr.w + 4, 5, 2, 0xFFFFFFFF);
    // hex field and preview
    const fy = sv.bottom() + self.sc(10);
    const fh = self.sc(24);
    canvas.fillRoundRectAA(sv.x, fy, fh, fh, 6.0 * f, pickerColor(self));
    canvas.fillRoundRectAA(sv.x + fh + self.sc(8), fy, p.right() - self.sc(12) - (sv.x + fh + self.sc(8)), fh, 6.0 * f, 0xFF2C3136);
    var buf: [16]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "#{s}", .{self.picker.hex[0..self.picker.hex_len]}) catch "#";
    const fs = 13.0 * f;
    const tx = sv.x + fh + self.sc(16);
    const ty = fy + @divTrunc(fh - text_mod.height(fs), 2);
    text_mod.draw(canvas, tx, ty, fs, ui_fg, label);
    canvas.fillRect(tx + text_mod.width(fs, label) + 1, ty, @max(1, self.sc(1)), text_mod.height(fs), ui_accent);
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
    const r = @as(f64, @floatFromInt((c >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((c >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(c & 0xFF)) / 255.0;
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
    const label_h = text_mod.height(12.0 * self.uf()) + self.sc(8);
    const total_h = size + self.sc(4) + label_h;
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
    const cell = @max(4, self.sc(8));
    const size = cell * loupe_cells;
    const ip = self.pn().view.toImg(self.mouse);
    const half: i32 = loupe_cells / 2;
    const iw: i32 = @intCast(self.img.width);
    const ih: i32 = @intCast(self.img.height);
    canvas.fillRoundRectAA(r.x - 1, r.y - 1, size + 2, size + 2, 3, 0xFF000000);
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
        canvas.fillRect(r.x + g * cell, r.y, 1, size, 0x1AFFFFFF);
        canvas.fillRect(r.x, r.y + g * cell, size, 1, 0x1AFFFFFF);
    }
    const c0x = r.x + half * cell;
    const c0y = r.y + half * cell;
    canvas.fillRect(r.x, c0y, size, cell, 0x264DABF7);
    canvas.fillRect(c0x, r.y, cell, size, 0x264DABF7);
    canvas.rectOutline(c0x - 1, c0y - 1, cell + 2, cell + 2, 1, 0xFFFFFFFF);
    canvas.rectOutline(r.x, r.y, size, size, 1, 0x66FFFFFF);
    // coordinates, and the selection size while dragging
    var buf: [64]u8 = undefined;
    const x_sym = if (text_mod.available()) "\u{00D7}" else "x";
    const label = if (self.drag != .none and self.doc.sel != null) blk: {
        const s = self.doc.sel.?.normalized();
        break :blk std.fmt.bufPrint(&buf, "{d} {s} {d}", .{ s.w, x_sym, s.h }) catch "?";
    } else std.fmt.bufPrint(&buf, "{d}, {d}", .{ std.math.clamp(ip.x, 0, iw), std.math.clamp(ip.y, 0, ih) }) catch "?";
    const fs = 12.0 * self.uf();
    const lh = text_mod.height(fs) + self.sc(8);
    const ly = r.y + size + self.sc(4);
    canvas.fillRoundRectAA(r.x, ly, size, lh, @as(f64, @floatFromInt(lh)) / 2.0, 0xF2191D21);
    text_mod.draw(canvas, r.x + @divTrunc(size - text_mod.width(fs, label), 2), ly + self.sc(4), fs, ui_fg, label);
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
    const fs = 13.5 * self.uf();
    const lh = text_mod.height(fs) + self.sc(6);
    const pw = self.sc(600);
    const ph = lh * @as(i32, help_lines.len) + self.sc(64);
    const w: i32 = @intCast(self.pn().width);
    const h: i32 = @intCast(self.pn().height);
    return .{ .x = @divTrunc(w - pw, 2), .y = @max(4, @divTrunc(h - ph, 2)), .w = pw, .h = ph };
}

fn drawHelp(self: *Editor, canvas: *Canvas) void {
    const r = helpRect(self);
    const f = self.uf();
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 14.0 * f, 0xF51A1E23);
    const fs = 13.5 * f;
    const lh = text_mod.height(fs) + self.sc(6);
    text_mod.draw(canvas, r.x + self.sc(24), r.y + self.sc(16), 16.0 * f, 0xFFFFFFFF, "Keyboard shortcuts");
    var y = r.y + self.sc(48);
    for (help_lines) |l| {
        text_mod.draw(canvas, r.x + self.sc(24), y, fs, ui_accent, l[0]);
        text_mod.draw(canvas, r.x + self.sc(240), y, fs, ui_fg, l[1]);
        y += lh;
    }
}

// --- copy notice ---

fn noticeMessage(self: *const Editor) []const u8 {
    return switch (self.copy_notice) {
        .none => "",
        .copying => "Copying...",
        .copied => "Copied to clipboard",
        .failed => "Copy failed",
    };
}

fn noticeRect(self: *const Editor) Rect {
    const window_width: i32 = @intCast(self.pn().width);
    const window_height: i32 = @intCast(self.pn().height);
    const fs = 15.0 * self.uf();
    const mw = text_mod.width(fs, noticeMessage(self));
    const mh = text_mod.height(fs);
    const icon_size = self.sc(22);
    const margin = self.sc(24);
    var nw = @max(self.sc(220), icon_size + self.sc(12) + mw + self.sc(18) * 2);
    nw = @min(nw, @max(self.sc(160), window_width - margin * 2));
    const nh = @max(self.sc(52), @max(icon_size, mh) + self.sc(12) * 2);
    var nx = window_width - nw - margin;
    if (nx < margin) nx = @divTrunc(window_width - nw, 2);
    if (nx < margin) nx = margin;
    var ny = window_height - nh - margin;
    if (ny < margin) ny = margin;
    return .{ .x = nx, .y = ny, .w = nw, .h = nh };
}

pub fn drawCopyNotice(self: *Editor, canvas: *Canvas) void {
    const ui_scale = self.uf();
    const r = noticeRect(self);
    const message = noticeMessage(self);
    const fs = 15.0 * ui_scale;
    const accent: u32 = switch (self.copy_notice) {
        .none => return,
        .copying, .copied => 0xFF4DABF7,
        .failed => 0xF2E03131,
    };
    canvas.fillRoundRectAA(r.x + self.sc(2), r.y + self.sc(5), r.w, r.h, 17.0 * ui_scale, 0x44000000);
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 17.0 * ui_scale, 0x35FFFFFF);
    canvas.fillRoundRectAA(r.x + 1, r.y + 1, r.w - 2, r.h - 2, 16.0 * ui_scale, 0xF21A2028);
    canvas.fillRoundRectAA(r.x + self.sc(9), r.y + self.sc(10), self.sc(3), r.h - self.sc(20), 1.5 * ui_scale, accent);
    const icon_size = self.sc(22);
    const content_x = r.x + self.sc(18) + self.sc(5);
    const icon_cx: f64 = @floatFromInt(content_x + @divTrunc(icon_size, 2));
    const icon_cy: f64 = @floatFromInt(r.y + @divTrunc(r.h, 2));
    drawCopyNoticeIcon(canvas, self.copy_notice, icon_cx, icon_cy, ui_scale, accent);
    const text_x = content_x + icon_size + self.sc(12);
    const text_y = r.y + @divTrunc(r.h - text_mod.height(fs), 2);
    text_mod.draw(canvas, text_x, text_y, fs, 0xFFEFF4FA, message);
}

fn drawCopyNoticeIcon(canvas: *Canvas, copy_notice: editor_mod.CopyNotice, cx: f64, cy: f64, scale: f64, accent: u32) void {
    switch (copy_notice) {
        .none => return,
        .copying => {
            canvas.ringAA(cx, cy, 9.5 * scale, 2.0 * scale, 0x804DABF7);
            canvas.fillCircleAA(cx + 6.5 * scale, cy - 6.5 * scale, 2.4 * scale, accent);
        },
        .copied => {
            canvas.fillCircleAA(cx, cy, 10.5 * scale, accent);
            const check = [_]Point{
                .{ .x = @intFromFloat(cx - 5.2 * scale), .y = @intFromFloat(cy + 0.2 * scale) },
                .{ .x = @intFromFloat(cx - 1.4 * scale), .y = @intFromFloat(cy + 4.1 * scale) },
                .{ .x = @intFromFloat(cx + 6.1 * scale), .y = @intFromFloat(cy - 5.0 * scale) },
            };
            canvas.strokePolylineAA(check[0..], 2.2 * scale, 0xFFFFFFFF);
        },
        .failed => {
            canvas.fillCircleAA(cx, cy, 10.5 * scale, accent);
            drawX(canvas, cx, cy, 4.6 * scale, 2.1 * scale, 0xFFFFFFFF);
        },
    }
}

fn drawX(canvas: *Canvas, cx: f64, cy: f64, r: f64, width: f64, c: u32) void {
    const a = [_]Point{ .{ .x = @intFromFloat(cx - r), .y = @intFromFloat(cy - r) }, .{ .x = @intFromFloat(cx + r), .y = @intFromFloat(cy + r) } };
    const b = [_]Point{ .{ .x = @intFromFloat(cx - r), .y = @intFromFloat(cy + r) }, .{ .x = @intFromFloat(cx + r), .y = @intFromFloat(cy - r) } };
    canvas.strokePolylineAA(a[0..], width, c);
    canvas.strokePolylineAA(b[0..], width, c);
}

// --- icons ---

fn drawButtonIcon(self: *Editor, canvas: *Canvas, b: Button, fg: u32, active: bool, target: Tool) void {
    const ipad = self.sc(9);
    const x = b.rect.x + ipad;
    const y = b.rect.y + ipad;
    const si = b.rect.h - ipad * 2; // icon box (square)
    const sf: f64 = @floatFromInt(si);
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const f = self.uf();
    const cxf = @as(f64, @floatFromInt(b.rect.x)) + @as(f64, @floatFromInt(b.rect.w)) / 2.0;
    const cyf = yf + sf / 2.0;
    const P = Point;
    const thin = @max(2, self.sc(2));
    switch (b.kind) {
        .tool => |t| switch (t) {
            .select => {
                // pointer arrow
                canvas.fillTriangleAA(xf + sf * 0.18, yf, xf + sf * 0.18, yf + sf * 0.86, xf + sf * 0.78, yf + sf * 0.58, fg);
                canvas.strokePolylineAA(&[_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.45), .y = @intFromFloat(yf + sf * 0.6) },
                    .{ .x = @intFromFloat(xf + sf * 0.7), .y = @intFromFloat(yf + sf * 1.0) },
                }, sf * 0.16, fg);
            },
            .pen => {
                const tipx = xf + sf * 0.06;
                const tipy = yf + sf * 0.94;
                const bodye_x = xf + sf * 0.34;
                const bodye_y = yf + sf * 0.66;
                const body = [_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.88), .y = @intFromFloat(yf + sf * 0.12) },
                    .{ .x = @intFromFloat(bodye_x), .y = @intFromFloat(bodye_y) },
                };
                canvas.strokePolylineAA(body[0..], sf * 0.32, fg);
                canvas.fillTriangleAA(bodye_x - sf * 0.115, bodye_y - sf * 0.115, bodye_x + sf * 0.115, bodye_y + sf * 0.115, tipx, tipy, (fg & 0x00FFFFFF) | 0x99000000);
                canvas.fillCircleAA(tipx + sf * 0.03, tipy - sf * 0.03, sf * 0.085, if (active) fg else ui_accent);
            },
            .line => {
                const seg = [_]P{ .{ .x = x, .y = y + si }, .{ .x = x + si, .y = y } };
                canvas.strokePolylineAA(seg[0..], 2.0 * f, fg);
                canvas.fillCircleAA(xf + 1, yf + sf - 1, 2.0 * f, fg);
                canvas.fillCircleAA(xf + sf - 1, yf + 1, 2.0 * f, fg);
            },
            .arrow => shapes_mod.drawArrow(canvas, xf, yf + sf, xf + sf, yf, 2.0 * f, sf * 0.5, fg),
            .rect => canvas.rectOutline(x, y + @divTrunc(si, 8), si, si - @divTrunc(si, 4), thin, fg),
            .ellipse => canvas.ellipseRingAA(x, y + @divTrunc(si, 8), si, si - @divTrunc(si, 4), 2.0 * f, fg),
            .highlight => {
                canvas.strokePolylineAA(&[_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.02), .y = @intFromFloat(yf + sf * 0.95) },
                    .{ .x = @intFromFloat(xf + sf * 0.62), .y = @intFromFloat(yf + sf * 0.95) },
                }, sf * 0.17, if (active) (fg & 0x00FFFFFF) | 0x80000000 else 0xA6FFD43B);
                canvas.strokePolylineAA(&[_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.84), .y = @intFromFloat(yf + sf * 0.14) },
                    .{ .x = @intFromFloat(xf + sf * 0.50), .y = @intFromFloat(yf + sf * 0.48) },
                }, sf * 0.36, fg);
                canvas.fillTriangleAA(xf + sf * 0.37, yf + sf * 0.35, xf + sf * 0.63, yf + sf * 0.61, xf + sf * 0.22, yf + sf * 0.76, fg);
            },
            .blur => {
                // soft concentric discs
                canvas.fillCircleAA(cxf, cyf, sf * 0.5, (fg & 0x00FFFFFF) | 0x33000000);
                canvas.fillCircleAA(cxf, cyf, sf * 0.36, (fg & 0x00FFFFFF) | 0x55000000);
                canvas.fillCircleAA(cxf, cyf, sf * 0.22, (fg & 0x00FFFFFF) | 0xAA000000);
            },
            .pixelate => {
                const cell = @divTrunc(si, 4);
                var yy: i32 = 0;
                while (yy < 4) : (yy += 1) {
                    var xx: i32 = 0;
                    while (xx < 4) : (xx += 1) {
                        const dark = @mod(xx + yy, 2) != 0;
                        canvas.fillRect(x + xx * cell, y + yy * cell, cell, cell, if (dark) (fg & 0x00FFFFFF) | 0x59000000 else fg);
                    }
                }
            },
            .redact => {
                canvas.fillRoundRectAA(x, y + @divTrunc(si, 4), si, @divTrunc(si, 2), 2.0 * f, fg);
                canvas.fillRect(x, y + @divTrunc(si, 8) - thin, @divTrunc(si * 2, 3), thin, (fg & 0x00FFFFFF) | 0x80000000);
                canvas.fillRect(x, y + si - @divTrunc(si, 8), @divTrunc(si * 3, 4), thin, (fg & 0x00FFFFFF) | 0x80000000);
            },
            .counter => {
                canvas.ringAA(cxf, cyf, sf / 2.0, 2.0 * f, fg);
                const fs = sf * 0.62;
                text_mod.draw(canvas, @intFromFloat(cxf - @as(f64, @floatFromInt(text_mod.width(fs, "1"))) / 2.0), @intFromFloat(cyf - @as(f64, @floatFromInt(text_mod.height(fs))) / 2.0), fs, fg, "1");
            },
            .text => {
                const fs = sf * 0.95;
                text_mod.draw(canvas, @intFromFloat(cxf - @as(f64, @floatFromInt(text_mod.width(fs, "T"))) / 2.0), @intFromFloat(cyf - @as(f64, @floatFromInt(text_mod.height(fs))) / 2.0), fs, fg, "T");
            },
        },
        .color => |c| {
            canvas.fillCircleAA(cxf, cyf, 8.5 * f, palette[c]);
            if (active) {
                canvas.ringAA(cxf, cyf, 11.5 * f, 2.0 * f, 0xFFFFFFFF);
            } else if (palette[c] == 0xFF1A1A1A) {
                canvas.ringAA(cxf, cyf, 8.5 * f, 1.0 * f, 0x59FFFFFF);
            }
        },
        .custom_color => {
            // hue wheel with the custom colour in the middle
            var a: usize = 0;
            while (a < 12) : (a += 1) {
                const ang = @as(f64, @floatFromInt(a)) * std.math.pi / 6.0;
                canvas.fillCircleAA(cxf + @cos(ang) * 6.5 * f, cyf + @sin(ang) * 6.5 * f, 2.6 * f, hsvToRgb(@as(f64, @floatFromInt(a)) * 30.0, 0.85, 1));
            }
            canvas.fillCircleAA(cxf, cyf, 3.8 * f, self.custom_color);
            if (active) canvas.ringAA(cxf, cyf, 11.5 * f, 2.0 * f, 0xFFFFFFFF);
        },
        .style => {
            const filled = (self.styles.get(target) & 1) != 0;
            const rounded = (self.styles.get(target) & 2) != 0;
            const r = Rect{ .x = x, .y = y + @divTrunc(si, 8), .w = si, .h = si - @divTrunc(si, 4) };
            switch (target) {
                .text => {
                    if (filled) canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, sf * 0.3, fg) else shapes_mod.roundRectRing(canvas, r, sf * 0.3, 1.2 * f, (fg & 0x00FFFFFF) | 0x80000000);
                    const fs = sf * 0.7;
                    text_mod.draw(canvas, @intFromFloat(cxf - @as(f64, @floatFromInt(text_mod.width(fs, "A"))) / 2.0), @intFromFloat(cyf - @as(f64, @floatFromInt(text_mod.height(fs))) / 2.0), fs, if (filled) 0xFF14181C else fg, "A");
                },
                .ellipse => if (filled) shapes_mod.fillEllipseAA(canvas, r, fg) else canvas.ellipseRingAA(r.x, r.y, r.w, r.h, 2.0 * f, fg),
                else => {
                    const rad: f64 = if (rounded) sf * 0.3 else 0;
                    if (filled) {
                        canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, fg);
                    } else if (rounded) {
                        shapes_mod.roundRectRing(canvas, r, rad, 2.0 * f, fg);
                    } else canvas.rectOutline(r.x, r.y, r.w, r.h, thin, fg);
                },
            }
        },
        .text_width => {
            // wrapped lines against a right margin when fixed; one long
            // line between arrows when the box fits its text
            const lw = @max(1, self.sc(2));
            const fixed = if (self.textHandleShape()) |i| self.doc.shapes.items[i].box_w > 0 else false;
            if (fixed) {
                for ([_]i32{ 0, 1, 2 }, [_]f64{ 0.78, 0.62, 0.7 }) |row, frac| {
                    const ly = y + @divTrunc(si * (row * 2 + 1), 7);
                    canvas.fillRect(x, ly, @intFromFloat(sf * frac), lw, fg);
                }
                canvas.fillRect(x + si - lw, y, lw, si, fg);
            } else {
                canvas.fillRect(x, y + @divTrunc(si, 2) - @divTrunc(lw, 2), si, lw, fg);
                for ([_]f64{ 0, 1 }) |side| {
                    const tip = xf + side * sf;
                    const back = tip + (if (side == 0) sf * 0.28 else -sf * 0.28);
                    canvas.fillTriangleAA(tip, cyf, back, cyf - sf * 0.22, back, cyf + sf * 0.22, fg);
                }
            }
        },
        .thickness => {
            const pr = @min(8.0 * f, @max(1.5, @as(f64, @floatFromInt(self.thickness)) * f / 2.0));
            canvas.fillCircleAA(@as(f64, @floatFromInt(b.rect.x)) + 13.0 * f, @as(f64, @floatFromInt(b.rect.y + @divTrunc(b.rect.h, 2))), pr, self.color());
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{self.thickness}) catch "?";
            const fs = 13.0 * f;
            text_mod.draw(canvas, b.rect.x + self.sc(26), b.rect.y + @divTrunc(b.rect.h - text_mod.height(fs), 2), fs, 0xFFAAB2BA, label);
        },
        .beautify => {
            // framed picture on a gradient tile
            const bg = self.beautify.background();
            if (!active) {
                canvas.fillRoundRectAA(x, y, si, si, 3.0 * f, (bg.from & 0x00FFFFFF) | 0x80000000);
            }
            const inset = @divTrunc(si, 4);
            canvas.fillRoundRectAA(x + inset, y + inset, si - 2 * inset, si - 2 * inset, 2.0 * f, if (active) fg else 0xFFFFFFFF);
        },
        .background => {
            const bg = self.beautify.background();
            var px: [64 * 64]u32 = @splat(0);
            const s: u32 = @intCast(@min(64, si));
            if (bg.transparent()) {
                // checkerboard, the usual sign for "no background"
                const cell = @max(2, s / 4);
                for (0..s) |yy| for (0..s) |xx| {
                    px[yy * s + xx] = if ((xx / cell + yy / cell) % 2 == 0) 0xFFFFFFFF else 0xFFB8BEC6;
                };
            } else @import("../gfx/effects.zig").gradient(&px, s, s, .{ .x = 0, .y = 0, .w = @intCast(s), .h = @intCast(s) }, bg.from, bg.to);
            var yy: u32 = 0;
            while (yy < s) : (yy += 1) {
                var xx: u32 = 0;
                while (xx < s) : (xx += 1) canvas.set(x + @as(i32, @intCast(xx)), y + @as(i32, @intCast(yy)), px[yy * s + xx]);
            }
            canvas.rectOutline(x, y, @intCast(s), @intCast(s), 1, 0x66FFFFFF);
        },
        .padding => {
            // a picture inside a frame, the gap growing with the padding
            canvas.rectOutline(x, y, si, si, @max(1, self.sc(1.5)), fg);
            const gap: i32 = @divTrunc(si * @as(i32, self.beautify.padding), 9);
            const inner = si - 2 * gap - 2 * @max(1, self.sc(1.5));
            if (inner > 0) canvas.fillRect(x + @max(1, self.sc(1.5)) + gap, y + @max(1, self.sc(1.5)) + gap, inner, inner, (fg & 0x00FFFFFF) | 0xB0000000);
        },
        .corners => shapes_mod.roundRectRing(canvas, .{ .x = x, .y = y, .w = si, .h = si }, sf * 0.35, 2.0 * f, fg),
        .shadow => {
            const o = @divTrunc(si, 5);
            canvas.fillRoundRectAA(x + o, y + o, si - o, si - o, 3.0 * f, (fg & 0x00FFFFFF) | 0x59000000);
            canvas.fillRoundRectAA(x, y, si - o, si - o, 3.0 * f, fg);
        },
        .undo => drawArcArrow(canvas, cxf, cyf, sf * 0.42, 2.0 * f, fg, false),
        .redo => drawArcArrow(canvas, cxf, cyf, sf * 0.42, 2.0 * f, fg, true),
        .copy => {
            const o = @divTrunc(si, 4);
            canvas.fillRoundRectAA(x + o, y, si - o, si - o, 3.0 * f, (fg & 0x00FFFFFF) | 0x66000000);
            canvas.fillRoundRectAA(x, y + o, si - o, si - o, 3.0 * f, fg);
        },
        .save => {
            shapes_mod.drawArrow(canvas, xf + sf / 2.0, yf, xf + sf / 2.0, yf + sf - @as(f64, @floatFromInt(self.sc(4))), 2.0 * f, sf * 0.45, fg);
            canvas.fillRoundRectAA(x, y + si - self.sc(3), si, self.sc(3), 1.5 * f, fg);
        },
        .save_as => {
            shapes_mod.drawArrow(canvas, xf + sf * 0.35, yf, xf + sf * 0.35, yf + sf - @as(f64, @floatFromInt(self.sc(4))), 2.0 * f, sf * 0.4, fg);
            canvas.fillRoundRectAA(x, y + si - self.sc(3), si, self.sc(3), 1.5 * f, fg);
            canvas.fillCircleAA(xf + sf * 0.72, yf + sf * 0.5, 1.4 * f, fg);
            canvas.fillCircleAA(xf + sf * 0.86, yf + sf * 0.5, 1.4 * f, fg);
            canvas.fillCircleAA(xf + sf * 1.0, yf + sf * 0.5, 1.4 * f, fg);
        },
        .help => {
            const fs = sf * 0.95;
            text_mod.draw(canvas, @intFromFloat(cxf - @as(f64, @floatFromInt(text_mod.width(fs, "?"))) / 2.0), @intFromFloat(cyf - @as(f64, @floatFromInt(text_mod.height(fs))) / 2.0), fs, fg, "?");
        },
        .cancel => drawX(canvas, cxf, cyf, sf / 3.0, 2.5 * f, 0xFFFF6B6B),
    }
}

/// Curved undo/redo arrow: ~230 degree arc with an arrowhead at the end.
fn drawArcArrow(canvas: *Canvas, cx: f64, cy: f64, r: f64, width: f64, color: u32, mirrored: bool) void {
    var pts: [10]Point = undefined;
    const start: f64 = -60.0;
    const end: f64 = 170.0;
    for (&pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(pts.len - 1));
        const ang = (start + (end - start) * t) * std.math.pi / 180.0;
        const px = if (mirrored) cx - r * @cos(ang) else cx + r * @cos(ang);
        const py = cy - r * @sin(ang);
        p.* = .{ .x = @intFromFloat(px), .y = @intFromFloat(py) };
    }
    canvas.strokePolylineAA(pts[0..], width, color);
    const last = pts[pts.len - 1];
    const prev = pts[pts.len - 2];
    const dx: f64 = @floatFromInt(last.x - prev.x);
    const dy: f64 = @floatFromInt(last.y - prev.y);
    const len = @max(1.0, @sqrt(dx * dx + dy * dy));
    const ux = dx / len;
    const uy = dy / len;
    const head = r * 0.75;
    const lx: f64 = @floatFromInt(last.x);
    const ly: f64 = @floatFromInt(last.y);
    canvas.fillTriangleAA(
        lx + ux * head * 0.6,
        ly + uy * head * 0.6,
        lx - uy * head * 0.45 - ux * head * 0.3,
        ly + ux * head * 0.45 - uy * head * 0.3,
        lx + uy * head * 0.45 - ux * head * 0.3,
        ly - ux * head * 0.45 - uy * head * 0.3,
        color,
    );
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
