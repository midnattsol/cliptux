//! The window seam of the contract: `Window`, its surfaces and outputs,
//! with the neutral types of api/window.zig.

const std = @import("std");
const types = @import("../api/window.zig");

pub const InputEvent = types.InputEvent;
pub const Key = types.Key;
pub const KeyCode = types.KeyCode;
pub const Button = types.Button;
pub const max_surfaces = types.max_surfaces;
pub const max_outputs = types.max_outputs;
pub const Rect = types.Rect;
pub const Layer = types.Layer;
pub const OpenOptions = types.OpenOptions;
pub const Cursor = types.Cursor;
pub const Dropped = types.Dropped;
pub const DragState = types.DragState;
pub const DragIcon = types.DragIcon;

/// One surface of a window: its buffer and logical size, scale, and
/// for one per output, that output's logical rectangle.
pub const Surface = struct {
    /// buffer pixels
    width: u32 = 0,
    height: u32 = 0,
    /// effective scale * 120
    scale120: u32 = 120,
    /// size in logical pixels
    logical_w: u32 = 0,
    logical_h: u32 = 0,
    /// openOutputs(): the output's logical rectangle; zero otherwise
    x: i32 = 0,
    y: i32 = 0,
    out_w: u32 = 0,
    out_h: u32 = 0,
    /// the output it is fullscreen on (Output.id); 0: the platform picks
    output: u32 = 0,
    frame_pending: bool = false,
    configured: bool = false,
    alive: bool = false,
    maximized: bool = false,
    transparent: bool = false,
    fullscreen: bool = false,
    /// which of its two buffers backBufferOf gave last (damage is kept
    /// per buffer)
    cur_buf: usize = 0,
};

/// A monitor: its logical rectangle and scale.
pub const Output = struct {
    /// 0: an empty slot
    id: u32 = 0,
    scale: i32 = 1,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn name(self: *const Output) []const u8 {
        _ = self;
        return "";
    }
    pub fn description(self: *const Output) []const u8 {
        _ = self;
        return "";
    }
    pub fn logicalRect(self: *const Output) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }
};

const Error = error{ Unavailable, OutOfMemory, NoSuchSurface };

