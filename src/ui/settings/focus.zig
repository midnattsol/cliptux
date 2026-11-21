//! Keyboard focus and the key map of the Settings window: which controls
//! take focus, the Tab order, and what a key press means.

const std = @import("std");
const window = @import("../window.zig");
const model = @import("model.zig");

const Hit = model.Hit;
const Region = model.Region;

pub const KeyCommand = enum { none, close, next, prev, activate };

/// Keyboard map of the settings window: Tab/Shift+Tab and arrows move
/// focus, Space/Enter activate, Esc (or Q) closes.
pub fn keyCommand(k: window.Key) KeyCommand {
    return switch (k.code) {
        window.KEY_ESC => .close,
        window.KEY_TAB => if (k.shift) .prev else .next,
        window.KEY_DOWN, window.KEY_RIGHT => .next,
        window.KEY_UP, window.KEY_LEFT => .prev,
        window.KEY_SPACE, window.KEY_ENTER, window.KEY_KPENTER => .activate,
        else => if (!k.ctrl and (k.keysym == 'q' or k.keysym == 'Q')) .close else .none,
    };
}

pub fn isModifier(code: u32) bool {
    return switch (code) {
        29, 97, 42, 54, 56, 100, 125, 126 => true, // ctrl/shift/alt/super
        else => false,
    };
}

/// Controls in the fixed header bar (not scrolled with the content).
pub fn isHeader(hit: Hit) bool {
    return hit == .win_close or hit == .view;
}

/// The close button is mouse-only (Esc closes); everything else takes focus.
pub fn isFocusable(hit: Hit) bool {
    return hit != .win_close;
}

pub fn findRegion(regions: []const Region, hit: Hit) ?Region {
    for (regions) |r| if (std.meta.eql(r.hit, hit)) return r;
    return null;
}

/// Next (or previous) focusable control after `current`, wrapping around.
pub fn nextFocus(regions: []const Region, current: ?Hit, forward: bool) ?Hit {
    // the header's view switcher first, then the content in reading order
    var list: [64]Hit = undefined;
    var n: usize = 0;
    for ([_]bool{ true, false }) |header| {
        for (regions) |r| {
            if (!isFocusable(r.hit) or isHeader(r.hit) != header or n == list.len) continue;
            list[n] = r.hit;
            n += 1;
        }
    }
    if (n == 0) return null;
    const cur = current orelse return if (forward) list[0] else list[n - 1];
    for (list[0..n], 0..) |h, i| {
        if (std.meta.eql(h, cur)) {
            return if (forward) list[(i + 1) % n] else list[(i + n - 1) % n];
        }
    }
    return if (forward) list[0] else list[n - 1];
}

test "tab order wraps and skips the close button" {
    const regions = [_]Region{
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .toggle_notify },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .{ .color = 2 } },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .reset_binds },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .win_close },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .{ .view = .editor } },
    };
    const t = std.testing;
    // the view switcher comes first, wherever it was drawn
    try t.expect(std.meta.eql(nextFocus(&regions, null, true).?, Hit{ .view = .editor }));
    try t.expect(std.meta.eql(nextFocus(&regions, .{ .view = .editor }, true).?, Hit.toggle_notify));
    try t.expect(std.meta.eql(nextFocus(&regions, null, false).?, Hit.reset_binds));
    try t.expect(std.meta.eql(nextFocus(&regions, .toggle_notify, true).?, Hit{ .color = 2 }));
    try t.expect(std.meta.eql(nextFocus(&regions, .reset_binds, true).?, Hit{ .view = .editor }));
    try t.expect(std.meta.eql(nextFocus(&regions, .toggle_notify, false).?, Hit{ .view = .editor }));
    try t.expect(nextFocus(&.{}, null, true) == null);
}

test "settings key commands" {
    const t = std.testing;
    const K = struct {
        fn k(code: u32, shift: bool, keysym: u32) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = false, .shift = shift, .keysym = keysym };
        }
    };
    try t.expectEqual(KeyCommand.next, keyCommand(K.k(window.KEY_TAB, false, 0)));
    try t.expectEqual(KeyCommand.prev, keyCommand(K.k(window.KEY_TAB, true, 0)));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(window.KEY_SPACE, false, ' ')));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(window.KEY_ENTER, false, 0)));
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(window.KEY_ESC, false, 0)));
    // Q closes by keysym, wherever the layout puts it (AZERTY: evdev 30)
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(30, false, 'q')));
    try t.expectEqual(KeyCommand.none, keyCommand(K.k(16, false, 'a')));
}
