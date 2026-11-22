//! The window seam of the contract: `Window`, its surfaces and outputs,
//! with the neutral types of api/window.zig.

const std = @import("std");
const types = @import("../api/window.zig");

pub const InputEvent = types.InputEvent;
pub const Key = types.Key;
pub const BTN_LEFT = types.BTN_LEFT;
pub const BTN_RIGHT = types.BTN_RIGHT;
pub const BTN_MIDDLE = types.BTN_MIDDLE;
pub const KEY_ESC = types.KEY_ESC;
pub const KEY_ENTER = types.KEY_ENTER;
pub const KEY_BACKSPACE = types.KEY_BACKSPACE;
pub const KEY_TAB = types.KEY_TAB;
pub const KEY_SPACE = types.KEY_SPACE;
pub const KEY_DELETE = types.KEY_DELETE;
pub const KEY_LEFTCTRL = types.KEY_LEFTCTRL;
pub const KEY_RIGHTCTRL = types.KEY_RIGHTCTRL;
pub const KEY_LEFTSHIFT = types.KEY_LEFTSHIFT;
pub const KEY_RIGHTSHIFT = types.KEY_RIGHTSHIFT;
pub const KEY_UP = types.KEY_UP;
pub const KEY_LEFT = types.KEY_LEFT;
pub const KEY_RIGHT = types.KEY_RIGHT;
pub const KEY_DOWN = types.KEY_DOWN;
pub const KEY_KPENTER = types.KEY_KPENTER;
pub const max_surfaces = types.max_surfaces;
pub const max_outputs = types.max_outputs;
pub const Rect = types.Rect;
pub const Layer = types.Layer;
pub const Cursor = types.Cursor;
pub const Dropped = types.Dropped;
pub const DragState = types.DragState;
pub const DragIcon = types.DragIcon;

pub const Window = struct {
    alloc: std.mem.Allocator,
};
