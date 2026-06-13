//! Editor chrome: selection overlay, toolbar layout/painting and the
//! procedural button icons. Operates on the Editor state.

const std = @import("std");
const render = @import("../gfx/render.zig");
const text_mod = @import("../gfx/text.zig");
const shapes_mod = @import("shapes.zig");
const editor_mod = @import("editor.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Tool = shapes_mod.Tool;
const Rect = shapes_mod.Rect;
const palette = shapes_mod.palette;
const handlePoints = shapes_mod.handlePoints;

pub const ui_bg: u32 = 0xF21D2126;
pub const ui_bg_hover: u32 = 0xFF3A3F42;
pub const ui_accent: u32 = 0xFF4DABF7;
pub const ui_fg: u32 = 0xFFE9ECEF;

pub const ButtonKind = union(enum) {
    tool: Tool,
    color: u3,
    undo,
    redo,
    copy,
    save,
    cancel,
};

pub const Button = struct {
    rect: Rect,
    kind: ButtonKind,
};

pub fn drawSelectionChrome(self: *Editor, canvas: *Canvas) void {
    const w: i32 = @intCast(self.win.width);
    const h: i32 = @intCast(self.win.height);
    const f = self.uf();

    _ = h;
    if (self.sel) |sel_raw| {
        const s = sel_raw.normalized();
        // (dimming is composed in composeBackground)
        // border: dark outer halo + crisp white line
        canvas.rectOutline(s.x - 2, s.y - 2, s.w + 4, s.h + 4, 1, 0x59000000);
        canvas.rectOutline(s.x - 1, s.y - 1, s.w + 2, s.h + 2, 1, 0xFFFFFFFF);
        // circular resize handles
        if (self.tool == .select) {
            for (handlePoints(s)) |p| {
                const px: f64 = @floatFromInt(p.x);
                const py: f64 = @floatFromInt(p.y);
                canvas.fillCircleAA(px, py, 5.5 * f, 0xFFFFFFFF);
                canvas.ringAA(px, py, 5.5 * f, 1.5 * f, 0xB3000000);
            }
        }
        // dimensions pill
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d} x {d}", .{ s.w, s.h }) catch "?";
        const fs = 13.0 * f;
        const tw = text_mod.width(fs, label);
        const ph = text_mod.height(fs) + self.sc(8);
        var lx = s.x;
        var ly = s.y - ph - self.sc(8);
        if (ly < 6) ly = s.y + self.sc(8);
        if (lx + tw + self.sc(18) > w) lx = w - tw - self.sc(18);
        if (lx < 6) lx = 6;
        canvas.fillRoundRectAA(lx, ly, tw + self.sc(16), ph, @as(f64, @floatFromInt(ph)) / 2.0, 0xE6191D21);
        text_mod.draw(canvas, lx + self.sc(8), ly + self.sc(4), fs, ui_fg, label);
    } else {
        // background already dimmed in composeBackground
        const hint = "Drag to select a region    Enter: full screen    Esc: cancel";
        const fs = 14.0 * f;
        const tw = text_mod.width(fs, hint);
        const ph = text_mod.height(fs) + self.sc(14);
        const lx = @divTrunc(w - tw, 2);
        canvas.fillRoundRectAA(lx - self.sc(18), self.sc(28), tw + self.sc(36), ph, @as(f64, @floatFromInt(ph)) / 2.0, 0xF21D2126);
        text_mod.draw(canvas, lx, self.sc(28) + self.sc(7), fs, ui_fg, hint);
    }
}

pub const tool_list = [_]Tool{ .select, .pen, .line, .arrow, .rect, .ellipse, .highlight, .pixelate, .counter, .text };

