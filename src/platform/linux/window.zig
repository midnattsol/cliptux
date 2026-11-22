//! Software-rendered windows on top of the raw Wayland client: registry and
//! global management, shm double buffering, pointer/keyboard input (real
//! layouts via keyboard.zig), custom cursors, clipboard ownership, HiDPI
//! and IME (text-input-v3).
//!
//! ## Single surface (the classic API)
//!
//!     var win = try Window.init(alloc, runtime_dir, display);
//!     try win.open("title", .{ .fullscreen = true });
//!     const px = try win.backBuffer();   // win.width x win.height pixels
//!     try win.present();
//!
//! `win.width`, `win.height`, `win.scale120` and `win.frame_pending` always
//! describe surface 0. Pointer coordinates are in that surface's buffer
//! pixels.
//!
//! ## One fullscreen surface per output (additive)
//!
//!     try win.openOutputs("title");          // falls back to open() if no outputs are known
//!     for (win.surfaceList(), 0..) |*s, i| {
//!         if (!s.alive) continue;
//!         const px = try win.backBufferOf(@intCast(i)); // s.width x s.height
//!         // s.x, s.y, s.out_w, s.out_h: the output's rectangle in the
//!         // compositor's logical desktop space; s.scale120: its scale
//!         try win.presentSurface(@intCast(i));
//!     }
//!
//! - Pointer events carry `surface: u8`, the index of the surface under the
//!   pointer; x/y are in that surface's buffer pixels.
//! - `.resize` carries `surface: u8`. A resize with w == 0 and h == 0 means
//!   that surface is gone (its output was unplugged); its `alive` is false
//!   and it must not be drawn. Surface 0 is never torn down while open, so
//!   the classic fields stay valid (the compositor moves it elsewhere).
//! - `.frame_done` is queued when any surface's frame callback fires;
//!   check `surfaceList()[i].frame_pending` per surface.
//! - Outputs plugged in after openOutputs() are tracked in outputList() but
//!   get no surface automatically.
//!
//! ## Keyboard and IME
//!
//! `.key` events carry the neutral key (keyboard/evdev.zig translates the
//! evdev code), the character of the layout's keysym and the text (see
//! Key). Held keys repeat per wl_keyboard.repeat_info as presses with
//! `repeat = true`; nextEvent/nextEventTimeout wake up for them.
//!
//! When the compositor offers zwp_text_input_v3, `setTextInput(true, rect)`
//! enables input-method composition while text is being edited (pass the
//! caret rectangle in buffer pixels of the focused surface) and
//! `setTextInput(false, null)` disables it. Then:
//! - committed text arrives as `.key` with code == .none, pressed == true,
//!   char == 0 and text() == the committed UTF-8 (long commits are split
//!   into several events at character boundaries);
//! - preedit (composition in progress) changes arrive as `.key` with
//!   code == .none, pressed == false and preedit == true; read the current
//!   string with `win.preedit()` (empty when composition ended) and draw it
//!   at the caret. Without the protocol nothing changes.
//!
//! ## Debugging
//!
//! SHOTLET_DUMP_FRAME=/path/prefix writes each surface's last presented
//! frame to <prefix>-<surface>.png when the window closes.
//!
//! ## Layout
//!
//! Facade over window/: registry (connection, globals, seat devices),
//! output, surface (objects and configure), roles (toplevel and layer
//! requests), scale, buffers (shm and present), lifecycle (open/close),
//! events (wait loop and dispatch), pointer, keys, text_input, cursor,
//! data_device (offers, drops, clipboard reads), clipboard (our
//! selection), drag (drags out) and dump.

const std = @import("std");
const wl = @import("wayland.zig");
const render = @import("../../gfx/render.zig");
const sys = @import("sys.zig");
const keyboard = @import("keyboard.zig");
const registry = @import("window/registry.zig");
const output = @import("window/output.zig");
const surface = @import("window/surface.zig");
const roles = @import("window/roles.zig");
const scale_mod = @import("window/scale.zig");
const buffers = @import("window/buffers.zig");
const lifecycle = @import("window/lifecycle.zig");
const events = @import("window/events.zig");
const pointer = @import("window/pointer.zig");
const keys = @import("window/keys.zig");
const text_input = @import("window/text_input.zig");
const cursor = @import("window/cursor.zig");
const data_device = @import("window/data_device.zig");
const clipboard = @import("window/clipboard.zig");
const drag = @import("window/drag.zig");
const foreign = @import("window/foreign.zig");

