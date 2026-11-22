//! The colour popover and the More menu fading out as they close, as
//! they fade in when they open: the popover's pixels as last shown are
//! kept and drawn over the chrome, less and less, while pop_open eases
//! back to 0.

const std = @import("std");
const editor_mod = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const render = @import("../../gfx/render.zig");
const motion = @import("../motion.zig");
const material = @import("material.zig");
const mix = @import("../../gfx/effects.zig").mixRows;

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = shapes_mod.Rect;

/// The closing popover as it was last shown on the toolbar's pane.
pub const Closing = struct {
    px: []u32 = &.{},
    rect: Rect = Rect.empty,
    pane: u8 = 0,

    pub fn release(c: *Closing, alloc: std.mem.Allocator) void {
        alloc.free(c.px);
        c.* = .{};
    }
};

/// Keep the open popover's pixels before it closes (call while
/// ed.popover and pop_rect still describe it).
pub fn begin(ed: *Editor) void {
    ed.pop_closing.release(ed.alloc);
    if (!motion.enabled or ed.pop_rect.isEmpty()) return;
    const p = &ed.panes[ed.tb_pane];
    if (p.last_frame.len != @as(usize, p.width) * p.height) return;
    const foot = material.shadowFootprint(ed, ed.pop_rect, ed.theme.popover_shadow);
    const r = Rect.intersect(foot, .{ .x = 0, .y = 0, .w = @intCast(p.width), .h = @intCast(p.height) }) orelse return;
    const px = ed.alloc.alloc(u32, @intCast(r.w * r.h)) catch return;
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |yy| {
        const off = (@as(usize, @intCast(r.y)) + yy) * p.width + @as(usize, @intCast(r.x));
        @memcpy(px[yy * rw ..][0..rw], p.last_frame[off..][0..rw]);
    }
    ed.pop_closing = .{ .px = px, .rect = r, .pane = ed.tb_pane };
    ed.pop_open.to(0, motion.now());
}

/// Still fading out.
pub fn busy(ed: *const Editor) bool {
    return ed.pop_closing.px.len > 0;
}

/// Where it shows, for damage (empty when nothing fades).
pub fn rect(ed: *const Editor) Rect {
    return if (busy(ed) and ed.pane_i == ed.pop_closing.pane) ed.pop_closing.rect else Rect.empty;
}

/// Draw the closing popover over the chrome; drop it once faded.
pub fn draw(ed: *Editor, canvas: *Canvas) void {
    if (!busy(ed) or ed.pane_i != ed.pop_closing.pane) return;
    // a popover opening again takes over
    if (ed.popover != .none) return ed.pop_closing.release(ed.alloc);
    const a = ed.pop_open.at(motion.now());
    if (a <= 0.001) return ed.pop_closing.release(ed.alloc);
    const c = &ed.pop_closing;
    const k: u32 = @intFromFloat(@round(a * 256));
    const rw: usize = @intCast(c.rect.w);
    for (0..@intCast(c.rect.h)) |yy| {
        const off = (@as(usize, @intCast(c.rect.y)) + yy) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(c.rect.x));
        const row = canvas.px[off..][0..rw];
        mix(row, row, c.px[yy * rw ..][0..rw], k);
    }
}
