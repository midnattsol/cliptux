//! Layout of the quick access thumbnails in logical pixels: the card
//! stack (newest at the bottom), each card's controls and menu, the GNOME
//! hint above them, and hit testing.

const std = @import("std");
const Rect = @import("../../ui/shapes.zig").Rect;

// layout, logical pixels
pub const card_w = 240;
pub const card_h = 150;
pub const gap = 12;
/// room for the shadow around the cards (outside the input region)
pub const pad = 28;
/// distance from the screen edges to the window (layer shell)
pub const edge = 8;
pub const hint_h = 52;
pub const max_cards = 5;

pub const Control = enum { body, close, annotate, pin, copy, save, menu, hint };

pub const menu_items = [_]struct { label: []const u8, action: Action }{
    .{ .label = "Copy", .action = .copy },
    .{ .label = "Save", .action = .save },
    .{ .label = "Save As...", .action = .save_as },
    .{ .label = "Annotate", .action = .annotate },
    .{ .label = "Pin to screen", .action = .pin },
    .{ .label = "Close", .action = .close },
};

pub const Action = enum { copy, save, save_as, annotate, pin, close };

/// What is under a logical point.
pub const Hit = struct { card: usize = 0, control: Control, item: u8 = 0 };

/// Card i's rectangle (0 = newest, at the bottom) in a window of height h.
pub fn cardRect(i: usize, h: i32) Rect {
    const y = h - pad - card_h - @as(i32, @intCast(i)) * (card_h + gap);
    return .{ .x = pad, .y = y, .w = card_w, .h = card_h };
}

pub fn windowSize(n: usize, hint: bool) [2]u32 {
    const k: u32 = @intCast(@max(n, 1));
    return .{ card_w + 2 * pad, 2 * pad + k * card_h + (k - 1) * gap + if (hint) @as(u32, hint_h) else 0 };
}

/// Controls inside a card, relative to its top-left.
pub fn controlRect(c: Control) Rect {
    const pw = (card_w - 16 - 6) / 2;
    return switch (c) {
        .close => .{ .x = 8, .y = 8, .w = 26, .h = 26 },
        .annotate => .{ .x = card_w - 8 - 26 - 6 - 26, .y = 8, .w = 26, .h = 26 },
        .pin => .{ .x = card_w - 8 - 26, .y = 8, .w = 26, .h = 26 },
        .copy => .{ .x = 8, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .save => .{ .x = 8 + pw + 6, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        else => .{ .x = 0, .y = 0, .w = card_w, .h = card_h },
    };
}

pub const menu_row = 22;

pub fn menuTop() i32 {
    return @divTrunc(card_h - @as(i32, menu_items.len) * menu_row, 2);
}

/// Hit test at logical x, y with n cards (menu: whether each card shows
/// its menu).
pub fn hitTest(x: i32, y: i32, h: i32, n: usize, menus: []const bool, hint: bool) ?Hit {
    for (0..n) |i| {
        const r = cardRect(i, h);
        if (!r.contains(x, y)) continue;
        const lx = x - r.x;
        const ly = y - r.y;
        if (i < menus.len and menus[i]) {
            const row = @divFloor(ly - menuTop(), menu_row);
            if (row >= 0 and row < menu_items.len) return .{ .card = i, .control = .menu, .item = @intCast(row) };
            return .{ .card = i, .control = .body };
        }
        for ([_]Control{ .close, .annotate, .pin, .copy, .save }) |c| {
            if (controlRect(c).contains(lx, ly)) return .{ .card = i, .control = c };
        }
        return .{ .card = i, .control = .body };
    }
    if (hint) {
        if (hintRect().contains(x, y)) return .{ .control = .hint };
    }
    return null;
}

test "layout: newest card in the corner, controls where the mockup has them" {
    const t = std.testing;
    const sz = windowSize(2, false);
    try t.expectEqual([2]u32{ 240 + 2 * pad, 2 * pad + 2 * 150 + 12 }, sz);
    const h: i32 = @intCast(sz[1]);
    try t.expectEqual(@as(i32, h - pad - 150), cardRect(0, h).y);
    try t.expect(cardRect(1, h).y < cardRect(0, h).y);
    const none = [_]bool{ false, false };
    // close top-left, pin top-right, copy and save at the bottom
    const r0 = cardRect(0, h);
    try t.expectEqual(Control.close, hitTest(r0.x + 12, r0.y + 12, h, 2, &none, false).?.control);
    try t.expectEqual(Control.pin, hitTest(r0.x + card_w - 14, r0.y + 14, h, 2, &none, false).?.control);
    try t.expectEqual(Control.copy, hitTest(r0.x + 20, r0.y + card_h - 20, h, 2, &none, false).?.control);
    try t.expectEqual(Control.save, hitTest(r0.x + card_w - 20, r0.y + card_h - 20, h, 2, &none, false).?.control);
    try t.expectEqual(Control.body, hitTest(r0.x + 120, r0.y + 70, h, 2, &none, false).?.control);
    try t.expectEqual(@as(usize, 1), hitTest(r0.x + 120, cardRect(1, h).y + 70, h, 2, &none, false).?.card);
    // the shadow margin is not a card
    try t.expect(hitTest(4, h - 4, h, 2, &none, false) == null);
    // a card's menu takes its clicks
    const menus = [_]bool{ true, false };
    const m = hitTest(r0.x + 50, r0.y + menuTop() + menu_row * 2 + 5, h, 2, &menus, false).?;
    try t.expectEqual(Control.menu, m.control);
    try t.expectEqual(Action.save_as, menu_items[m.item].action);
}

/// The GNOME hint's pill, above the cards.
pub fn hintRect() Rect {
    return .{ .x = pad, .y = pad, .w = card_w, .h = hint_h - gap };
}