// Reach every submodule's tests (a `test {}` block would count as one).
comptime {
    _ = registry;
    _ = output;
    _ = surface;
    _ = roles;
    _ = scale_mod;
    _ = buffers;
    _ = lifecycle;
    _ = events;
    _ = pointer;
    _ = keys;
    _ = text_input;
    _ = cursor;
    _ = data_device;
    _ = clipboard;
    _ = drag;
    _ = @import("window/dump.zig");
}

// the seam's neutral types (src/platform/api/window.zig)
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

pub const Output = output.Output;
pub const Surface = surface.Surface;

pub const bufferSize = scale_mod.bufferSize;
pub const outputBufferSize = scale_mod.outputBufferSize;
pub const pickIntScale = scale_mod.pickIntScale;
pub const utf8Chunk = text_input.utf8Chunk;

// clipboard and drag-and-drop payloads (transfer.zig)
const transfer = @import("../../ui/transfer.zig");
pub const readBounded = transfer.readBounded;
pub const drag_mimes = transfer.drag_mimes;
pub const dragPayloadFor = transfer.dragPayloadFor;
pub const fileUriList = transfer.fileUriList;

pub const Window = struct {
    alloc: std.mem.Allocator,
    conn: wl.Connection,

    // components (window/*.zig); their state is internal
    globals: registry.Globals = .{},
    outputs: output.Outputs = .{},
    pointer: pointer.Pointer = .{},
    keys: keys.Keys = .{},
    text_input: text_input.TextInput = .{},
    cursors: cursor.Cursors = .{},
    data_device: data_device.DataDevice = .{},
    clipboard: clipboard.Clipboard = .{},
    drag: drag.Drag = .{},

    // surfaces; index 0 is the classic single window
    surfaces: [max_surfaces]Surface = @splat(.{}),
    n_surfaces: u8 = 0,

    /// text we offer on the clipboard (text/plain;charset=utf-8, UTF8_STRING)
    clipboard_text: []u8 = &.{},
    /// the PNG we offer on the clipboard (setClipboardPng)
    clipboard_png: []u8 = &.{},
    /// progress of a drag started with startDrag()
    drag_state: DragState = .none,
    // drops onto our surfaces: types taken, best first (empty: none);
    // a completed drop lands in `dropped` (caller frees .data)
    accept_mimes: []const []const u8 = &.{},
    dropped: ?Dropped = null,

    /// our toplevel as exported for another client's dialog (foreign.zig)
    exported: u32 = 0,

    /// pointer over one of our surfaces / keyboard focus on one
    pointer_in: bool = false,
    kb_focus: bool = false,
    /// queue a pointer_motion to (-1, -1) when the pointer leaves
    report_leave: bool = false,
    /// pointer movement (logical pixels) from zwp_relative_pointer_v1,
    /// summed until the caller takes it (takeRelative); only collected
    /// when set before open(). Independent of where our surfaces are,
    /// unlike wl_pointer positions: for moving a layer surface by drag.
    track_relative: bool = false,

    // mirrors of surface 0, kept for the single-surface API
    width: u32 = 0, // buffer pixels
    height: u32 = 0,
    scale: u32 = 1,
    scale120: u32 = 120,
    maximized: bool = false,
    configured: bool = false,
    frame_pending: bool = false,

    default_w: u32 = 800, // used when the compositor lets the client decide
    default_h: u32 = 500,

    // keyboard state shared with callers
    ctrl: bool = false,
    shift: bool = false,
    /// layout translation (libxkbcommon when available) and key repeat
    kb: keyboard.Keyboard = .{},
    /// last button/key serial, for set_selection, moves and drags
    input_serial: u32 = 0,
    current_cursor: Cursor = .crosshair,

    // queued logical events (one wayland message may produce several)
    queue: std.ArrayList(InputEvent) = .empty,

    pub const OpenOptions = lifecycle.OpenOptions;

    // connection and lifecycle
    pub const init = registry.init;
    pub const deinit = lifecycle.deinit;
    pub const hasLayerShell = registry.hasLayerShell;
    pub const open = lifecycle.open;
    pub const openOutputs = lifecycle.openOutputs;
    pub const openOnOutputAt = lifecycle.openOnOutputAt;
    pub const closeWindow = lifecycle.closeWindow;
    pub const surfaceList = surface.surfaceList;
    pub const outputList = output.outputList;

    /// Flush requests to the compositor.
    pub fn flush(w: *Window) !void {
        try w.conn.flush();
    }

    /// The name of key `code` in the layout (for shortcuts in Settings);
    /// its US label (KeyCode.label) when the layout has none.
    pub fn keyName(w: *Window, code: KeyCode, buf: []u8) []const u8 {
        const evcode = keyboard.evdev.fromCode(code) orelse return code.label();
        return w.kb.keyName(evcode, buf, code.label());
    }

    /// The descriptor to poll for the window's events.
    pub fn pollFd(w: *const Window) sys.fd_t {
        return w.conn.fd;
    }

    // drawing
    pub const backBuffer = buffers.backBuffer;
    pub const backBufferOf = buffers.backBufferOf;
    pub const present = buffers.present;
    pub const presentSurface = buffers.presentSurface;
    pub const presentDamaged = buffers.presentDamaged;

    // events
    pub const nextEvent = events.nextEvent;
    pub const nextEventTimeout = events.nextEventTimeout;
    pub const pollTimeoutMs = events.pollTimeoutMs;
    pub const drainPending = events.drainPending;
    const roundtrip = registry.roundtrip;
    const handleGlobalRemove = registry.handleGlobalRemove;

    // input
    pub const takeRelative = pointer.takeRelative;
    pub const setCursor = cursor.setCursor;
    pub const setTextInput = text_input.setTextInput;
    pub const hasTextInput = text_input.hasTextInput;
    pub const preedit = text_input.preedit;

    // surface roles and regions
    pub const startMove = roles.startMove;
    pub const startMoveOf = roles.startMoveOf;
    pub const toggleMaximize = roles.toggleMaximize;
    pub const minimize = roles.minimize;
    pub const setInputRegion = roles.setInputRegion;
    pub const setWindowGeometry = roles.setWindowGeometry;
    pub const setTitle = roles.setTitle;
    pub const parentHandle = foreign.parentHandle;
    pub const unexport = foreign.unexport;
    pub const showWindowMenu = roles.showWindowMenu;
    pub const setLayerPlacement = roles.setLayerPlacement;
    pub const setLayerKeyboard = roles.setLayerKeyboard;
    pub const resizeTo = roles.resizeTo;

    // clipboard and drag and drop
    pub const hasClipboard = clipboard.hasClipboard;
    pub const clipboardPng = clipboard.clipboardPng;
    pub const setClipboardPng = clipboard.setClipboardPng;
    pub const setClipboardImage = clipboard.setClipboardImage;
    pub const setClipboardText = clipboard.setClipboardText;
    pub const claimClipboardSource = clipboard.claimClipboardSource;
    pub const serveClipboard = clipboard.serveClipboard;
    pub const clipboardText = data_device.clipboardText;
    pub const clipboardAccepted = data_device.clipboardAccepted;
    pub const startDrag = drag.startDrag;
    pub const endDrag = drag.endDrag;
};

