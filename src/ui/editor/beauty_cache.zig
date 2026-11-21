//! The beautify preview of the selection on screen: the shot as shown,
//! framed by the background, shadow and rounded corners the export will
//! have, scaled like the view. Cached per pane until the selection or
//! what it shows changes.

const std = @import("std");
const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const effects = @import("../../gfx/effects.zig");

const Editor = editor.Editor;
const Rect = shapes_mod.Rect;

/// Rebuild the current pane's beautify cache when it is stale.
pub fn ensure(ed: *Editor) !void {
    if (!ed.beautify.enabled or ed.pn().bcache_valid) return;
    const s = ed.selBuf() orelse return;
    if (s.w < 2 or s.h < 2) return;
    const fr = ed.frameRect(s);
    const old = ed.pn().bcache_rect;
    ed.pn().bcache_valid = true;
    ed.pn().gen +%= 1;
    ed.pn().bcache_rect = fr;
    const fw: u32 = @intCast(fr.w);
    const fh: u32 = @intCast(fr.h);
    ed.alloc.free(ed.pn().bcache);
    ed.pn().bcache = &.{};
    ed.pn().bcache = try ed.alloc.alloc(u32, @as(usize, fw) * fh);
    const shot = try copyShot(ed, s);
    defer ed.alloc.free(shot);
    paintFrame(ed, s, fr, shot);
    ed.pn().content_dirty.add(old);
    ed.pn().content_dirty.add(fr);
}

/// The shot as shown, `s` of the view (clipped to the screen; off-screen
/// parts repeat the edge). Caller frees.
fn copyShot(ed: *Editor, s: Rect) ![]u32 {
    const sw: u32 = @intCast(s.w);
    const sh: u32 = @intCast(s.h);
    const shot = try ed.alloc.alloc(u32, @as(usize, sw) * sh);
    const ww: i32 = @intCast(ed.pn().width);
    const wh: i32 = @intCast(ed.pn().height);
    for (0..sh) |yy| {
        const by = std.math.clamp(s.y + @as(i32, @intCast(yy)), 0, wh - 1);
        for (0..sw) |xx| {
            const bx = std.math.clamp(s.x + @as(i32, @intCast(xx)), 0, ww - 1);
            shot[yy * sw + xx] = ed.pn().viewc[@as(usize, @intCast(by)) * ed.pn().width + @as(usize, @intCast(bx))];
        }
    }
    return shot;
}

/// Paint the frame `fr` into the cache: background, shadow, then the
/// shot `s` with rounded corners. Scaled like the export: same
/// proportions, view pixels.
fn paintFrame(ed: *Editor, s: Rect, fr: Rect, shot: []const u32) void {
    const fw: u32 = @intCast(fr.w);
    const fh: u32 = @intCast(fr.h);
    const sel = ed.doc.sel.?.normalized();
    const g_img = ed.beautify.geometry(@intCast(@max(1, sel.w)), @intCast(@max(1, sel.h)));
    const k = ed.pn().view.scale;
    paintBackground(ed, fr, k);
    const inner: effects.Rect = .{ .x = s.x - fr.x, .y = s.y - fr.y, .w = s.w, .h = s.h };
    const blur: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(g_img.shadow_blur)) * k));
    if (blur > 0) effects.dropShadow(ed.pn().bcache, fw, fh, inner, blur, @intFromFloat(@round(@as(f64, @floatFromInt(g_img.shadow_dy)) * k)), 0x70000000);
    const rad: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(g_img.radius)) * k));
    effects.blitRounded(ed.pn().bcache, fw, fh, shot, @intCast(s.w), @intCast(s.h), inner.x, inner.y, rad);
}

/// The beautify background, or for a transparent one the usual
/// checkerboard standing for "nothing here" (the export itself is
/// transparent).
fn paintBackground(ed: *Editor, fr: Rect, k: f64) void {
    const fw: u32 = @intCast(fr.w);
    const fh: u32 = @intCast(fr.h);
    const bg = ed.beautify.background();
    if (!bg.transparent()) return effects.gradient(ed.pn().bcache, fw, fh, .{ .x = 0, .y = 0, .w = fr.w, .h = fr.h }, bg.from, bg.to);
    const cell: usize = @max(4, @as(usize, @intFromFloat(@round(8 * k))));
    for (0..fh) |yy| for (0..fw) |xx| {
        ed.pn().bcache[yy * fw + xx] = if ((xx / cell + yy / cell) % 2 == 0) 0xFFFFFFFF else 0xFFD9DDE1;
    };
}