/// A software-rendered window: one surface, or one per output. The
/// classic fields mirror surface 0; pointer positions are in the buffer
/// pixels of the surface under the pointer. See the Linux window.zig for
/// the full description of the behaviour a backend must have.
pub const Window = struct {
    alloc: std.mem.Allocator,
    surfaces: [max_surfaces]Surface = @splat(.{}),
    n_surfaces: u8 = 0,

    /// text and PNG we offer on the clipboard
    clipboard_text: []u8 = &.{},
    clipboard_png: []u8 = &.{},
    drag_state: DragState = .none,
    /// drops we take, best first; a completed one lands in `dropped`
    accept_mimes: []const []const u8 = &.{},
    dropped: ?Dropped = null,

    pointer_in: bool = false,
    kb_focus: bool = false,
    /// queue a pointer_motion to (-1, -1) when the pointer leaves
    report_leave: bool = false,
    /// collect relative pointer motion (takeRelative); set before open()
    track_relative: bool = false,

    // mirrors of surface 0
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    scale120: u32 = 120,
    maximized: bool = false,
    configured: bool = false,
    frame_pending: bool = false,

    default_w: u32 = 800,
    default_h: u32 = 500,

    ctrl: bool = false,
    shift: bool = false,
    current_cursor: Cursor = .crosshair,

    /// events not handed out yet
    queue: std.ArrayList(InputEvent) = .empty,

    pub const OpenOptions = types.OpenOptions;

    /// Connect to the display (`runtime_dir`, `display`: Env's).
    pub fn init(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8) Error!Window {
        _ = .{ runtime_dir, display };
        return .{ .alloc = alloc };
    }
    pub fn deinit(w: *Window) void {
        w.queue.deinit(w.alloc);
    }
    /// Floating surfaces (OpenOptions.layer) are available.
    pub fn hasLayerShell(w: *const Window) bool {
        _ = w;
        return false;
    }
    pub fn open(w: *Window, title: []const u8, opts: types.OpenOptions) Error!void {
        _ = .{ w, title, opts };
        return error.Unavailable;
    }
    /// One fullscreen surface per output.
    pub fn openOutputs(w: *Window, title: []const u8) Error!void {
        _ = .{ w, title };
        return error.Unavailable;
    }
    /// One fullscreen surface on the output whose rectangle starts at x, y.
    pub fn openOnOutputAt(w: *Window, title: []const u8, x: i32, y: i32) Error!void {
        _ = .{ w, title, x, y };
        return error.Unavailable;
    }
    pub fn closeWindow(w: *Window) void {
        _ = w;
    }
    pub fn surfaceList(w: *Window) []Surface {
        return w.surfaces[0..w.n_surfaces];
    }
    pub fn outputList(w: *Window) []const Output {
        _ = w;
        return &.{};
    }
    /// Flush requests to the display server.
    pub fn flush(w: *Window) Error!void {
        _ = w;
    }
    /// The name of key `code` in the layout (for shortcuts in Settings);
    /// `fallback` when it has none.
    pub fn keyName(w: *Window, code: KeyCode, buf: []u8) []const u8 {
        _ = .{ w, buf };
        return code.label();
    }
    /// The descriptor to poll for the window's events.
    pub fn pollFd(w: *const Window) i32 {
        _ = w;
        return -1;
    }

    // drawing
    pub fn backBuffer(w: *Window) Error![]u32 {
        _ = w;
        return error.Unavailable;
    }
    pub fn backBufferOf(w: *Window, idx: u8) Error![]u32 {
        _ = .{ w, idx };
        return error.NoSuchSurface;
    }
    pub fn present(w: *Window) Error!void {
        _ = w;
    }
    pub fn presentSurface(w: *Window, idx: u8) Error!void {
        _ = .{ w, idx };
    }
    /// Present with only `damage` (buffer pixels) changed.
    pub fn presentDamaged(w: *Window, idx: u8, damage: ?Rect) Error!void {
        _ = .{ w, idx, damage };
    }

    // events
    pub fn nextEvent(w: *Window) Error!InputEvent {
        _ = w;
        return .close;
    }
    pub fn nextEventTimeout(w: *Window, timeout_ms: i32) Error!?InputEvent {
        _ = .{ w, timeout_ms };
        return .close;
    }
    /// The poll timeout that keeps key repeat and timers on time.
    pub fn pollTimeoutMs(w: *const Window, max_ms: i32) i32 {
        _ = w;
        return max_ms;
    }
    /// Read what the display server sent, without waiting.
    pub fn drainPending(w: *Window) Error!void {
        _ = w;
    }

    // input
    /// Relative pointer motion since the last call (logical pixels).
    pub fn takeRelative(w: *Window) ?[2]f64 {
        _ = w;
        return null;
    }
    pub fn setCursor(w: *Window, kind: Cursor) Error!void {
        w.current_cursor = kind;
    }
    /// Input-method composition at `cursor_rect` while text is edited.
    pub fn setTextInput(w: *Window, enabled: bool, cursor_rect: ?Rect) Error!void {
        _ = .{ w, enabled, cursor_rect };
    }
    pub fn hasTextInput(w: *const Window) bool {
        _ = w;
        return false;
    }
    /// The input method's text being composed.
    pub fn preedit(w: *const Window) []const u8 {
        _ = w;
        return "";
    }

    // the surfaces' roles and regions
    pub fn startMove(w: *Window) Error!void {
        _ = w;
    }
    pub fn startMoveOf(w: *Window, idx: u8) Error!void {
        _ = .{ w, idx };
    }
    pub fn toggleMaximize(w: *Window) Error!void {
        _ = w;
    }
    pub fn minimize(w: *Window) Error!void {
        _ = w;
    }
    /// Where clicks land (null: everywhere); elsewhere they pass through.
    pub fn setInputRegion(w: *Window, idx: u8, rects: ?[]const Rect) Error!void {
        _ = .{ w, idx, rects };
    }
    /// The window's visible part (its shadow excluded), logical.
    pub fn setWindowGeometry(w: *Window, idx: u8, r: Rect) Error!void {
        _ = .{ w, idx, r };
    }
    pub fn setTitle(w: *Window, idx: u8, title: []const u8) Error!void {
        _ = .{ w, idx, title };
    }
    /// A handle another process's dialog can be parented to.
    pub fn parentHandle(w: *Window, buf: []u8) Error![]const u8 {
        _ = .{ w, buf };
        return error.Unavailable;
    }
    pub fn unexport(w: *Window) void {
        _ = w;
    }
    pub fn showWindowMenu(w: *Window, idx: u8, x: i32, y: i32) Error!void {
        _ = .{ w, idx, x, y };
    }
    /// Move or resize a floating surface (logical size and margins).
    pub fn setLayerPlacement(w: *Window, idx: u8, width: u32, height: u32, margin: [4]i32) Error!void {
        _ = .{ w, idx, width, height, margin };
    }
    pub fn setLayerKeyboard(w: *Window, idx: u8, on_demand: bool) Error!void {
        _ = .{ w, idx, on_demand };
    }
    pub fn resizeTo(w: *Window, idx: u8, width: u32, height: u32) Error!void {
        _ = .{ w, idx, width, height };
    }

    // the clipboard and drag and drop
    pub fn hasClipboard(w: *const Window) bool {
        _ = w;
        return false;
    }
    /// The PNG we offer, if any.
    pub fn clipboardPng(w: *Window) ?[]const u8 {
        _ = w;
        return null;
    }
    /// Offer `data` (owned) as image/png.
    pub fn setClipboardPng(w: *Window, data: []u8) Error!void {
        _ = .{ w, data };
    }
    /// Offer pixels (encoded once asked for).
    pub fn setClipboardImage(w: *Window, pixels: []u32, width: u32, height: u32) Error!void {
        _ = .{ w, pixels, width, height };
    }
    /// Offer `data` (owned) as text.
    pub fn setClipboardText(w: *Window, data: []u8) Error!void {
        _ = .{ w, data };
    }
    /// Offer `clipboard_text`/`clipboard_png` under these types.
    pub fn claimClipboardSource(w: *Window, mimes: []const []const u8) Error!void {
        _ = .{ w, mimes };
    }
    /// Keep answering paste requests until another client owns it.
    pub fn serveClipboard(w: *Window) Error!void {
        _ = w;
    }
    /// The clipboard's text, owned.
    pub fn clipboardText(w: *Window, alloc: std.mem.Allocator, max_bytes: usize, timeout_ms: i64) Error!?[]u8 {
        _ = .{ w, alloc, max_bytes, timeout_ms };
        return null;
    }
    /// The clipboard's content in one of accept_mimes.
    pub fn clipboardAccepted(w: *Window, alloc: std.mem.Allocator, max_bytes: usize, timeout_ms: i64) Error!?Dropped {
        _ = .{ w, alloc, max_bytes, timeout_ms };
        return null;
    }
    /// Drag a PNG (and its file) out of surface `idx`.
    pub fn startDrag(w: *Window, idx: u8, png_data: []u8, uri_list: []u8, icon: ?DragIcon) Error!void {
        _ = .{ w, idx, png_data, uri_list, icon };
    }
    pub fn endDrag(w: *Window) void {
        _ = w;
    }
};
