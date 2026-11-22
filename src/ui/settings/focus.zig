//! Keyboard focus and the key map of the Settings window: which controls
//! take focus, the Tab order, and what a key press means.

const std = @import("std");
const window = @import("../../platform/api.zig").window;
const model = @import("model.zig");

const Hit = model.Hit;
const Region = model.Region;

pub const KeyCommand = enum { none, close, next, prev, activate };

/// Keyboard map of the settings window: Tab/Shift+Tab and arrows move
/// focus, Space/Enter activate, Esc (or Q) closes.
pub fn keyCommand(k: window.Key) KeyCommand {
    return switch (k.code) {
        .escape => .close,
        .tab => if (k.shift) .prev else .next,
        .down, .right => .next,
        .up, .left => .prev,
        .space, .enter, .kp_enter => .activate,
        else => if (!k.ctrl and (k.char == 'q' or k.char == 'Q')) .close else .none,
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
        fn k(code: window.KeyCode, shift: bool, char: u21) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = false, .shift = shift, .char = char };
        }
    };
    try t.expectEqual(KeyCommand.next, keyCommand(K.k(.tab, false, 0)));
    try t.expectEqual(KeyCommand.prev, keyCommand(K.k(.tab, true, 0)));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(.space, false, ' ')));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(.enter, false, 0)));
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(.escape, false, 0)));
    // Q closes by the layout's character, wherever it puts it (AZERTY:
    // the key US layouts have A on)
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(.a, false, 'q')));
    try t.expectEqual(KeyCommand.none, keyCommand(K.k(.q, false, 'a')));
}
