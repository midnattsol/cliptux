//! Window events in: routes each to the pointer, drag, key or render
//! handlers, and tracks the pointer's surface and held modifiers.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const ui = @import("../editor_ui.zig");
const tall_view = @import("../tall_view.zig");
const caches = @import("caches.zig");
const pointer = @import("pointer.zig");
const drag = @import("drag.zig");
const hit = @import("hit.zig");
const keys_input = @import("keys_input.zig");
const props = @import("props.zig");
const text_edit = @import("text_edit.zig");
const history = @import("history.zig");
const render = @import("render.zig");
const loupe_input = @import("loupe_input.zig");

const Editor = editor.Editor;

pub fn handle(ed: *Editor, ev: window.InputEvent) !void {
    switch (ev) {
        // other surfaces are the integrator's (one view per monitor)
        .resize => |r| try caches.onResize(ed, r.surface, r.w, r.h),
        .frame_done => if (render.renderReady(ed)) try render.renderFrame(ed),
        .close => {
            ed.action = .cancel;
            ed.running = false;
        },
        .pointer_motion => |m| {
            const was = ed.mouse;
            pointerAt(ed, m.surface, m.x, m.y);
            if (!std.meta.eql(was, ed.mouse)) ui.loupePointed(ed);
            try drag.onMotion(ed);
        },
        .pointer_button => |b| {
            pointerAt(ed, b.surface, b.x, b.y);
            try onButtonEvent(ed, b.button, b.pressed);
        },
        .pointer_axis => |a| try onScroll(ed, a.value, a.value120),
        .key => |k| try onKeyEvent(ed, k),
    }
    // input may start, end or cancel a drag, or change what lies under
    // the pointer
    switch (ev) {
        .pointer_motion, .pointer_button, .key => try ed.win.setCursor(hit.cursorFor(ed, ed.mouse)),
        else => {},
    }
}

/// The pointer is at (`x`, `y`) of `surface`.
fn pointerAt(ed: *Editor, surface: u8, x: f64, y: f64) void {
    pointerOn(ed, surface);
    ed.mouse = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

fn onButtonEvent(ed: *Editor, button: window.Button, pressed: bool) !void {
    if (pressed) loupe_input.pointerPressed(ed);
    if (button == .left) {
        if (pressed) try pointer.onPress(ed) else try drag.onRelease(ed);
    } else if (button == .right and pressed) {
        _ = try history.cancelOne(ed);
    }
}

fn onKeyEvent(ed: *Editor, k: window.Key) !void {
    try trackModifiers(ed, k);
    loupe_input.track(ed, k);
    if (k.code == .none) {
        // input method: committed text or a preedit change, never a
        // shortcut
        if (k.pressed and ed.picker.open) {
            if (ui.pickerKey(ed, k) orelse false) try props.applyPickerColor(ed);
        } else if (k.pressed and ed.text != null) try text_edit.typeText(ed, k);
        ed.needs_render = true;
    } else if (k.pressed) try keys_input.onKey(ed, k);
}

fn pointerOn(ed: *Editor, surface: u8) void {
    if (surface >= ed.n_panes or !ed.panes[surface].alive) return;
    if (surface != ed.mouse_pane) ed.needs_render = true;
    ed.mouse_pane = surface;
    ed.pane_i = surface;
}

/// Held Shift/Alt/Space shape the drag in progress (constrain, draw
/// from the centre, move the selection), so track them, releases too.
fn trackModifiers(ed: *Editor, k: window.Key) !void {
    switch (k.code) {
        .shift_left, .shift_right => ed.mod_shift = k.pressed,
        .alt_left, .alt_right => ed.mod_alt = k.pressed,
        .space => {
            const dragging = ed.drag == .selecting or ed.drag == .drawing;
            if (k.pressed and dragging) ed.space.held = true;
            if (!k.pressed) ed.space.held = false;
        },
        else => return,
    }
    // re-apply the constraint at the current pointer position
    if (ed.drag == .selecting or ed.drag == .drawing) {
        ed.space.last = null;
        try drag.onMotion(ed);
    }
}

/// The wheel scrolls a tall image, else zooms the magnifier while it
/// shows, else changes the stroke width.
fn onScroll(ed: *Editor, value: f64, value120: ?i32) !void {
    // exact notches when the wheel reports them (8 units = 1/15 notch)
    const steps = if (value120) |v| editor.scrollSteps(&ed.scroll_acc, @as(f64, @floatFromInt(v)) / 8.0) else editor.scrollSteps(&ed.scroll_acc, value);
    if (steps != 0 and !ed.win.ctrl and tall_view.isTall(ed.img.width, ed.img.height, ed.screenRect())) return caches.scrollTall(ed, -steps);
    if (loupe_input.onScroll(ed, steps)) return;
    if (steps != 0) try props.setThickness(ed, ed.thickness + steps);
}
