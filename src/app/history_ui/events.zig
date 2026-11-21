//! Input of the "Recent captures" panel: hover, clicks, the wheel, and
//! keys (Enter copies, Delete removes, arrows move the pick, typing
//! searches, Esc clears the search, then the pick, then closes).

const std = @import("std");
const window = @import("../../ui/window.zig");
const layout = @import("layout.zig");
const Panel = @import("panel.zig").Panel;

const pad = layout.pad;
const inset = layout.inset;
const header_h = layout.header_h;

fn hitItem(self: *const Panel, x: i32, y: i32) ?usize {
    if (y < self.gridTop() or y >= self.gridTop() + self.gridViewH()) return null;
    for (self.shown.items, 0..) |idx, n| {
        if (self.itemRect(n).contains(x, y)) return idx;
    }
    return null;
}

fn hitAction(self: *const Panel, x: i32, y: i32) ?usize {
    if (self.selected == null) return null;
    for (0..layout.action_names.len) |i| if (self.actionRect(i).contains(x, y)) return i;
    return null;
}

fn onMotion(self: *Panel, bx: f64, by: f64) void {
    const kk = self.k();
    const x: i32 = @intFromFloat(bx / kk - pad);
    const y: i32 = @intFromFloat(by / kk - pad);
    const inside = bx >= 0;
    const hi = if (inside) hitItem(self, x, y) else null;
    const ha = if (inside) hitAction(self, x, y) else null;
    const hc = inside and self.clearRect().contains(x, y) and self.items.items.len > 0;
    const hx = inside and self.closeRect().contains(x, y);
    if (hi != self.hover_item or ha != self.hover_action or hc != self.hover_clear or hx != self.hover_close) self.dirty = true;
    self.hover_item = hi;
    self.hover_action = ha;
    self.hover_clear = hc;
    self.hover_close = hx;
}

/// Returns false to close the panel.
pub fn onEvent(self: *Panel, ev: window.InputEvent) !bool {
    switch (ev) {
        .close => return false,
        .resize, .frame_done => self.dirty = true,
        .pointer_motion => |m| onMotion(self, m.x, m.y),
        .pointer_button => |b| {
            onMotion(self, b.x, b.y);
            if (b.button != window.BTN_LEFT or !b.pressed) return true;
            return onPress(self, b.y);
        },
        .pointer_axis => |a| {
            const maxs = @max(0, self.contentH() - self.gridViewH());
            self.scroll = std.math.clamp(self.scroll + @as(i32, @intFromFloat(a.value * 4)), 0, maxs);
            self.dirty = true;
        },
        .key => |key| {
            if (!key.pressed) return true;
            if (!onKey(self, key)) return false;
            self.dirty = true;
        },
    }
    return true;
}

/// A left press on what is hovered; returns false to close.
fn onPress(self: *Panel, by: f64) !bool {
    const y: i32 = @intFromFloat(by / self.k() - pad);
    if (self.hover_close) return false;
    if (self.hover_clear) {
        try self.clearAll();
    } else if (self.hover_action) |a| {
        self.act(@fromBackingInt(@intCast(a)));
    } else if (self.hover_item) |i| {
        self.selected = if (self.selected == i) null else i;
        self.dirty = true;
    } else if (y < inset + header_h + 4) {
        try self.win.startMoveOf(0);
    }
    return true;
}

/// A key press; returns false to close.
fn onKey(self: *Panel, key: window.Key) bool {
    switch (key.code) {
        window.KEY_ESC => {
            if (self.search.items.len > 0) {
                self.search.clearRetainingCapacity();
                self.filter();
            } else if (self.selected != null) {
                self.selected = null;
            } else return false;
        },
        window.KEY_DELETE => self.act(.delete),
        window.KEY_ENTER, window.KEY_KPENTER => self.act(.copy),
        window.KEY_BACKSPACE => if (self.search.items.len > 0) {
            var n = self.search.items.len - 1;
            while (n > 0 and (self.search.items[n] & 0xC0) == 0x80) n -= 1;
            self.search.shrinkRetainingCapacity(n);
            self.filter();
        },
        window.KEY_LEFT, window.KEY_RIGHT, window.KEY_UP, window.KEY_DOWN, window.KEY_TAB => moveSelection(self, key.code, key.shift),
        else => if (key.ctrl and key.code == 46) {
            self.act(.copy);
        } else if (key.ctrl and key.code == 31) {
            self.act(.save);
        } else if (self.searchable and key.text().len > 0 and !key.ctrl) {
            self.search.appendSlice(self.gpa, key.text()) catch {};
            self.filter();
        },
    }
    return true;
}

fn moveSelection(self: *Panel, code: u32, shift: bool) void {
    if (self.shown.items.len == 0) return;
    const n = self.shown.items.len;
    var pos: usize = if (self.selected) |s| std.mem.indexOfScalar(usize, self.shown.items, s) orelse 0 else n - 1;
    const step: usize = switch (code) {
        window.KEY_UP => n - @min(n, 2),
        window.KEY_DOWN => 2,
        window.KEY_LEFT => n - 1,
        window.KEY_TAB => if (shift) n - 1 else 1,
        else => 1,
    };
    if (self.selected == null) pos = if (code == window.KEY_LEFT or (code == window.KEY_TAB and shift)) 0 else n - 1;
    pos = (pos + step) % n;
    self.selected = self.shown.items[pos];
    // keep it in view
    const r = self.itemRect(pos);
    if (r.y < self.gridTop()) self.scroll -= self.gridTop() - r.y;
    if (r.bottom() > self.gridTop() + self.gridViewH()) self.scroll += r.bottom() - self.gridTop() - self.gridViewH();
}