test "window decls compile" {
    std.testing.refAllDecls(Window);
}

// Live check against a real compositor, skipped unless
// SHOTLET_LIVE_WINDOW_TEST=1 (run it inside tools/headless.sh, never on a
// real desktop): opens one surface per output, paints each a distinct
// color with its index bar, presents and waits for the frames.
test "live: one surface per output" {
    if (std.c.getenv("SHOTLET_LIVE_WINDOW_TEST") == null) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const rt = std.mem.span(std.c.getenv("XDG_RUNTIME_DIR") orelse return error.SkipZigTest);
    const disp = std.mem.span(std.c.getenv("WAYLAND_DISPLAY") orelse return error.SkipZigTest);
    var win = try Window.init(alloc, rt, disp);
    defer win.deinit();
    var n_out: usize = 0;
    for (win.outputList()) |o| if (o.id != 0) {
        n_out += 1;
        const r = o.logicalRect();
        std.debug.print("output {s} \"{s}\": {d},{d} {d}x{d} scale {d}\n", .{ o.name(), o.description(), r.x, r.y, r.w, r.h, o.scale });
    };
    try win.openOutputs("Shotlet live test");
    // IME: enabling/disabling must not upset the compositor
    std.debug.print("text-input-v3: {}\n", .{win.hasTextInput()});
    try win.setTextInput(true, .{ .x = 100, .y = 100, .w = 2, .h = 20 });
    try win.roundtrip();
    try win.setTextInput(false, null);
    try win.roundtrip();
    try std.testing.expectEqual(n_out, win.surfaceList().len);
    const colors = [_]u32{ 0xFF2060C0, 0xFFC04020, 0xFF20A040, 0xFFA0A020 };
    for (win.surfaceList(), 0..) |s, i| {
        std.debug.print("surface {d}: output {d} at {d},{d} {d}x{d}, buffer {d}x{d} scale120 {d}\n", .{ i, s.output, s.x, s.y, s.out_w, s.out_h, s.width, s.height, s.scale120 });
        try std.testing.expect(s.alive and s.width > 0 and s.height > 0);
        const px = try win.backBufferOf(@intCast(i));
        @memset(px, colors[i % colors.len]);
        var cv = render.Canvas.init(px, s.width, s.height);
        // i+1 white blocks identify the surface in the dump
        for (0..i + 1) |k| cv.fillRect(@intCast(40 + k * 60), 40, 40, 40, 0xFFFFFFFF);
        try win.presentSurface(@intCast(i));
    }
    // classic fields mirror surface 0
    try std.testing.expectEqual(win.surfaces[0].width, win.width);
    try std.testing.expectEqual(win.surfaces[0].height, win.height);
    var waited: usize = 0;
    while (waited < 40) : (waited += 1) {
        var pending = false;
        for (win.surfaceList()) |s| pending = pending or (s.alive and s.frame_pending);
        if (!pending) break;
        _ = try win.nextEventTimeout(50);
    }
    win.queue.clearRetainingCapacity();
    if (win.surfaceList().len > 1 and std.c.getenv("SHOTLET_LIVE_WAIT_MS") == null) {
        // unplug: simulate the registry removing output of surface 1 (a
        // real unplug is exercised by tools when the compositor allows it)
        const gone = win.surfaces[1].output;
        try win.handleGlobalRemove(gone);
        try std.testing.expect(!win.surfaces[1].alive);
        try std.testing.expectError(error.NoSuchSurface, win.presentSurface(1));
        try std.testing.expectError(error.NoSuchSurface, win.backBufferOf(1));
        var saw_gone = false;
        for (win.queue.items) |ev| if (ev == .resize and ev.resize.surface == 1 and ev.resize.w == 0) {
            saw_gone = true;
        };
        try std.testing.expect(saw_gone);
        // surface 0 keeps working and the connection stays healthy
        const px = try win.backBuffer();
        @memset(px, 0xFF303030);
        try win.present();
        try win.roundtrip();
    }
    // wait for a real unplug when the harness triggers one
    if (std.c.getenv("SHOTLET_LIVE_WAIT_MS")) |ms_z| {
        const ms = std.fmt.parseInt(i64, std.mem.span(ms_z), 10) catch 0;
        const end = keyboard.monotonicMs() + ms;
        while (keyboard.monotonicMs() < end) _ = try win.nextEventTimeout(100);
        var alive: usize = 0;
        for (win.surfaceList()) |s| alive += @intFromBool(s.alive);
        std.debug.print("after wait: {d} surfaces alive, outputs:", .{alive});
        for (win.outputList()) |o| if (o.id != 0) std.debug.print(" {s} (scale {d})", .{ o.name(), o.scale });
        std.debug.print("\n", .{});
        const s0 = &win.surfaces[0];
        std.debug.print("surface 0 now: logical {d}x{d}, buffer {d}x{d}, scale120 {d}, buffer scale {d}\n", .{ s0.logical_w, s0.logical_h, s0.width, s0.height, s0.scale120, s0.committed_scale });
        // repaint so the dump shows the final buffer size
        const px = try win.backBuffer();
        @memset(px, 0xFF406080);
        try win.present();
        _ = try win.nextEventTimeout(200);
    }
    win.closeWindow();
}
