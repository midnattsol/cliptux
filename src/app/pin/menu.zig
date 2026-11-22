//! The pin's menu (right-click, the ⋯ button, or the Menu key): what it
//! offers, where its rows are, where it opens, what is under a point and
//! moving through it with the keyboard. Logical pixels, from the menu's
//! top-left unless said otherwise; drawing is menu_draw.zig.

const std = @import("std");
const theme = @import("../../ui/theme.zig");
const icons = @import("../../ui/icons.zig");
const motion = @import("../../ui/motion.zig");
const Rect = @import("../../ui/shapes.zig").Rect;

pub const Item = enum {
    copy,
    save,
    annotate,
    opacity,
    lock,
    keep_on_top,
    close,
    close_all,

    pub fn label(it: Item, locked: bool) []const u8 {
        return switch (it) {
            .copy => "Copy",
            .save => "Save...",
            .annotate => "Annotate",
            .opacity => "Opacity",
            .lock => if (locked) "Unlock" else "Lock in Place",
            .keep_on_top => "Keep on Top...",
            .close => "Close",
            .close_all => "Close All Pins",
        };
    }

    /// Its shortcut on a focused pin, as the menu shows it.
    pub fn key(it: Item) []const u8 {
        return switch (it) {
            .copy => "Ctrl+C",
            .save => "Ctrl+S",
            .annotate => "Ctrl+E",
            .opacity => "1-4",
            .lock => "Ctrl+L",
            .keep_on_top => "",
            .close => "Ctrl+W",
            .close_all => "Ctrl+Shift+W",
        };
    }

    pub fn icon(it: Item) icons.Icon {
        return switch (it) {
            .copy => .copy,
            .save => .save_as,
            .annotate => .pen,
            .opacity => .more,
            .lock => .lock,
            .keep_on_top => .pin,
            .close, .close_all => .close,
        };
    }
};

/// What this pin can offer besides the fixed items.
pub const Offer = struct {
    /// clicks can pass through it (window.passesClicks)
    lock: bool = true,
    /// a plain window the desktop does not keep above: its window menu
    keep_on_top: bool = false,
};

pub const width = 256;
pub const pad: i32 = @intFromFloat(theme.menu_pad);
pub const row_h: i32 = @intFromFloat(theme.menu_row);
/// a separator: this much room, its hairline in the middle
pub const sep_h = 9;
/// the opacity block: a small heading over a segmented control
pub const heading_h = 22;
pub const seg_h = 28;
const opacity_h = heading_h + seg_h + 4;
const max_items = @typeInfo(Item).@"enum".field_names.len;

pub const Layout = struct {
    items: [max_items]Item = undefined,
    rows: [max_items]Rect = undefined,
    n: u8 = 0,
    /// the separators' hairlines (y)
    seps: [3]i32 = undefined,
    n_seps: u8 = 0,
    h: i32 = 0,

    pub fn size(l: *const Layout) [2]i32 {
        return .{ width, l.h };
    }

    fn add(l: *Layout, it: Item, y: *i32) void {
        const h = if (it == .opacity) opacity_h else row_h;
        l.items[l.n] = it;
        l.rows[l.n] = .{ .x = pad, .y = y.*, .w = width - 2 * pad, .h = h };
        l.n += 1;
        y.* += h;
    }

    fn separate(l: *Layout, y: *i32) void {
        l.seps[l.n_seps] = y.* + sep_h / 2;
        l.n_seps += 1;
        y.* += sep_h;
    }

    /// The index of `it`, if shown.
    pub fn find(l: *const Layout, it: Item) ?u8 {
        for (l.items[0..l.n], 0..) |x, i| if (x == it) return @intCast(i);
        return null;
    }
};

/// Copy, Save, Annotate | Opacity | Lock, Keep on Top | Close, Close All.
pub fn layout(offer: Offer) Layout {
    var l: Layout = .{};
    var y: i32 = pad;
    for ([_]Item{ .copy, .save, .annotate }) |it| l.add(it, &y);
    l.separate(&y);
    l.add(.opacity, &y);
    if (offer.lock or offer.keep_on_top) {
        l.separate(&y);
        if (offer.lock) l.add(.lock, &y);
        if (offer.keep_on_top) l.add(.keep_on_top, &y);
    }
    l.separate(&y);
    for ([_]Item{ .close, .close_all }) |it| l.add(it, &y);
    l.h = y + pad;
    return l;
}

/// Segment `i` of the opacity row `r`.
pub fn segment(r: Rect, i: usize) Rect {
    const top = r.y + heading_h;
    const inner = r.w - 4;
    const sw = @divTrunc(inner, 4);
    return .{ .x = r.x + 2 + @as(i32, @intCast(i)) * sw, .y = top + 2, .w = sw, .h = seg_h - 4 };
}

/// What is under a point of the menu.
pub const Hit = struct { index: u8, seg: ?u2 = null };

pub fn hit(l: *const Layout, x: i32, y: i32) ?Hit {
    for (l.rows[0..l.n], l.items[0..l.n], 0..) |r, it, i| {
        if (!r.contains(x, y)) continue;
        if (it != .opacity) return .{ .index = @intCast(i) };
        for (0..4) |s| if (segment(r, s).expand(2).contains(x, y)) return .{ .index = @intCast(i), .seg = @intCast(s) };
        return .{ .index = @intCast(i) };
    }
    return null;
}

