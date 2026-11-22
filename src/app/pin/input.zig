//! A pin's pointer: hover (its buttons, the menu's rows), drag to move,
//! scroll to zoom, right-click or ⋯ for the menu, and clicks on the menu
//! and the lock badge. Event positions are buffer pixels on the surface.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const state = @import("state.zig");
const menu = @import("menu.zig");
const chrome = @import("chrome.zig");
const view = @import("view.zig");
const keys = @import("keys.zig");
const actions = @import("actions.zig");

const Pin = state.Pin;
const Hover = state.Hover;
/// the pointer away from the pin this long closes its menu
const leave_close_ms = 700;

pub fn handle(p: *Pin, ev: window.InputEvent) !void {
    const k = p.scale();
    switch (ev) {
        .close => p.quit = true,
        .resize => p.dirty = true,
        .frame_done => {},
        .key => |key| if (key.pressed and p.edit == null) keys.onKey(p, key),
        .pointer_axis => |a| onAxis(p, if (a.value120) |n| @as(f64, @floatFromInt(n)) / 120.0 else a.value / 10.0),
        .pointer_motion => |m| try onMotion(p, m.x, m.y, k),
        .pointer_button => |b| try onButton(p, b.button, b.pressed, b.x, b.y, k),
    }
}

fn onAxis(p: *Pin, v: f64) void {
    if (p.locked or p.menu.open) return;
    p.scroll_acc += v;
    const steps: i32 = @intFromFloat(@trunc(p.scroll_acc));
    if (steps == 0) return;
    p.scroll_acc -= @floatFromInt(steps);
    p.setZoom(view.zoomStep(p.zoom, steps));
}

fn logical(v: f64, k: f64) i32 {
    return @intFromFloat(@floor(v / k));
}

/// What is under the pointer; on the menu, its hot row follows.
fn hoverAt(p: *Pin, x: f64, y: f64, k: f64) Hover {
    const lx = logical(x, k);
    const ly = logical(y, k);
    if (p.menu.open and p.menu.rect().contains(lx, ly)) {
        const h = menu.hit(&p.menu.lay, lx - p.menu.at[0], ly - p.menu.at[1]);
        p.menu.hot = if (h) |v| v.index else null;
        p.menu.hot_seg = if (h) |v| v.seg else null;
        return .menu;
    }
    if (p.menu.open) {
        p.menu.hot = null;
        p.menu.hot_seg = null;
    }
    if (!p.picRect(k).contains(lx, ly)) return .none;
    const ox = state.pad * k;
    return chrome.under(p.scaled_w, k, x - ox, y - ox, p.locked);
}

fn onMotion(p: *Pin, x: f64, y: f64, k: f64) !void {
    const inside = x >= 0;
    const now = sys.monoMs();
    const Seen = struct { Hover, ?u8, ?u2 };
    const was: Seen = .{ p.hover, p.menu.hot, p.menu.hot_seg };
    if (inside) {
        p.pointer = .{ x, y };
        p.hover = hoverAt(p, x, y, k);
        p.menu.close_at = 0;
    } else {
        p.hover = .none;
        if (p.menu.open) p.menu.close_at = now + leave_close_ms;
    }
    if (!std.meta.eql(was, Seen{ p.hover, p.menu.hot, p.menu.hot_seg })) p.dirty = true;
    if (p.drag_from) |from| try dragTo(p, from, inside, x, y, k);
}

/// Layer shell: follows the pointer by moving the margins. Positions
/// on the pin cannot say how far the pointer went: the pin moves under
/// it with a delay, and compositors differ on which place a held
/// button's motion is relative to (sway: where the press happened).
/// Relative pointer motion is the pointer's own.
fn dragTo(p: *Pin, from: [2]f64, inside: bool, x: f64, y: f64, k: f64) !void {
    const rel = p.win.takeRelative() orelse .{ 0, 0 };
    // absolute devices (tablets; KWin's fake input) may move the
    // pointer without relative motion: then go by positions, which
    // KWin gives relative to where the pin is now
    if (rel[0] != 0 or rel[1] != 0) p.drag_rel = true;
    if (p.drag_rel) {
        p.drag_at[0] += rel[1];
        p.drag_at[1] += rel[0];
    } else if (inside) {
        p.drag_at[0] += (y - from[1]) / k;
        p.drag_at[1] += (x - from[0]) / k;
    }
    const top: i32 = @intFromFloat(@round(p.drag_at[0]));
    const left: i32 = @intFromFloat(@round(p.drag_at[1]));
    if (top != p.margin[0] or left != p.margin[3]) {
        p.margin[0] = top;
        p.margin[3] = left;
        try p.win.setLayerPlacement(0, p.lw, p.lh, p.margin);
    }
}

fn onButton(p: *Pin, button: window.Button, pressed: bool, x: f64, y: f64, k: f64) !void {
    const now = sys.monoMs();
    if (p.menu.open) {
        if (p.hover == .menu) {
            // a row acts when the button comes up on it
            if (!pressed and (button == .left or button == .right)) {
                const h = menu.hit(&p.menu.lay, logical(x, k) - p.menu.at[0], logical(y, k) - p.menu.at[1]) orelse return;
                actions.activate(p, h);
            }
            return;
        }
        // a press elsewhere on the pin closes the menu; a right-click
        // opens it again there
        if (pressed) p.closeMenu(now);
        if (button != .right) return;
    }
    if (!pressed) {
        if (button == .left) p.drag_from = null;
        return;
    }
    switch (button) {
        .left => try onLeftPress(p, x, y, k, now),
        .right => p.openMenu(.{ logical(x, k), logical(y, k) }, false, now),
        .middle => if (!p.locked) {
            p.quit = true;
        },
        else => {},
    }
}

fn onLeftPress(p: *Pin, x: f64, y: f64, k: f64, now: i64) !void {
    switch (p.hover) {
        .close => p.quit = true,
        .more => {
            // below the ⋯ button, from its left edge
            const c = chrome.centre(.more, p.scaled_w, k);
            const anchor: [2]i32 = .{ logical(c[0], k) + state.pad - chrome.radius, logical(c[1], k) + state.pad + chrome.radius + 4 };
            p.openMenu(anchor, false, now);
        },
        .badge => actions.setLocked(p, false),
        .picture => if (p.layer) {
            p.drag_from = .{ x, y };
            p.drag_at = .{ @floatFromInt(p.margin[0]), @floatFromInt(p.margin[3]) };
            p.drag_rel = false;
            _ = p.win.takeRelative();
        } else try p.win.startMoveOf(0),
        .none, .menu => {},
    }
}