pub fn layoutToolbar(self: *Editor) !void {
    self.buttons.clearRetainingCapacity();
    if (self.sel == null) {
        self.toolbar_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return;
    }
    const w: i32 = @intCast(self.win.width);
    const h: i32 = @intCast(self.win.height);

    const btn = self.sc(36);
    const gap = self.sc(5);
    const group_gap = self.sc(18);
    const pad = self.sc(10);
    const chip_w = self.sc(52);
    const n_tools: i32 = tool_list.len;
    const n_colors: i32 = palette.len;
    const n_actions: i32 = 5;
    const total = pad + n_tools * (btn + gap) - gap + group_gap +
        n_colors * (btn + gap) - gap + group_gap +
        n_actions * (btn + gap) - gap + group_gap + chip_w + pad;

    const s = self.sel.?.normalized();
    var bx = std.math.clamp(s.x + @divTrunc(s.w - total, 2), 8, @max(8, w - total - 8));
    var by = s.y + s.h + self.sc(16);
    if (by + btn + self.sc(24) > h) by = s.y - btn - self.sc(34);
    if (by < 8) by = 8;

    self.toolbar_rect = .{ .x = bx, .y = by - pad, .w = total, .h = btn + pad * 2 };
    bx += pad;

    for (tool_list) |t| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = bx, .y = by, .w = btn, .h = btn },
            .kind = .{ .tool = t },
        });
        bx += btn + gap;
    }
    bx += group_gap - gap;
    for (0..palette.len) |i| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = bx, .y = by, .w = btn, .h = btn },
            .kind = .{ .color = @intCast(i) },
        });
        bx += btn + gap;
    }
    bx += group_gap - gap;
    const actions = [_]ButtonKind{ .undo, .redo, .copy, .save, .cancel };
    for (actions) |a| {
        try self.buttons.append(self.alloc, .{
            .rect = .{ .x = bx, .y = by, .w = btn, .h = btn },
            .kind = a,
        });
        bx += btn + gap;
    }
}

pub fn drawToolbar(self: *Editor, canvas: *Canvas) void {
    if (self.sel == null) return;
    const tb = self.toolbar_rect;
    const f = self.uf();
    // soft drop shadow + rounded bar
    canvas.fillRoundRectAA(tb.x - 1, tb.y + self.sc(2), tb.w + 2, tb.h + self.sc(2), 16.0 * f, 0x38000000);
    canvas.fillRoundRectAA(tb.x, tb.y, tb.w, tb.h, 15.0 * f, ui_bg);

    var prev_kind: ?ButtonKind = null;
    for (self.buttons.items) |b| {
        if (prev_kind) |pk| {
            const group_changed = @intFromEnum(pk) != @intFromEnum(b.kind) and
                (pk == .color or (std.meta.activeTag(pk) == .tool and std.meta.activeTag(b.kind) == .color));
            if (group_changed) {
                const sx = @divTrunc(prevRight(pk, self.buttons.items) + b.rect.x, 2);
                canvas.fillRect(sx, tb.y + self.sc(10), 1, tb.h - self.sc(20), 0x26FFFFFF);
            }
        }
        prev_kind = b.kind;

        const hovered = b.rect.contains(self.mouse.x, self.mouse.y);
        const active = switch (b.kind) {
            .tool => |t| t == self.tool,
            .color => |c| c == self.color_idx,
            else => false,
        };
        const is_color = std.meta.activeTag(b.kind) == .color;
        if (active and !is_color) {
            canvas.fillRoundRectAA(b.rect.x, b.rect.y, b.rect.w, b.rect.h, 10.0 * f, ui_accent);
        } else if (hovered) {
            canvas.fillRoundRectAA(b.rect.x, b.rect.y, b.rect.w, b.rect.h, 10.0 * f, 0x24FFFFFF);
        }
        const fg: u32 = if (active and !is_color) 0xFF14181C else ui_fg;
        drawButtonIcon(self, canvas, b, fg, active);
    }

    // thickness chip: live disc preview + value
    const chip_x = tb.x + tb.w - self.sc(60);
    const cy: f64 = @floatFromInt(tb.y + @divTrunc(tb.h, 2));
    const pr = @min(9.0 * f, @max(1.5, @as(f64, @floatFromInt(self.thickness)) / 2.0));
    canvas.fillCircleAA(@floatFromInt(chip_x + self.sc(12)), cy, pr, self.color());
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}", .{self.thickness}) catch "?";
    const fs = 13.0 * f;
    text_mod.draw(canvas, chip_x + self.sc(28), tb.y + @divTrunc(tb.h, 2) - @divTrunc(text_mod.height(fs), 2), fs, 0xFFAAB2BA, label);
}

