//! How the tools' controls look and read: names for scripts, labels and
//! shortcuts for tooltips and menus, icons, and their place on the
//! toolbar, the colour popover and the More menu.

const std = @import("std");
const config = @import("../../app/config.zig");
const icons = @import("../icons.zig");
const ui = @import("../editor_ui.zig");
const editor_mod = @import("../editor.zig");
const tools = @import("mod.zig");
const theme = @import("../theme.zig");
const shapes = @import("../shapes.zig");
const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const color = @import("color.zig");

const Editor = editor_mod.Editor;
const Ext = tools.Ext;
const Icon = icons.Icon;

/// Script names (`button NAME`).
pub fn name(e: Ext) []const u8 {
    return switch (e) {
        .aspect => |a| switch (a) {
            .free => "aspect_free",
            .square => "aspect_square",
            .wide => "aspect_wide",
            .classic => "aspect_classic",
        },
        .picked => |i| (&picked_names)[@min(i, picked_names.len - 1)],
        else => @tagName(e),
    };
}

const picked_names = [_][]const u8{ "picked0", "picked1", "picked2", "picked3", "picked4", "picked5" };

/// Where a control named `n` lives, when it is one of the tools'.
pub fn nameLayer(n: []const u8) ?ui.Layer {
    for ([_][]const u8{ "copy_text", "redact_sensitive", "pin" }) |m| if (std.mem.eql(u8, m, n)) return .menu;
    for (picked_names) |m| if (std.mem.eql(u8, m, n)) return .popover;
    return null;
}

fn actionOf(e: Ext) ?config.Action {
    return switch (e) {
        .eyedropper => .eyedropper,
        .crop => .crop,
        .copy_text => .copy_text,
        .redact_sensitive => .redact_sensitive,
        .pin => .pin,
        else => null,
    };
}

pub fn label(ed: *const Editor, e: Ext, kb: []u8) ui.Label {
    const n: []const u8, const fixed: []const u8 = switch (e) {
        .eyedropper => .{ "Colour picker", "" },
        .crop => .{ "Crop", "" },
        .copy_text => .{ "Copy text", "" },
        .redact_sensitive => .{ "Redact sensitive data", "" },
        .pin => .{ "Pin to screen", "" },
        .crop_apply => .{ "Apply crop", "Enter" },
        .crop_cancel => .{ "Cancel crop", "Esc" },
        .aspect => |a| .{ switch (a) {
            .free => "Free",
            .square => "1:1",
            .wide => "16:9",
            .classic => "4:3",
        }, "" },
        .picked => |i| return .{ .name = "Use this colour", .key = if (i < ed.tools.history.len) color.hex(kb, ed.tools.history.items[i]) else "" },
    };
    // without libtesseract these say what they need
    if ((e == .copy_text or e == .redact_sensitive) and !@import("ocr_job.zig").available()) return .{ .name = n, .key = "needs Tesseract" };
    const key = if (actionOf(e)) |a| config.bindName(ed.binds[@backingInt(a)], kb) else fixed;
    return .{ .name = n, .key = if (std.mem.eql(u8, key, "unset")) "" else key };
}

pub fn icon(e: Ext) ?Icon {
    return switch (e) {
        .eyedropper => .eyedropper,
        .crop => .crop,
        .copy_text => .scan_text,
        .redact_sensitive => .shield,
        .pin => .pin,
        .crop_apply => .check,
        .crop_cancel => .close,
        .aspect, .picked => null,
    };
}

pub fn active(ed: *const Editor, e: Ext) bool {
    return switch (e) {
        .eyedropper => ed.tools.mode == .eyedropper,
        .crop => ed.tools.mode == .crop,
        .aspect => |a| ed.tools.mode == .crop and ed.tools.aspect == a,
        else => false,
    };
}

// --- toolbar ---

/// The tools' buttons after the annotation tools.
pub fn barTools(ed: *const Editor, items: *[24]ui.Item, n_in: usize) usize {
    var n = n_in;
    const btn = ed.sc(theme.button);
    for ([_]Ext{ .eyedropper, .crop }) |e| {
        items[n] = .{ .kind = .{ .ext = e }, .w = btn, .group = 0 };
        n += 1;
    }
    return n;
}

