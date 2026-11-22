//! A focused pin's keys: the menu's shortcuts (Ctrl+C, Ctrl+S, Ctrl+E,
//! Ctrl+L, Ctrl+W, Ctrl+Shift+W, 1-4), the zoom (- = 0), Esc, and the
//! Menu key (or Shift+F10) for the menu; with the menu open, the arrows,
//! Tab, Enter and Esc move through it.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const state = @import("state.zig");
const menu = @import("menu.zig");
const view = @import("view.zig");
const actions = @import("actions.zig");

const Pin = state.Pin;
const Key = window.Key;

pub fn onKey(p: *Pin, key: Key) void {
    const now = sys.monoMs();
    if (p.menu.open and menuKey(p, key, now)) return;
    if (shortcut(key)) |it| {
        p.closeMenu(now);
        return actions.run(p, it);
    }
    if (opacityKey(key.code)) |o| return p.setOpacity(o);
    switch (key.code) {
        .escape => p.quit = true,
        .minus, .kp_minus => p.setZoom(view.zoomStep(p.zoom, 1)), // - zooms out
        .equal, .kp_plus => p.setZoom(view.zoomStep(p.zoom, -1)), // = + zooms in
        .digit_0 => p.setZoom(1), // 0: 100%
        .menu => p.openMenu(.{ state.pad + 8, state.pad + 8 }, true, now),
        .f10 => if (key.shift) p.openMenu(.{ state.pad + 8, state.pad + 8 }, true, now),
        else => {},
    }
}

/// The menu item a Ctrl shortcut stands for (letters as the layout has
/// them).
pub fn shortcut(key: Key) ?menu.Item {
    if (!key.ctrl or key.alt) return null;
    const c: u8 = if (key.char != 0 and key.char < 128) @intCast(key.char) else key.code.letterChar() orelse return null;
    return switch (std.ascii.toLower(c)) {
        'c' => .copy,
        's' => .save,
        'e' => .annotate,
        'l' => .lock,
        'w' => if (key.shift) .close_all else .close,
        else => null,
    };
}

/// 1 to 4 on the digit row or the keypad.
fn opacityKey(code: window.KeyCode) ?view.Opacity {
    return switch (code) {
        .kp_1 => .full,
        .kp_2 => .three_quarters,
        .kp_3 => .half,
        .kp_4 => .quarter,
        else => view.Opacity.fromDigit(code.digitChar() orelse return null),
    };
}

/// The menu's own keys; false when the key is not one of them.
fn menuKey(p: *Pin, key: Key, now: i64) bool {
    const l = &p.menu.lay;
    switch (key.code) {
        .escape, .menu => p.closeMenu(now),
        .up => p.menu.hot = menu.step(l, p.menu.hot, -1),
        .down => p.menu.hot = menu.step(l, p.menu.hot, 1),
        .tab => p.menu.hot = menu.step(l, p.menu.hot, if (key.shift) -1 else 1),
        .left, .right => {
            const i = p.menu.hot orelse return false;
            if (l.items[i] != .opacity) return false;
            p.setOpacity(stepOpacity(p.opacity, if (key.code == .left) -1 else 1));
        },
        .enter, .kp_enter, .space => actions.activate(p, .{ .index = p.menu.hot orelse return true }),
        else => return false,
    }
    p.menu.hot_seg = null;
    p.dirty = true;
    return true;
}

/// The next opacity left (-1) or right (+1) in the menu, stopping at the ends.
pub fn stepOpacity(o: view.Opacity, dir: i2) view.Opacity {
    const i: i32 = @backingInt(o);
    return @fromBackingInt(@intCast(std.math.clamp(i + dir, 0, view.Opacity.all.len - 1)));
}

test "Ctrl shortcuts follow the layout's letters" {
    const base: Key = .{ .code = .c, .pressed = true, .ctrl = true, .shift = false, .char = 'c' };
    try std.testing.expectEqual(menu.Item.copy, shortcut(base).?);
    var w = base;
    w.code = .w;
    w.char = 'w';
    try std.testing.expectEqual(menu.Item.close, shortcut(w).?);
    w.shift = true;
    w.char = 'W';
    try std.testing.expectEqual(menu.Item.close_all, shortcut(w).?);
    // the key labelled S on another layout: its character decides
    var s = base;
    s.code = .semicolon;
    s.char = 's';
    try std.testing.expectEqual(menu.Item.save, shortcut(s).?);
    var plain = base;
    plain.ctrl = false;
    try std.testing.expect(shortcut(plain) == null);
}

test "opacity keys and arrows" {
    try std.testing.expectEqual(view.Opacity.half, opacityKey(.digit_3).?);
    try std.testing.expectEqual(view.Opacity.quarter, opacityKey(.kp_4).?);
    try std.testing.expect(opacityKey(.digit_5) == null);
    try std.testing.expectEqual(view.Opacity.full, stepOpacity(.full, -1));
    try std.testing.expectEqual(view.Opacity.three_quarters, stepOpacity(.full, 1));
    try std.testing.expectEqual(view.Opacity.quarter, stepOpacity(.quarter, 1));
}