/// The next row up (dir -1) or down (+1) from `cur`, wrapping.
pub fn step(l: *const Layout, cur: ?u8, dir: i2) u8 {
    const n: i32 = l.n;
    const c: i32 = cur orelse return if (dir > 0) 0 else @intCast(n - 1);
    return @intCast(@mod(c + dir, n));
}

/// Where a menu of `size` opens for a pointer at `anchor` in a surface
/// of `room` (both from the surface's top-left): right of and below the
/// anchor, else left of or above it when that fits in the surface, else
/// right and below anyway (the surface grows). `margin`: its shadow.
pub fn place(anchor: [2]i32, size: [2]i32, room: [2]i32, margin: i32) [2]i32 {
    var at: [2]i32 = undefined;
    for (0..2) |a| {
        const fits_after = anchor[a] + size[a] + margin <= room[a];
        const fits_before = anchor[a] - size[a] - margin >= 0;
        at[a] = if (!fits_after and fits_before) anchor[a] - size[a] else anchor[a];
    }
    return at;
}

/// How much a surface of `room` grows to show `r` and its shadow.
pub fn growth(r: Rect, room: [2]i32, margin: i32) [2]u32 {
    return .{
        @intCast(@max(0, r.right() + margin - room[0])),
        @intCast(@max(0, r.bottom() + margin - room[1])),
    };
}

/// An open (or closing) menu.
pub const State = struct {
    open: bool = false,
    /// its top-left in the surface
    at: [2]i32 = .{ 0, 0 },
    lay: Layout = .{},
    /// the row under the pointer or the keyboard focus, and the segment
    hot: ?u8 = null,
    hot_seg: ?u2 = null,
    shown: motion.Tween = .{ .dur_ms = theme.motion },
    /// the pointer left the pin: the menu closes at this time (0: no)
    close_at: i64 = 0,

    pub fn rect(s: *const State) Rect {
        const sz = s.lay.size();
        return .{ .x = s.at[0], .y = s.at[1], .w = sz[0], .h = sz[1] };
    }

    /// Open or fading out.
    pub fn visible(s: *const State, now: i64) bool {
        return s.open or s.shown.at(now) > 0.001;
    }

    pub fn show(s: *State, lay: Layout, at: [2]i32, hot: ?u8, now: i64) void {
        s.* = .{ .open = true, .at = at, .lay = lay, .hot = hot, .shown = s.shown };
        s.shown.to(1, now);
    }

    pub fn hide(s: *State, now: i64) void {
        if (!s.open) return;
        s.open = false;
        s.close_at = 0;
        s.shown.to(0, now);
    }
};

test "the menu groups its items and leaves out what this pin cannot do" {
    const full = layout(.{ .lock = true, .keep_on_top = true });
    try std.testing.expectEqual(@as(u8, 8), full.n);
    try std.testing.expectEqual(@as(u8, 3), full.n_seps);
    const plain = layout(.{ .lock = false, .keep_on_top = false });
    try std.testing.expectEqual(@as(u8, 6), plain.n);
    try std.testing.expectEqual(@as(u8, 2), plain.n_seps);
    try std.testing.expect(plain.find(.lock) == null);
    try std.testing.expect(plain.h < full.h);
    try std.testing.expectEqual(Item.close_all, plain.items[plain.n - 1]);
}

test "hits land on rows and on the opacity segments" {
    const l = layout(.{});
    const copy = l.rows[0];
    try std.testing.expectEqual(@as(u8, 0), hit(&l, copy.x + 20, copy.y + 10).?.index);
    const op = l.rows[l.find(.opacity).?];
    const third = segment(op, 2);
    const h = hit(&l, third.x + 5, third.y + 5).?;
    try std.testing.expectEqual(l.find(.opacity).?, h.index);
    try std.testing.expectEqual(@as(?u2, 2), h.seg);
    // the heading is the row, no segment
    try std.testing.expect(hit(&l, op.x + 10, op.y + 4).?.seg == null);
    try std.testing.expect(hit(&l, 1, 1) == null);
}

test "keyboard steps wrap around" {
    const l = layout(.{});
    try std.testing.expectEqual(@as(u8, 0), step(&l, null, 1));
    try std.testing.expectEqual(l.n - 1, step(&l, null, -1));
    try std.testing.expectEqual(@as(u8, 0), step(&l, l.n - 1, 1));
}

test "the menu opens toward where there is room, else grows the surface" {
    // room to the right and below
    try std.testing.expectEqual([2]i32{ 10, 10 }, place(.{ 10, 10 }, .{ 100, 50 }, .{ 400, 300 }, 10));
    // near the right edge: to the left of the pointer
    try std.testing.expectEqual([2]i32{ 280, 10 }, place(.{ 380, 10 }, .{ 100, 50 }, .{ 400, 300 }, 10));
    // a small pin: right and below, and the surface grows
    const at = place(.{ 40, 30 }, .{ 100, 50 }, .{ 80, 60 }, 10);
    try std.testing.expectEqual([2]i32{ 40, 30 }, at);
    try std.testing.expectEqual([2]u32{ 70, 30 }, growth(.{ .x = at[0], .y = at[1], .w = 100, .h = 50 }, .{ 80, 60 }, 10));
}
