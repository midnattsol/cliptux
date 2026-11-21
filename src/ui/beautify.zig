//! The "beautify" frame around an export: background (gradient, solid or
//! transparent), padding, rounded corners and a shadow.

const std = @import("std");
const effects = @import("../gfx/effects.zig");

pub const Background = struct {
    from: u32,
    to: u32,
    name: []const u8,

    /// no backdrop: padding exported as transparent pixels (PNG with alpha)
    pub fn transparent(self: Background) bool {
        return self.from >> 24 == 0 and self.to >> 24 == 0;
    }
};

pub const backgrounds = [_]Background{
    .{ .from = 0xFF8EC5FC, .to = 0xFFE0C3FC, .name = "Lavender" },
    .{ .from = 0xFFFF9A8B, .to = 0xFFFF6A88, .name = "Coral" },
    .{ .from = 0xFF4FACFE, .to = 0xFF00F2FE, .name = "Ocean" },
    .{ .from = 0xFF43E97B, .to = 0xFF38F9D7, .name = "Mint" },
    .{ .from = 0xFFFA709A, .to = 0xFFFEE140, .name = "Sunset" },
    .{ .from = 0xFF30343F, .to = 0xFF1B1D24, .name = "Graphite" },
    .{ .from = 0xFFF1F3F5, .to = 0xFFF1F3F5, .name = "Paper" },
    // last, so saved indexes of the others keep their meaning
    .{ .from = 0x00000000, .to = 0x00000000, .name = "Transparent" },
};

/// Padding as a percentage of the shot's longer side, per level.
pub const padding_pct = [4]u8{ 0, 4, 7, 12 };

pub const Beautify = struct {
    enabled: bool = false,
    bg: u8 = 0,
    /// padding: 0 none, 1 small, 2 medium, 3 large (see padding_pct)
    padding: u2 = 2,
    rounded: bool = true,
    shadow: bool = true,

    pub const Geometry = struct {
        out_w: u32,
        out_h: u32,
        pad: u32,
        radius: u32,
        shadow_blur: u32,
        shadow_dy: i32,
    };

    /// Output layout for a `w`×`h` shot, in the shot's own pixels.
    pub fn geometry(self: Beautify, w: u32, h: u32) Geometry {
        if (!self.enabled) return .{ .out_w = w, .out_h = h, .pad = 0, .radius = 0, .shadow_blur = 0, .shadow_dy = 0 };
        const long: f64 = @floatFromInt(@max(w, h));
        const pct = padding_pct[self.padding];
        const pad: u32 = if (pct == 0) 0 else @max(16, @as(u32, @intFromFloat(@round(long * @as(f64, @floatFromInt(pct)) / 100.0))));
        const radius: u32 = if (self.rounded) @min(@min(w, h) / 2, @max(4, @as(u32, @intFromFloat(@round(long * 0.012))))) else 0;
        const blur: u32 = if (self.shadow and pad > 0) @max(4, pad / 2) else 0;
        return .{
            .out_w = w + 2 * pad,
            .out_h = h + 2 * pad,
            .pad = pad,
            .radius = radius,
            .shadow_blur = blur,
            .shadow_dy = @intCast(blur / 3),
        };
    }

    pub fn background(self: Beautify) Background {
        return backgrounds[self.bg % backgrounds.len];
    }

    /// Paint the frame (background, shadow) into `dst` and place `shot`
    /// at (pad, pad) with rounded corners. `dst` is out_w×out_h.
    pub fn paint(self: Beautify, alloc: std.mem.Allocator, dst: []u32, shot: []const u32, w: u32, h: u32) void {
        _ = alloc;
        const g = self.geometry(w, h);
        const bg = self.background();
        const full: effects.Rect = .{ .x = 0, .y = 0, .w = @intCast(g.out_w), .h = @intCast(g.out_h) };
        effects.gradient(dst, g.out_w, g.out_h, full, bg.from, bg.to);
        const inner: effects.Rect = .{ .x = @intCast(g.pad), .y = @intCast(g.pad), .w = @intCast(w), .h = @intCast(h) };
        if (g.shadow_blur > 0) effects.dropShadow(dst, g.out_w, g.out_h, inner, g.shadow_blur, g.shadow_dy, 0x70000000);
        effects.blitRounded(dst, g.out_w, g.out_h, shot, w, h, inner.x, inner.y, g.radius);
    }
};
