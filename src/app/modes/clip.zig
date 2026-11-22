//! Copy a capture taken without the editor: compositors only take the
//! clipboard from a client with the keyboard focus, so a tiny see-through
//! surface takes it for a moment (as wl-copy does), sets the selection and
//! closes; the process then serves the data until another app takes the
//! clipboard, like the editor after Copy.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;

/// Wait at most this long for the focus.
const focus_ms = 1500;

fn waitFocus(win: *window.Window) !void {
    const deadline = sys.monoMs() + focus_ms;
    while (!win.kb_focus) {
        const left = deadline - sys.monoMs();
        if (left <= 0) return error.NoFocus;
        _ = try win.nextEventTimeout(@intCast(left));
    }
}

fn paintClear(win: *window.Window) !void {
    const px = try win.backBuffer();
    @memset(px, 0);
    try win.present();
}

/// Put `data` (owned, PNG) on the clipboard. Returns once it is set; call
/// win.serveClipboard() afterwards.
pub fn copyPng(win: *window.Window, data: []u8) !void {
    const opts: window.Window.OpenOptions = .{ .fullscreen = false, .transparent = true, .width = 4, .height = 4, .layer = .{
        .width = 4,
        .height = 4,
        .keyboard = .exclusive,
        .namespace = "shotlet-copy",
    } };
    try win.open("shotlet:copy", opts);
    defer win.closeWindow();
    try paintClear(win);
    try waitFocus(win);
    try win.setClipboardPng(data);
}
