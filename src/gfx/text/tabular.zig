//! Tabular figures: digits that all take the same width, so numbers that
//! change while you watch (a selection's size, a timer, a counter) do not
//! jiggle. The font's own tabular digits (its GSUB "tnum" feature) when it
//! has them; else its default digits, each centred in the advance of the
//! widest one.

const std = @import("std");
const ttf = @import("../ttf.zig");
const otl = @import("../otl.zig");

/// One font's tabular digits.
pub const Digits = struct {
    /// glyph of '0'..'9'
    gid: [10]u16,
    /// the advance they all take, font units
    adv: f64,

    /// Glyph, advance and centring offset (pixels at `size_px`) of digit
    /// `d`; null when the font has no glyph for it.
    pub fn place(self: *const Digits, font: *const ttf.Font, d: u4, size_px: f64) ?struct { gid: u16, adv: f64, dx: f64 } {
        const gid = self.gid[d];
        if (gid == 0) return null;
        const k = size_px / font.units_per_em;
        return .{ .gid = gid, .adv = self.adv * k, .dx = (self.adv - font.advanceUnits(gid)) * k / 2 };
    }
};

/// Work out `font`'s tabular digits.
pub fn compute(alloc: std.mem.Allocator, font: *const ttf.Font) Digits {
    var out: Digits = .{ .gid = undefined, .adv = 0 };
    for (&out.gid, 0..) |*g, d| g.* = font.glyphIndex(@intCast('0' + d));
    substituteTnum(alloc, font, &out.gid);
    for (out.gid) |g| {
        if (g != 0) out.adv = @max(out.adv, font.advanceUnits(g));
    }
    return out;
}

/// Replace `gid` by the font's "tnum" glyphs, when it has the feature.
fn substituteTnum(alloc: std.mem.Allocator, font: *const ttf.Font, gid: *[10]u16) void {
    var buf: std.ArrayList(otl.Glyph) = .empty;
    defer buf.deinit(alloc);
    for (gid, 0..) |g, d| buf.append(alloc, .{ .gid = g, .cl0 = @intCast(d), .cl1 = @intCast(d + 1) }) catch return;
    otl.substitute(alloc, font.layout, .latn, &.{"tnum"}, &buf) catch return;
    // one glyph per digit, still: a font that did anything else is ignored
    if (buf.items.len != gid.len) return;
    for (buf.items, gid) |g, *out| {
        if (g.gid != 0) out.* = g.gid;
    }
}

/// The digit `cp` stands for, or null.
pub fn digitOf(cp: u21) ?u4 {
    return if (cp >= '0' and cp <= '9') @intCast(cp - '0') else null;
}

test "tabular digits all take the same advance" {
    const alloc = std.testing.allocator;
    var font = ttf.Font.load(alloc, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") catch return; // skip if absent
    defer font.deinit();
    const t = compute(alloc, &font);
    var adv: ?f64 = null;
    for (0..10) |d| {
        const p = t.place(&font, @intCast(d), 20).?;
        if (adv) |a| try std.testing.expectEqual(a, p.adv) else adv = p.adv;
        try std.testing.expect(p.dx >= 0);
    }
    try std.testing.expect(digitOf('7').? == 7 and digitOf('a') == null);
}
