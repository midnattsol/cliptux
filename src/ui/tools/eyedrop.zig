//! The colour picker (eyedropper, I): the magnifier (editor_ui/loupe.zig)
//! shows the pixel grid and the colour under the pointer; a click copies
//! it as `#RRGGBB`, Shift+click as `rgb(r, g, b)`, Alt+click makes it the
//! annotation colour. Picked colours are kept in the colour popover's
//! history.

const std = @import("std");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const color = @import("color.zig");

const Editor = editor_mod.Editor;
const Point = shapes.Point;

pub fn toggle(ed: *Editor) !void {
    if (ed.tools.mode == .eyedropper) {
        ed.tools.mode = .none;
    } else {
        try ed.settle();
        ed.closePopover();
        ed.tools.mode = .eyedropper;
    }
    ed.needs_render = true;
}

/// The composed pixel (annotations included) under buffer point `m`.
fn colorAt(ed: *const Editor, m: Point) ?u32 {
    const ip = ed.pn().view.toImg(m);
    if (ip.x < 0 or ip.y < 0 or ip.x >= ed.img.width or ip.y >= ed.img.height) return null;
    return ed.layer[@as(usize, @intCast(ip.y)) * ed.img.width + @as(usize, @intCast(ip.x))] | 0xFF000000;
}

/// A click while picking. True when it was the picker's.
pub fn onPress(ed: *Editor) !bool {
    if (ed.tools.mode != .eyedropper) return false;
    const c = colorAt(ed, ed.mouse) orelse return true;
    ed.tools.history.add(c);
    if (ed.mod_alt) return useColor(ed, c);
    try copy(ed, c, if (ed.mod_shift) .rgb else .hex);
    return true;
}

/// Make `c` the annotation colour (and the selected shape's).
pub fn useColor(ed: *Editor, c: u32) !bool {
    ed.custom_color = c;
    ed.custom_active = true;
    try ed.applyColor();
    var buf: [16]u8 = undefined;
    var msg: [48]u8 = undefined;
    ed.tools.toast.show(.info, std.fmt.bufPrint(&msg, "{s} is the annotation colour", .{color.hex(&buf, c)}) catch "", 2400);
    ed.tools.toast.swatch = c;
    ed.needs_render = true;
    return true;
}

fn copy(ed: *Editor, c: u32, f: color.Format) !void {
    var buf: [32]u8 = undefined;
    const s = color.format(&buf, c, f);
    const owned = try ed.alloc.dupe(u8, s);
    ed.win.setClipboardText(owned) catch |e| {
        ed.alloc.free(owned);
        std.log.warn("colour picker: copy failed: {t}", .{e});
        ed.tools.toast.show(.problem, "Copy failed", 2400);
        return;
    };
    std.log.info("colour picker: copied {s}", .{s});
    var msg: [64]u8 = undefined;
    ed.tools.toast.show(.done, std.fmt.bufPrint(&msg, "{s} copied", .{s}) catch s, 2400);
    ed.tools.toast.swatch = c;
    ed.needs_render = true;
}
