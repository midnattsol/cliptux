//! A captured window as macOS frames it: its own pixels (rounded corners
//! transparent) on a transparent canvas, with a soft shadow around it.
//! With beautify on, the window sits on the beautify background instead
//! (its corners showing the background, not black).

const std = @import("std");
const effects = @import("../../gfx/effects.zig");
const png = @import("../../gfx/png.zig");
const doc_mod = @import("../../ui/doc.zig");

/// Shadow size for a window `w`x`h` at `scale` (pixels per logical px).
pub fn shadowPad(scale: f64) u32 {
    return @intFromFloat(@round(28 * @max(1, scale)));
}

/// `win` over a transparent canvas with `pad` pixels of shadow around it.
pub fn withShadow(gpa: std.mem.Allocator, win: png.Image, pad: u32) !png.Image {
    const w = win.width + 2 * pad;
    const h = win.height + 2 * pad;
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    @memset(px, 0);
    const r: effects.Rect = .{ .x = @intCast(pad), .y = @intCast(pad), .w = @intCast(win.width), .h = @intCast(win.height) };
    effects.dropShadow(px, w, h, r, pad * 3 / 4, @intCast(pad / 4), 0x66000000);
    blitOver(px, w, win, pad, pad);
    return .{ .width = w, .height = h, .pixels = px };
}

/// `src` over `dst` at (x, y), alpha blended.
fn blitOver(dst: []u32, dw: u32, src: png.Image, x: u32, y: u32) void {
    for (0..src.height) |sy| {
        const drow = dst[(y + sy) * dw + x ..][0..src.width];
        for (drow, src.pixels[sy * src.width ..][0..src.width]) |*d, s| d.* = effects.over(d.*, s);
    }
}

/// The window on the beautify background (padding, shadow), its own
/// corners kept.
pub fn beautified(gpa: std.mem.Allocator, win: png.Image, b: doc_mod.Beautify) !png.Image {
    const g = b.geometry(win.width, win.height);
    const px = try gpa.alloc(u32, @as(usize, g.out_w) * g.out_h);
    const bg = b.background();
    const full: effects.Rect = .{ .x = 0, .y = 0, .w = @intCast(g.out_w), .h = @intCast(g.out_h) };
    effects.gradient(px, g.out_w, g.out_h, full, bg.from, bg.to);
    const inner: effects.Rect = .{ .x = @intCast(g.pad), .y = @intCast(g.pad), .w = @intCast(win.width), .h = @intCast(win.height) };
    if (g.shadow_blur > 0) effects.dropShadow(px, g.out_w, g.out_h, inner, g.shadow_blur, g.shadow_dy, 0x70000000);
    blitOver(px, g.out_w, win, g.pad, g.pad);
    return .{ .width = g.out_w, .height = g.out_h, .pixels = px };
}

/// Frame the window as the settings say. Takes `win`; returns the image
/// to keep (possibly `win` itself).
pub fn frame(gpa: std.mem.Allocator, win: png.Image, scale: f64, shadow: bool, b: doc_mod.Beautify) !png.Image {
    if (!b.enabled and !shadow) return win;
    var w = win;
    defer w.deinit(gpa);
    if (b.enabled) return beautified(gpa, win, b);
    return withShadow(gpa, win, shadowPad(scale));
}

test "the shadow surrounds the window and the corners stay see-through" {
    const gpa = std.testing.allocator;
    const src = try gpa.alloc(u32, 20 * 10);
    @memset(src, 0xFF336699);
    src[0] = 0; // a rounded corner's transparent pixel
    const out = try frame(gpa, .{ .width = 20, .height = 10, .pixels = src }, 1, true, .{});
    defer gpa.free(out.pixels);
    const pad = shadowPad(1);
    try std.testing.expectEqual(20 + 2 * pad, out.width);
    try std.testing.expectEqual(10 + 2 * pad, out.height);
    // far corner: nothing; the window's own pixels opaque; its corner shows shadow only
    try std.testing.expectEqual(@as(u32, 0), out.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF336699), out.pixels[(pad + 5) * out.width + pad + 5]);
    try std.testing.expect(out.pixels[pad * out.width + pad] >> 24 < 0xFF);
    // below the window the shadow is visible
    try std.testing.expect(out.pixels[(pad + 10 + 2) * out.width + pad + 10] >> 24 > 0);
}

test "no shadow, no beautify: the window as it is" {
    const gpa = std.testing.allocator;
    const src = try gpa.alloc(u32, 4);
    @memset(src, 0);
    const out = try frame(gpa, .{ .width = 2, .height = 2, .pixels = src }, 2, false, .{});
    defer gpa.free(out.pixels);
    try std.testing.expectEqual(src.ptr, out.pixels.ptr);
}
