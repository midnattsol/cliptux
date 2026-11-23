//! The window seam's platform-neutral types: input events, key and button
//! codes, cursors, how a floating surface is placed, and drag-and-drop
//! states. A backend's `Window` produces and takes these.
//!
//! A key event names the physical key (api/keys.zig), the character it
//! stands for in the active layout and the UTF-8 text it types; a
//! backend translates its native key events into these.

/// Most surfaces one window has (one per monitor for the editor).
pub const max_surfaces = 8;
/// Most monitors tracked.
pub const max_outputs = 8;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

const keys = @import("keys.zig");
pub const KeyCode = keys.Code;
pub const Button = keys.Button;

pub const InputEvent = union(enum) {
    pointer_motion: struct { x: f64, y: f64, surface: u8 = 0 },
    pointer_button: struct { button: Button, pressed: bool, x: f64, y: f64, surface: u8 = 0 },
    /// vertical scroll, positive = down. `value120`: exact wheel notches
    /// (120 per notch) when the device reports them
    pointer_axis: struct { value: f64, value120: ?i32 = null, surface: u8 = 0 },
    key: Key,
    /// buffer was (re)created at this pixel size; caller must redraw.
    /// w == h == 0: the surface is gone (output unplugged)
    resize: struct { w: u32, h: u32, surface: u8 = 0 },
    close,
    frame_done,
};

pub const Key = struct {
    /// the physical key; none for text from an input method
    code: KeyCode,
    pressed: bool,
    ctrl: bool,
    shift: bool,
    alt: bool = false,
    /// Caps Lock is on (already applied to text)
    caps: bool = false,
    /// true for presses synthesized by key repeat
    repeat: bool = false,
    /// input-method preedit changed; read Window.preedit() (code is none)
    preedit: bool = false,
    /// the character the key stands for in the active layout, with Shift
    /// and Caps Lock applied but not Ctrl (Ctrl+Q has 'q'); 0 for keys
    /// that are no character (Enter, arrows, dead keys) or when unknown
    char: u21 = 0,
    /// UTF-8 text the key produces in the active layout (after dead keys
    /// and compose); empty for keys that type nothing or with Ctrl held
    text_buf: [16]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn text(self: *const Key) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// The pointer's shape over our surfaces. A backend shows the desktop's
/// own cursor for each where it can, else draws a lookalike.
pub const Cursor = enum {
    crosshair,
    arrow,
    /// over something that a drag moves (open hand)
    grab,
    /// while dragging it (closed hand)
    grabbing,
    text,
    resize_nwse,
    resize_nesw,
    resize_ns,
    resize_ew,

    /// The hand over something draggable: closed while `held`.
    pub fn hand(held: bool) Cursor {
        return if (held) .grabbing else .grab;
    }
};

/// A floating surface above other windows (thumbnails, pins, controls),
/// where the platform has such surfaces (Linux: wlr-layer-shell); an
/// ordinary window otherwise. The bit and value layouts are the
/// wlr-layer-shell ones.
pub const Layer = struct {
    layer: Level = .overlay,
    /// the screen edges it sticks to
    anchor: Anchor = .{},
    /// logical size; 0 along an axis anchored on both edges stretches
    width: u32 = 0,
    height: u32 = 0,
    /// top, right, bottom, left (logical pixels)
    margin: [4]i32 = .{ 0, 0, 0, 0 },
    keyboard: Keyboard = .on_demand,
    /// what the compositor may call it (rules, animations)
    namespace: []const u8 = "shotlet",

    pub const Level = enum(u32) { background = 0, bottom = 1, top = 2, overlay = 3 };
    pub const Anchor = packed struct(u32) {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
        _: u28 = 0,
    };
    /// none: never takes keys; exclusive: takes them all while shown;
    /// on_demand: when clicked, like a window
    pub const Keyboard = enum(u32) { none = 0, exclusive = 1, on_demand = 2 };
};

/// How Window.open makes a surface.
pub const OpenOptions = struct {
    fullscreen: bool = true,
    /// ask to be maximized (the work area: panels stay visible)
    maximized: bool = false,
    /// fallback size when the platform lets the client decide
    width: u32 = 800,
    height: u32 = 500,
    /// premultiplied ARGB buffers: see-through where alpha < 255
    transparent: bool = false,
    /// a floating surface where the platform has them; ignored
    /// otherwise (an ordinary window as the rest describes)
    layer: ?Layer = null,
};

/// Progress of a drag out of one of our surfaces (Window.startDrag).
pub const DragState = enum {
    none,
    /// the pointer is carrying the data
    active,
    /// dropped on a target that accepted; it may still be reading
    dropped,
    /// the target took the data (copy done)
    finished,
    /// nobody accepted it, or it was cancelled
    cancelled,
};

/// A premultiplied ARGB image to show under the pointer while dragging.
pub const DragIcon = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    /// buffer pixels per logical pixel
    scale: i32 = 1,
};

/// Data dropped on one of our surfaces: one of Window.accept_mimes.
pub const Dropped = struct {
    mime: []const u8,
    data: []u8,
};

test {
    _ = keys;
}

test "layer anchors and keyboard use wlr-layer-shell's values" {
    const std = @import("std");
    const a: Layer.Anchor = .{ .top = true, .right = true };
    try std.testing.expectEqual(@as(u32, 1 | 8), @as(u32, @bitCast(a)));
    try std.testing.expectEqual(@as(u32, 2), @backingInt(Layer.Keyboard.on_demand));
}

test "the hand closes while held" {
    const std = @import("std");
    try std.testing.expectEqual(Cursor.grab, Cursor.hand(false));
    try std.testing.expectEqual(Cursor.grabbing, Cursor.hand(true));
}
