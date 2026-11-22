//! The seat's keyboard: keymap, keys translated through the active
//! layout (keyboard.zig) with key repeat, modifiers and focus.

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const keyboard = @import("../keyboard.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");

const Window = window.Window;
const Key = window.Key;

pub const Keys = struct {
    /// wl_keyboard; 0 when the seat has none
    id: u32 = 0,
    /// surface index with keyboard focus
    surface: u8 = 0,
};

/// Take the seat's keyboard, or let go of it when the seat lost it.
pub fn updateDevice(w: *Window, has_keyboard: bool) !void {
    const c = &w.conn;
    const k = &w.keys;
    if (has_keyboard and k.id == 0) {
        k.id = c.newId();
        try c.request(w.globals.seat, wl.wl_seat.get_keyboard, &.{.{ .new_id = k.id }});
    } else if (!has_keyboard and k.id != 0) {
        if (w.globals.seat_version >= 3) try c.request(k.id, wl.wl_keyboard.release, &.{});
        k.id = 0;
        w.kb.leave();
    }
}

/// The Key event for evdev `code` in the active layout; updates the
/// window's ctrl/shift.
pub fn translate(w: *Window, code: u32, pressed: bool, use_compose: bool) Key {
    const t = w.kb.translate(code, pressed, use_compose);
    w.ctrl = t.ctrl;
    w.shift = t.shift;
    return .{
        .code = code,
        .pressed = pressed,
        .ctrl = t.ctrl,
        .shift = t.shift,
        .alt = t.alt,
        .caps = t.caps,
        .keysym = t.keysym,
        .text_buf = t.text_buf,
        .text_len = t.text_len,
    };
}

/// wl_keyboard events.
pub fn handleEvent(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_keyboard.ev_keymap => try onKeymap(w, r),
        wl.wl_keyboard.ev_key => try onKey(w, r),
        wl.wl_keyboard.ev_modifiers => try onModifiers(w, r),
        wl.wl_keyboard.ev_repeat_info => {
            const rate = try r.int();
            const delay = try r.int();
            w.kb.repeat.setInfo(rate, delay);
        },
        wl.wl_keyboard.ev_enter => {
            w.kb_focus = true;
            w.input_serial = try r.uint();
            w.keys.surface = surface.indexOf(w, try r.uint()) orelse 0;
            std.log.debug("keyboard focus: surface {d}", .{w.keys.surface});
        },
        wl.wl_keyboard.ev_leave => {
            w.kb_focus = false;
            std.log.debug("keyboard focus lost", .{});
            w.kb.leave();
        },
        else => {},
    }
}

fn onKeymap(w: *Window, r: *wl.ArgReader) !void {
    const format = try r.uint();
    const size = try r.uint();
    if (w.conn.takeFd()) |fd| {
        defer sys.close(fd);
        w.kb.setKeymapFd(format, fd, size);
    }
}

fn onKey(w: *Window, r: *wl.ArgReader) !void {
    const serial = try r.uint();
    _ = try r.uint(); // time
    const code = try r.uint();
    const state = try r.uint();
    w.input_serial = serial;
    const pressed = state == 1;
    const key = translate(w, code, pressed, true);
    if (pressed) {
        w.kb.repeat.press(code, w.kb.keyRepeats(code), keyboard.monotonicMs());
    } else {
        w.kb.repeat.release(code);
    }
    try w.queue.append(w.alloc, .{ .key = key });
}

fn onModifiers(w: *Window, r: *wl.ArgReader) !void {
    _ = try r.uint(); // serial
    const depressed = try r.uint();
    const latched = try r.uint();
    const locked = try r.uint();
    const group = try r.uint();
    w.kb.updateMods(depressed, latched, locked, group);
    const t = w.kb.translate(0, false, false);
    w.ctrl = t.ctrl;
    w.shift = t.shift;
}