/// A whole other toolbar for a mode (crop); null: the usual one.
pub fn barItems(ed: *const Editor, items: *[24]ui.Item) ?usize {
    if (ed.tools.mode != .crop) return null;
    const btn = ed.sc(theme.button);
    var n: usize = 0;
    for ([_]tools.Aspect{ .free, .square, .wide, .classic }) |a| {
        items[n] = .{ .kind = .{ .ext = .{ .aspect = a } }, .w = labelWidth(ed, .{ .aspect = a }), .group = 0 };
        n += 1;
    }
    items[n] = .{ .kind = .{ .ext = .crop_cancel }, .w = btn, .group = 1 };
    items[n + 1] = .{ .kind = .{ .ext = .crop_apply }, .w = btn, .group = 1 };
    return n + 2;
}

/// The toolbar stays hidden (capturing text: select and done).
pub fn hideBar(ed: *const Editor) bool {
    return ed.tools.text_capture;
}

fn labelWidth(ed: *const Editor, e: Ext) i32 {
    var kb: [32]u8 = undefined;
    return text_mod.width(theme.font_label * ed.uf(), label(ed, e, &kb).name) + ed.sc(20);
}

/// A text button (the crop ratios).
pub fn drawBarLabel(ed: *const Editor, canvas: *render.Canvas, b: ui.Button, fg: u32) void {
    var kb: [32]u8 = undefined;
    const l = label(ed, b.kind.ext, &kb).name;
    const fs = theme.font_label * ed.uf();
    const r = b.rect;
    text_mod.draw(canvas, r.x + @divTrunc(r.w - text_mod.width(fs, l), 2), r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, fg, l);
}

// --- the colour popover: picked colours ---

fn swatchSize(ed: *const Editor) i32 {
    return ed.sc(22);
}

pub fn historyHeight(ed: *const Editor) i32 {
    if (ed.tools.history.len == 0) return 0;
    return text_mod.height(theme.font_small * ed.uf()) + ed.sc(6) + swatchSize(ed) + ed.sc(12);
}

/// The history's swatches from (x, y), `w` wide; returns where the
/// popover goes on below them.
pub fn layoutHistory(ed: *Editor, x: i32, y: i32, w: i32) !i32 {
    _ = w;
    if (ed.tools.history.len == 0) return y;
    const sw = swatchSize(ed);
    const top = y + text_mod.height(theme.font_small * ed.uf()) + ed.sc(6);
    for (0..ed.tools.history.len) |i| {
        const sx = x + @as(i32, @intCast(i)) * (sw + ed.sc(8));
        try ed.buttons.append(ed.alloc, .{ .rect = .{ .x = sx, .y = top, .w = sw, .h = sw }, .kind = .{ .ext = .{ .picked = @intCast(i) } }, .layer = .popover });
    }
    return y + historyHeight(ed);
}

pub fn drawPopoverButton(ed: *Editor, canvas: *render.Canvas, b: ui.Button, bi: usize) void {
    const i = switch (b.kind.ext) {
        .picked => |i| i,
        else => return,
    };
    const f = ed.uf();
    const th = ed.theme;
    const r = b.rect;
    if (i == 0) {
        const fs = theme.font_small * f;
        text_mod.draw(canvas, r.x, r.y - ed.sc(6) - text_mod.height(fs), fs, th.muted, "Picked");
    }
    const hv = ui.hoverAmount(ed, bi);
    if (hv > 0) shapes.roundRectRing(canvas, r.expand(ed.sc(3)), 8 * f, 1.5 * f, theme.fade(th.hairline, 2 * hv));
    canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, 6 * f, ed.tools.history.items[i]);
    shapes.roundRectRing(canvas, r, 6 * f, 1, 0x59808080);
    if (ed.focus == bi) ui.focusRing(ed, canvas, r, 6 * f);
}
