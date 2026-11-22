//! Input and time of the quick access thumbnails: hover, clicks, drags
//! out, the right-click menu, keyboard shortcuts and focus, and each
//! card's life (fade in, stay, fade out).

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Control = layout.Control;
const fade_ms = stack.fade_ms;
const fade_in_ms = stack.fade_in_ms;

pub fn onEvent(self: *Quick, ev: window.InputEvent) void {
    switch (ev) {
        .resize, .frame_done => self.dirty = true,
        .close => {
            for (self.cards.items) |*c| if (c.fade_from == 0) {
                c.fade_from = sys.monoMs();
            };
        },
        .pointer_motion => |m| onMotion(self, m.x, m.y),
        .pointer_button => |b| onButton(self, b.button, b.pressed, b.x, b.y),
        .pointer_axis => {},
        .key => |k| if (k.pressed) {
            // a layer surface has the keyboard only while the pointer
            // is over it, but KWin keeps it focused after that: keys
            // then belong to whatever the person went back to typing
            // in, not to the thumbnail's shortcuts
            if (self.layer and !self.win.pointer_in) {
                std.log.debug("quick access: key ignored, the pointer is elsewhere", .{});
            } else onKey(self, k);
        },
    }
}

/// Hover, and a drag out once a pressed card moved far enough.
fn onMotion(self: *Quick, x: f64, y: f64) void {
    if (self.layer) self.win.setLayerKeyboard(0, self.win.pointer_in) catch {};
    const h = self.hitAt(x, y);
    if (!std.meta.eql(h, self.hover)) self.dirty = true;
    self.hover = h;
    if (self.pressed) |p| if (p.control == .body and self.dragging == null) {
        const k = self.f();
        const dx = (x - self.press_x) / k;
        const dy = (y - self.press_y) / k;
        if (dx * dx + dy * dy > 36) {
            self.pressed = null;
            self.startDrag(p.card) catch |err| std.log.warn("quick access: drag failed: {t}", .{err});
        }
    };
}

/// Right press toggles a card's menu; a left click (press and release
/// on the same control) activates it.
fn onButton(self: *Quick, button: window.Button, pressed: bool, x: f64, y: f64) void {
    const h = self.hitAt(x, y);
    self.hover = h;
    self.dirty = true;
    if (button == .right and pressed) {
        if (h) |hh| if (hh.control != .hint) {
            const c = &self.cards.items[hh.card];
            c.menu = !c.menu;
        };
    } else if (button == .left) {
        if (pressed) {
            self.pressed = h;
            self.press_x = x;
            self.press_y = y;
            self.focus = null;
        } else {
            const p = self.pressed;
            self.pressed = null;
            if (p != null and h != null and std.meta.eql(p.?, h.?)) self.activate(h.?);
        }
    }
}

const focus_order = [_]Control{ .primary, .secondary, .annotate, .pin, .close };

fn onKey(self: *Quick, k: window.Key) void {
    self.dirty = true;
    const cur = self.current() orelse return;
    const card = &self.cards.items[cur];
    switch (k.code) {
        .escape => {
            if (card.menu) card.menu = false else self.act(cur, .close);
        },
        .tab, .right, .left => cycleFocus(self, k.shift or k.code == .left),
        .up, .down => {
            const n = self.cards.items.len;
            const c: usize = if (k.code == .up) (cur + 1) % n else (cur + n - 1) % n;
            self.focus = .{ .card = c, .control = if (self.focus) |fo| fo.control else .primary };
        },
        .enter, .kp_enter, .space => {
            if (self.focus) |fo| self.activate(fo) else self.act(cur, .copy);
        },
        .delete => self.act(cur, .close),
        .c => if (k.ctrl) self.act(cur, .copy),
        .s => if (k.ctrl) self.act(cur, if (k.shift) .save_as else .save),
        .e, .a => if (!k.ctrl) self.act(cur, .annotate),
        .p => if (!k.ctrl) self.act(cur, .pin),
        else => {},
    }
}

/// Move focus to the next (or previous) control, across all cards.
fn cycleFocus(self: *Quick, back: bool) void {
    const n = self.cards.items.len * focus_order.len;
    var idx: usize = 0;
    if (self.focus) |fo| {
        const pos = std.mem.indexOfScalar(Control, &focus_order, fo.control) orelse 0;
        idx = fo.card * focus_order.len + pos;
        idx = if (back) (idx + n - 1) % n else (idx + 1) % n;
    }
    self.focus = .{ .card = idx / focus_order.len, .control = focus_order[idx % focus_order.len] };
}

// --- time ---

/// Age the cards: keep them while used, fade them out when their time
/// is up, drop the faded ones.
pub fn tick(self: *Quick) void {
    const now = sys.monoMs();
    const keep_alive = self.win.pointer_in or self.dragging != null;
    var i: usize = 0;
    while (i < self.cards.items.len) {
        const c = &self.cards.items[i];
        if (c.menu or (keep_alive and c.fade_from == 0)) c.deadline_ms = @max(c.deadline_ms, now + 2000);
        if (c.fade_from == 0 and now >= c.deadline_ms) c.fade_from = now;
        if (c.notice_until != 0 and now >= c.notice_until) {
            c.notice_until = 0;
            c.notice = "";
            self.dirty = true;
        }
        if (fading(c, now)) self.dirty = true;
        if (c.fade_from != 0 and now - c.fade_from >= fade_ms) {
            self.remove(i);
            continue;
        }
        i += 1;
    }
}

/// Not drawn yet, fading in or out, or its controls fading: a frame per
/// refresh.
fn fading(c: *const stack.Card, now: i64) bool {
    return c.born_ms == 0 or c.fade_from != 0 or now - c.born_ms < fade_in_ms or c.hov.busy(now);
}

pub fn nextWakeMs(self: *const Quick) i32 {
    var wait: i64 = 1000;
    const now = sys.monoMs();
    for (self.cards.items) |*c| {
        if (fading(c, now)) return 16;
        wait = @min(wait, c.deadline_ms - now);
        if (c.notice_until != 0) wait = @min(wait, c.notice_until - now);
    }
    return @intCast(std.math.clamp(wait, 5, 1000));
}