pub fn drawCopyNotice(self: *Editor, canvas: *Canvas) void {
    const window_width: i32 = @intCast(self.win.width);
    const ui_scale = self.uf();
    const message = switch (self.copy_notice) {
        .none => return,
        .copying => "Copying...",
        .copied => "Copied to clipboard",
        .failed => "Copy failed",
    };
    const message_font_size = 15.0 * ui_scale;
    const message_width = text_mod.width(message_font_size, message);
    const message_height = text_mod.height(message_font_size);
    const horizontal_padding = self.sc(18);
    const vertical_padding = self.sc(10);
    const notice_width = message_width + horizontal_padding * 2;
    const notice_height = message_height + vertical_padding * 2;
    const notice_x = @divTrunc(window_width - notice_width, 2);
    const notice_y = self.sc(28);
    const background_color: u32 = switch (self.copy_notice) {
        .none => unreachable,
        .copying => 0xF24DABF7,
        .copied => 0xF22F9E44,
        .failed => 0xF2E03131,
    };
    canvas.fillRoundRectAA(notice_x, notice_y + self.sc(2), notice_width, notice_height, 14.0 * ui_scale, 0x44000000);
    canvas.fillRoundRectAA(notice_x, notice_y, notice_width, notice_height, 14.0 * ui_scale, background_color);
    text_mod.draw(canvas, notice_x + horizontal_padding, notice_y + vertical_padding, message_font_size, 0xFFFFFFFF, message);
}

fn prevRight(kind: ButtonKind, buttons: []const Button) i32 {
    var right: i32 = 0;
    for (buttons) |b| {
        if (std.meta.activeTag(b.kind) == std.meta.activeTag(kind)) right = @max(right, b.rect.x + b.rect.w);
    }
    return right;
}

pub fn drawButtonIcon(self: *Editor, canvas: *Canvas, b: Button, fg: u32, active: bool) void {
    const ipad = self.sc(9);
    const x = b.rect.x + ipad;
    const y = b.rect.y + ipad;
    const si = b.rect.w - ipad * 2; // icon box (square)
    const sf: f64 = @floatFromInt(si);
    const xf: f64 = @floatFromInt(x);
    const yf: f64 = @floatFromInt(y);
    const f = self.uf();
    const cxf = xf + sf / 2.0;
    const cyf = yf + sf / 2.0;
    const P = struct { x: i32, y: i32 };
    const pi = std.math.pi;
    switch (b.kind) {
        .tool => |t| switch (t) {
            .select => {
                const l: i32 = @intFromFloat(sf * 0.4);
                const th: i32 = @max(2, self.sc(2));
                canvas.fillRect(x, y, l, th, fg);
                canvas.fillRect(x, y, th, l, fg);
                canvas.fillRect(x + si - l, y, l, th, fg);
                canvas.fillRect(x + si - th, y, th, l, fg);
                canvas.fillRect(x, y + si - th, l, th, fg);
                canvas.fillRect(x, y + si - l, th, l, fg);
                canvas.fillRect(x + si - l, y + si - th, l, th, fg);
                canvas.fillRect(x + si - th, y + si - l, th, l, fg);
            },
            .pen => {
                // pencil: body at 45 deg, wood tip, lead point
                const tipx = xf + sf * 0.06;
                const tipy = yf + sf * 0.94;
                const bodye_x = xf + sf * 0.34;
                const bodye_y = yf + sf * 0.66;
                const body = [_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.88), .y = @intFromFloat(yf + sf * 0.12) },
                    .{ .x = @intFromFloat(bodye_x), .y = @intFromFloat(bodye_y) },
                };
                canvas.strokePolylineAA(body[0..], sf * 0.32, fg);
                // wood collar
                canvas.fillTriangleAA(
                    bodye_x - sf * 0.115,
                    bodye_y - sf * 0.115,
                    bodye_x + sf * 0.115,
                    bodye_y + sf * 0.115,
                    tipx,
                    tipy,
                    (fg & 0x00FFFFFF) | 0x99000000,
                );
                // lead
                canvas.fillCircleAA(tipx + sf * 0.03, tipy - sf * 0.03, sf * 0.085, if (active) fg else ui_accent);
            },
            .line => {
                const seg = [_]P{ .{ .x = x, .y = y + si }, .{ .x = x + si, .y = y } };
                canvas.strokePolylineAA(seg[0..], 2.0 * f, fg);
                canvas.fillCircleAA(xf + 1, yf + sf - 1, 2.0 * f, fg);
                canvas.fillCircleAA(xf + sf - 1, yf + 1, 2.0 * f, fg);
            },
            .arrow => canvas.arrowAA(x, y + si, x + si, y, @max(2, self.sc(2)), fg),
            .rect => canvas.rectOutline(x, y + @divTrunc(si, 8), si, si - @divTrunc(si, 4), @max(2, self.sc(2)), fg),
            .ellipse => canvas.ellipseRingAA(x, y + @divTrunc(si, 8), si, si - @divTrunc(si, 4), 2.0 * f, fg),
            .highlight => {
                // marker pen over a highlighted swipe
                canvas.strokePolylineAA(&[_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.02), .y = @intFromFloat(yf + sf * 0.95) },
                    .{ .x = @intFromFloat(xf + sf * 0.62), .y = @intFromFloat(yf + sf * 0.95) },
                }, sf * 0.17, if (active) (fg & 0x00FFFFFF) | 0x80000000 else 0xA6FFD43B);
                const body = [_]P{
                    .{ .x = @intFromFloat(xf + sf * 0.84), .y = @intFromFloat(yf + sf * 0.14) },
                    .{ .x = @intFromFloat(xf + sf * 0.50), .y = @intFromFloat(yf + sf * 0.48) },
                };
                canvas.strokePolylineAA(body[0..], sf * 0.36, fg);
                canvas.fillTriangleAA(
                    xf + sf * 0.37,
                    yf + sf * 0.35,
                    xf + sf * 0.63,
                    yf + sf * 0.61,
                    xf + sf * 0.22,
                    yf + sf * 0.76,
                    fg,
                );
            },
            .pixelate => {
                const cell = @divTrunc(si, 4);
                var yy: i32 = 0;
                while (yy < 4) : (yy += 1) {
                    var xx: i32 = 0;
                    while (xx < 4) : (xx += 1) {
                        const dark = if (active) @mod(xx + yy, 2) == 0 else @mod(xx + yy, 2) != 0;
                        const shade: u32 = if (dark) (fg & 0x00FFFFFF) | 0x59000000 else fg;
                        canvas.fillRect(x + xx * cell, y + yy * cell, cell, cell, shade);
                    }
                }
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
            canvas.fillCircleAA(cxf, cyf, 9.0 * f, palette[c]);
            if (active) {
                canvas.ringAA(cxf, cyf, 12.0 * f, 2.0 * f, 0xFFFFFFFF);
            } else if (palette[c] == 0xFF1A1A1A) {
                canvas.ringAA(cxf, cyf, 9.0 * f, 1.0 * f, 0x59FFFFFF);
            }
        },
        .undo => drawArcArrow(canvas, cxf, cyf, sf * 0.42, 2.0 * f, fg, false),
        .redo => drawArcArrow(canvas, cxf, cyf, sf * 0.42, 2.0 * f, fg, true),
        .copy => {
            const o = @divTrunc(si, 4);
            canvas.fillRoundRectAA(x + o, y, si - o, si - o, 3.0 * f, (fg & 0x00FFFFFF) | 0x66000000);
            canvas.fillRoundRectAA(x, y + o, si - o, si - o, 3.0 * f, fg);
        },
        .save => {
            canvas.arrowAA(x + @divTrunc(si, 2), y, x + @divTrunc(si, 2), y + si - self.sc(6), @max(2, self.sc(2)), fg);
            canvas.fillRoundRectAA(x, y + si - self.sc(3), si, self.sc(3), 1.5 * f, fg);
        },
        .cancel => {
            const inset = @divTrunc(si, 6);
            const a = [_]P{ .{ .x = x + inset, .y = y + inset }, .{ .x = x + si - inset, .y = y + si - inset } };
            const bb = [_]P{ .{ .x = x + inset, .y = y + si - inset }, .{ .x = x + si - inset, .y = y + inset } };
            canvas.strokePolylineAA(a[0..], 2.5 * f, 0xFFFF6B6B);
            canvas.strokePolylineAA(bb[0..], 2.5 * f, 0xFFFF6B6B);
        },
    }
    _ = pi;
}

/// Curved undo/redo arrow: ~270 degree arc with an arrowhead at the end.
fn drawArcArrow(canvas: *Canvas, cx: f64, cy: f64, r: f64, width: f64, color: u32, mirrored: bool) void {
    const P = struct { x: i32, y: i32 };
    var pts: [10]P = undefined;
    const start: f64 = -60.0; // degrees
    const end: f64 = 170.0;
    for (&pts, 0..) |*p, i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(pts.len - 1));
        var ang = (start + (end - start) * t) * std.math.pi / 180.0;
        var px = cx + r * @cos(ang);
        if (mirrored) px = cx - r * @cos(ang);
        const py = cy - r * @sin(ang);
        _ = &ang;
        p.* = .{ .x = @intFromFloat(px), .y = @intFromFloat(py) };
    }
    canvas.strokePolylineAA(pts[0..], width, color);
    // arrowhead at the end, along the tangent
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
