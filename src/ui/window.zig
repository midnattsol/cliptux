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
//! `.key` events carry the evdev code, the layout's keysym and text (see
//! Key). Held keys repeat per wl_keyboard.repeat_info as presses with
//! `repeat = true`; nextEvent/nextEventTimeout wake up for them.
//!
//! When the compositor offers zwp_text_input_v3, `setTextInput(true, rect)`
//! enables input-method composition while text is being edited (pass the
//! caret rectangle in buffer pixels of the focused surface) and
//! `setTextInput(false, null)` disables it. Then:
//! - committed text arrives as `.key` with code == 0, pressed == true,
//!   keysym == 0 and text() == the committed UTF-8 (long commits are split
//!   into several events at character boundaries);
//! - preedit (composition in progress) changes arrive as `.key` with
//!   code == 0, pressed == false and preedit == true; read the current
//!   string with `win.preedit()` (empty when composition ended) and draw it
//!   at the caret. Without the protocol nothing changes.
//!
//! ## Debugging
//!
//! SHOTLET_DUMP_FRAME=/path/prefix writes each surface's last presented
//! frame to <prefix>-<surface>.png when the window closes.

const std = @import("std");
const sys = @import("../platform/sys.zig");
const wl = @import("../platform/wayland.zig");
const render = @import("../gfx/render.zig");
const png = @import("../gfx/png.zig");
const keyboard = @import("keyboard.zig");

pub const InputEvent = union(enum) {
    pointer_motion: struct { x: f64, y: f64, surface: u8 = 0 },
    pointer_button: struct { button: u32, pressed: bool, x: f64, y: f64, surface: u8 = 0 },
    /// vertical scroll, positive = down. `value120`: exact wheel notches
    /// (120 per notch, wl_pointer v8) when the device reports them
    pointer_axis: struct { value: f64, value120: ?i32 = null, surface: u8 = 0 },
    key: Key,
    /// buffer was (re)created at this pixel size; caller must redraw.
    /// w == h == 0: the surface is gone (output unplugged)
    resize: struct { w: u32, h: u32, surface: u8 = 0 },
    close,
    frame_done,
};

pub const Key = struct {
    /// evdev code: the physical key; 0 for IME text (see the top of file)
    code: u32,
    pressed: bool,
    ctrl: bool,
    shift: bool,
    alt: bool = false,
    /// Caps Lock is on (already applied to text)
    caps: bool = false,
    /// true for presses synthesized by key repeat
    repeat: bool = false,
    /// IME preedit changed; read Window.preedit() (code is 0)
    preedit: bool = false,
    /// xkb keysym for the active layout; 0 when unknown
    keysym: u32 = 0,
    /// UTF-8 text the key produces in the active layout (after dead keys
    /// and compose); empty for keys that type nothing or with Ctrl held
    text_buf: [16]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn text(self: *const Key) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

// evdev key codes (linux/input-event-codes.h)
pub const KEY_ESC: u32 = 1;
pub const KEY_ENTER: u32 = 28;
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_TAB: u32 = 15;
pub const KEY_SPACE: u32 = 57;
pub const KEY_DELETE: u32 = 111;
pub const KEY_LEFTCTRL: u32 = 29;
pub const KEY_RIGHTCTRL: u32 = 97;
pub const KEY_LEFTSHIFT: u32 = 42;
pub const KEY_RIGHTSHIFT: u32 = 54;
pub const KEY_UP: u32 = 103;
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_DOWN: u32 = 108;
pub const KEY_KPENTER: u32 = 96;

pub const max_surfaces = 8;
pub const max_outputs = 8;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

const Buffer = struct {
    id: u32 = 0,
    busy: bool = false,
    // 4-byte aligned: the pool is page-aligned and buf_size is a multiple
    // of 4 (stride = w*4), so each buffer offset is u32-aligned. It is NOT
    // page-aligned for arbitrary window sizes, only u32-aligned.
    pixels: []align(4) u8 = &.{},
};

/// A wl_output the compositor announced.
pub const Output = struct {
    /// wl_output object id; 0 = empty slot
    id: u32 = 0,
    /// registry global name (stable identity of the output)
    global: u32 = 0,
    version: u32 = 0,
    xdg: u32 = 0, // zxdg_output_v1
    /// integer scale (wl_output.scale)
    scale: i32 = 1,
    /// logical rectangle in the compositor's desktop space
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    has_logical: bool = false,
    geo_x: i32 = 0,
    geo_y: i32 = 0,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    desc_buf: [128]u8 = @splat(0),
    desc_len: u8 = 0,
    done: bool = false,

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn description(self: *const Output) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    /// Logical rectangle: xdg_output when known, else derived from the
    /// wl_output geometry, current mode and integer scale.
    pub fn logicalRect(self: *const Output) Rect {
        if (self.has_logical and self.w > 0 and self.h > 0)
            return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
        const sc = @max(1, self.scale);
        return .{ .x = self.geo_x, .y = self.geo_y, .w = @divTrunc(self.mode_w, sc), .h = @divTrunc(self.mode_h, sc) };
    }
};

/// One wl_surface + xdg toplevel with its own shm buffers and scale.
pub const Surface = struct {
    // --- public, read-only for callers ---
    /// buffer pixels
    width: u32 = 0,
    height: u32 = 0,
    /// effective scale * 120 (fractional, or the integer buffer scale)
    scale120: u32 = 120,
    /// surface size in logical (compositor) pixels
    logical_w: u32 = 0,
    logical_h: u32 = 0,
    /// openOutputs(): the output's logical rectangle; zero otherwise
    x: i32 = 0,
    y: i32 = 0,
    out_w: u32 = 0,
    out_h: u32 = 0,
    /// registry name of the output this surface is fullscreen on; 0 when
    /// the compositor picks
    output: u32 = 0,
    frame_pending: bool = false,
    configured: bool = false,
    alive: bool = false,
    maximized: bool = false,
    /// argb8888 buffers with premultiplied alpha (OpenOptions.transparent)
    transparent: bool = false,

    // --- protocol objects and state ---
    wl_surface: u32 = 0,
    xdg_surf: u32 = 0,
    toplevel: u32 = 0,
    /// zwlr_layer_surface_v1, used instead of xdg_surf/toplevel
    layer_surf: u32 = 0,
    /// surface size minus its window geometry (a drawn shadow): xdg
    /// configure sizes are the geometry's
    geom_extra_w: u32 = 0,
    geom_extra_h: u32 = 0,
    viewport: u32 = 0,
    fs_obj: u32 = 0, // wp_fractional_scale_v1
    frame_cb: u32 = 0,
    /// integer buffer scale used when fractional scaling is unavailable
    int_scale: i32 = 1,
    /// buffer scale last sent with set_buffer_scale
    committed_scale: i32 = 1,
    /// wl_surface.preferred_buffer_scale (v6); 0 = not received
    preferred_int: i32 = 0,
    /// output slots the surface is on (wl_surface.enter/leave)
    entered: u32 = 0,
    pending_w: u32 = 0, // from xdg_toplevel.configure (surface coords)
    pending_h: u32 = 0,
    bounds_w: u32 = 0, // from xdg_toplevel.configure_bounds (logical)
    bounds_h: u32 = 0,

    pool: u32 = 0,
    pool_fd: sys.fd_t = -1,
    pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [2]Buffer = .{ .{}, .{} },
    cur_buf: usize = 0,
    /// buffer index of the last present, for SHOTLET_DUMP_FRAME
    last_presented: ?usize = null,
};

/// Buffer size for a logical size. With fractional scaling the buffer is
/// logical * scale120 / 120 (rounded) and a viewport maps it back; without
/// it the buffer is logical * integer scale and set_buffer_scale is used.
pub fn bufferSize(logical_w: u32, logical_h: u32, scale120: u32, fractional: bool, int_scale: i32) [2]u32 {
    if (fractional) {
        return .{ (logical_w * scale120 + 60) / 120, (logical_h * scale120 + 60) / 120 };
    }
    const k: u32 = @intCast(@max(1, int_scale));
    return .{ logical_w * k, logical_h * k };
}

/// A surface that exactly covers one output gets a buffer of the output's
/// physical pixels. fractional-scale-v1 rounds the scale to 1/120 steps, so
/// logical * scale120 / 120 can miss the panel by a few pixels (1712 x 179/120
/// = 2554 on a 2560-pixel panel at 1.4953) and the compositor would then
/// resample the whole UI. Null when the surface does not match the output's
/// logical size or the mode is not plausibly that output at about `approx`.
pub fn outputBufferSize(logical_w: u32, logical_h: u32, approx: [2]u32, out_w: i32, out_h: i32, mode_w: i32, mode_h: i32) ?[2]u32 {
    if (out_w != @as(i64, logical_w) or out_h != @as(i64, logical_h) or mode_w <= 0 or mode_h <= 0) return null;
    // the mode is in the panel's native orientation; rotated outputs swap it
    var mw: u32 = @intCast(mode_w);
    var mh: u32 = @intCast(mode_h);
    if ((mw > mh) != (logical_w > logical_h) and mw != mh) std.mem.swap(u32, &mw, &mh);
    const close = struct {
        fn f(a: u32, b: u32) bool {
            const d = if (a > b) a - b else b - a;
            return d <= b / 100 + 2;
        }
    }.f;
    if (!close(mw, approx[0]) or !close(mh, approx[1])) return null;
    return .{ mw, mh };
}

/// Integer buffer scale: the compositor's preferred_buffer_scale when it
/// sent one, else the largest scale among the outputs the surface is on,
/// else the assigned output's, else 1.
pub fn pickIntScale(preferred: i32, entered_scales: []const i32, assigned: i32) i32 {
    if (preferred > 0) return preferred;
    var best: i32 = 0;
    for (entered_scales) |sc| best = @max(best, sc);
    if (best > 0) return best;
    return @max(1, assigned);
}

/// Bytes of `s` that fit in `max` without splitting a UTF-8 sequence
/// (at least one whole character when s is non-empty, unless malformed).
pub fn utf8Chunk(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    // back up over continuation bytes to a character boundary
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    if (n == 0) {
        // a single character longer than max cannot happen for max >= 4;
        // skip the malformed run instead of looping forever
        n = max;
    }
    return n;
}

const ClipboardImage = struct {
    alloc: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    png_data: []u8 = &.{},
    encode_failed: bool = false,
    thread: ?std.Thread = null,

    fn create(alloc: std.mem.Allocator, pixels: []u32, width: u32, height: u32) !*ClipboardImage {
        const self = try alloc.create(ClipboardImage);
        self.* = .{ .alloc = alloc, .pixels = pixels, .width = width, .height = height };
        errdefer alloc.destroy(self);
        self.thread = try std.Thread.spawn(.{}, encodeWorker, .{self});
        return self;
    }

    fn deinit(self: *ClipboardImage) void {
        if (self.thread) |thread| thread.join();
        self.alloc.free(self.png_data);
        self.alloc.free(self.pixels);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn waitPng(self: *ClipboardImage) ![]const u8 {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.encode_failed) return error.ClipboardEncodeFailed;
        return self.png_data;
    }

    fn encodeWorker(self: *ClipboardImage) void {
        self.png_data = png.encode(self.alloc, self.pixels, self.width, self.height) catch {
            self.encode_failed = true;
            return;
        };
    }
};

/// A wl_data_offer and which plain-text types it carries (best first).
const Offer = struct {
    id: u32 = 0,
    /// bit 0: text/plain;charset=utf-8, 1: UTF8_STRING, 2: text/plain
    text: u3 = 0,
    /// bit i: accept_mimes[i] is offered
    accept: u8 = 0,
};

/// What a drop onto one of our surfaces delivered (Window.accept_mimes).
pub const Dropped = struct {
    mime: []const u8,
    data: []u8,
};

const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

/// Read `fd` until EOF, `max_bytes` or the deadline, whichever comes
/// first; a cut never splits a UTF-8 sequence. Caller owns the bytes.
pub fn readBounded(alloc: std.mem.Allocator, fd: sys.fd_t, max_bytes: usize, deadline_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (out.items.len < max_bytes) {
        if (!try sys.waitReadable(fd, deadline_ms)) break; // timed out
        const n = try sys.read(fd, buf[0..@min(buf.len, max_bytes - out.items.len)]);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    if (out.items.len == max_bytes) {
        // drop a trailing partial character
        var i = out.items.len;
        while (i > 0 and (out.items[i - 1] & 0xC0) == 0x80) i -= 1;
        if (i > 0 and out.items[i - 1] >= 0xC0) {
            const need = std.unicode.utf8ByteSequenceLength(out.items[i - 1]) catch 1;
            if (out.items.len - (i - 1) < need) out.shrinkRetainingCapacity(i - 1);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "bounded reads stop at EOF, the size limit and the deadline" {
    const alloc = std.testing.allocator;
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    try sys.writeAll(fds[1], "ab\xc3\xb1cd"); // "abñcd"
    // limit cuts inside "ñ": the partial character is dropped
    const cut = try readBounded(alloc, fds[0], 3, sys.monoMs() + 1000);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("ab", cut);
    // nothing more arrives and the writer stays open: the deadline ends it
    const rest = try readBounded(alloc, fds[0], 100, sys.monoMs() + 50);
    defer alloc.free(rest);
    try std.testing.expectEqualStrings("\xb1cd", rest);
    sys.close(fds[1]);
    const eof = try readBounded(alloc, fds[0], 100, sys.monoMs() + 1000);
    defer alloc.free(eof);
    try std.testing.expectEqual(@as(usize, 0), eof.len);
}

pub const Cursor = enum { crosshair, arrow, move, text, resize_nwse, resize_nesw, resize_ns, resize_ew };

/// A wlr-layer-shell placement (see OpenOptions.layer).
pub const Layer = struct {
    layer: u32 = wl.zwlr_layer_shell_v1.layer_overlay,
    /// zwlr_layer_surface_v1.anchor_* bits
    anchor: u32 = 0,
    /// logical size; 0 along an axis anchored on both edges stretches
    width: u32 = 0,
    height: u32 = 0,
    /// top, right, bottom, left (logical pixels)
    margin: [4]i32 = .{ 0, 0, 0, 0 },
    keyboard: u32 = wl.zwlr_layer_surface_v1.keyboard_on_demand,
    namespace: []const u8 = "shotlet",
};

/// Progress of a drag started with startDrag().
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

/// MIME types a dragged image offers, best first.
pub const drag_mimes = [_][]const u8{ "image/png", "text/uri-list" };

/// Which payload answers a request for `mime` (null: not offered).
pub fn dragPayloadFor(mime: []const u8) ?enum { png, uri_list } {
    if (std.mem.eql(u8, mime, "image/png")) return .png;
    if (std.mem.eql(u8, mime, "text/uri-list")) return .uri_list;
    return null;
}

/// text/uri-list body for a local file: file:// URI with every byte
/// outside RFC 3986's unreserved set and '/' percent-encoded, CRLF ended.
pub fn fileUriList(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        if (plain) try out.append(alloc, c) else try out.print(alloc, "%{X:0>2}", .{c});
    }
    try out.appendSlice(alloc, "\r\n");
    return out.toOwnedSlice(alloc);
}

test "drag MIME types map to their payloads" {
    const t = std.testing;
    try t.expectEqual(.png, dragPayloadFor("image/png").?);
    try t.expectEqual(.uri_list, dragPayloadFor("text/uri-list").?);
    try t.expect(dragPayloadFor("text/plain") == null);
    try t.expect(dragPayloadFor("image/png;x") == null);
    try t.expect(dragPayloadFor("") == null);
    for (drag_mimes) |m| try t.expect(dragPayloadFor(m) != null);
    const u = try fileUriList(t.allocator, "/home/a b/Imágenes/shot#1.png");
    defer t.allocator.free(u);
    try t.expectEqualStrings("file:///home/a%20b/Im%C3%A1genes/shot%231.png\r\n", u);
}

pub const Window = struct {
    alloc: std.mem.Allocator,
    conn: wl.Connection,

    // globals
    registry: u32 = 0,
    compositor: u32 = 0,
    compositor_version: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    seat_version: u32 = 0,
    /// wl_seat capabilities last announced (pointer/keyboard bits)
    seat_caps: u32 = 0,
    ddm: u32 = 0, // wl_data_device_manager
    viewporter: u32 = 0,
    fs_manager: u32 = 0, // wp_fractional_scale_manager_v1
    xdg_output_manager: u32 = 0,
    ti_manager: u32 = 0, // zwp_text_input_manager_v3
    rel_manager: u32 = 0, // zwp_relative_pointer_manager_v1
    rel_pointer: u32 = 0, // zwp_relative_pointer_v1
    ddm_version: u32 = 0,
    layer_shell: u32 = 0, // zwlr_layer_shell_v1
    layer_shell_version: u32 = 0,

    outputs: [max_outputs]Output = @splat(.{}),

    // surfaces; index 0 is the classic single window
    surfaces: [max_surfaces]Surface = @splat(.{}),
    n_surfaces: u8 = 0,

    // seat objects
    pointer: u32 = 0,
    keyboard: u32 = 0,
    data_device: u32 = 0,
    /// data offers the compositor announced (selection or drag), with the
    /// text types each one has; the selection is the clipboard's
    offers: [4]Offer = @splat(.{}),
    selection_offer: u32 = 0,
    clipboard_source: u32 = 0,
    clipboard_png: []u8 = &.{},
    /// text we offer on the clipboard (text/plain;charset=utf-8, UTF8_STRING)
    clipboard_text: []u8 = &.{},
    clipboard_image: ?*ClipboardImage = null,

    // drag and drop out (startDrag)
    drag_source: u32 = 0,
    drag_state: DragState = .none,
    /// a drop target accepted one of the types (wl_data_source.target)
    drag_accepted: bool = false,
    drag_png: []u8 = &.{},
    drag_uri: []u8 = &.{},
    drag_icon: u32 = 0,
    drag_icon_buf: u32 = 0,
    drag_icon_mem: []align(std.heap.page_size_min) u8 = &.{},

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
    rel_sum: [2]f64 = .{ 0, 0 },

    // drops onto our surfaces: types taken, best first (empty: none);
    // a completed drop lands in `dropped` (caller frees .data)
    accept_mimes: []const []const u8 = &.{},
    dnd_offer: u32 = 0,
    dropped: ?Dropped = null,

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

    // input state
    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    /// surface index under the pointer / with keyboard focus
    ptr_surface: u8 = 0,
    /// vertical scroll gathered until the pointer frame
    axis_value: f64 = 0,
    axis_v120: ?i32 = null,
    axis_pending: bool = false,
    key_surface: u8 = 0,
    ctrl: bool = false,
    shift: bool = false,
    /// layout translation (libxkbcommon when available) and key repeat
    kb: keyboard.Keyboard = .{},
    enter_serial: u32 = 0,
    input_serial: u32 = 0, // last button/key serial, for set_selection

    // text-input-v3
    text_input: u32 = 0,
    ti_focus: bool = false,
    ti_surface: u8 = 0,
    ti_want: bool = false,
    ti_enabled: bool = false,
    ti_rect: ?Rect = null,
    ti_pending_commit: [512]u8 = undefined,
    ti_pending_commit_len: usize = 0,
    ti_pending_preedit: [256]u8 = undefined,
    ti_pending_preedit_len: usize = 0,
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,

    // cursor surfaces
    cursor_surface: u32 = 0,
    cursor_pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    cursor_buffers: [8]u32 = @splat(0),
    current_cursor: Cursor = .crosshair,

    // queued logical events (one wayland message may produce several)
    queue: std.ArrayList(InputEvent) = .empty,

    pub fn init(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8) !Window {
        var self = Window{
            .alloc = alloc,
            .conn = try wl.Connection.connect(alloc, runtime_dir, display),
        };
        errdefer self.conn.deinit();
        self.kb = keyboard.Keyboard.init();
        errdefer self.kb.deinit();

        self.registry = try self.conn.getRegistry();
        const done = try self.conn.sync();
        // collect globals until sync callback fires
        var synced = false;
        while (!synced) {
            const ev = try self.conn.readEvent();
            if (ev.object == done and ev.opcode == wl.wl_callback.ev_done) {
                synced = true;
            } else {
                try self.handleEvent(ev);
            }
        }
        if (self.compositor == 0 or self.shm == 0 or self.wm_base == 0)
            return error.MissingGlobals;
        // outputs announce their geometry after binding: one more roundtrip
        // so openOutputs() knows them up front
        var any_output = false;
        for (&self.outputs) |*o| if (o.id != 0) {
            any_output = true;
            try self.ensureXdgOutput(o);
        };
        if (any_output) try self.roundtrip();
        return self;
    }

    fn roundtrip(self: *Window) !void {
        const cb = try self.conn.sync();
        while (true) {
            const ev = try self.conn.readEvent();
            if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) return;
            try self.handleEvent(ev);
        }
    }

    fn handleGlobal(self: *Window, name: u32, iface: []const u8, version: u32) !void {
        const eql = std.mem.eql;
        if (eql(u8, iface, "wl_compositor")) {
            // v6 for wl_surface.preferred_buffer_scale
            self.compositor_version = @min(version, 6);
            self.compositor = try self.conn.bind(self.registry, name, iface, self.compositor_version);
        } else if (eql(u8, iface, "wl_shm")) {
            self.shm = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wl_seat") and self.seat == 0) {
            // v8 adds axis_value120 (exact wheel notches); keymaps are
            // already mapped MAP_PRIVATE as v7 requires
            self.seat_version = @min(version, 8);
            self.seat = try self.conn.bind(self.registry, name, iface, self.seat_version);
        } else if (eql(u8, iface, "wl_data_device_manager")) {
            // v3: drag-and-drop actions (copy) for startDrag
            self.ddm_version = @min(version, 3);
            self.ddm = try self.conn.bind(self.registry, name, iface, self.ddm_version);
        } else if (eql(u8, iface, "zwlr_layer_shell_v1")) {
            if (std.c.getenv("SHOTLET_NO_LAYER_SHELL") == null) {
                self.layer_shell_version = @min(version, 4);
                self.layer_shell = try self.conn.bind(self.registry, name, iface, self.layer_shell_version);
            }
        } else if (eql(u8, iface, "wp_viewporter")) {
            self.viewporter = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            if (std.c.getenv("SHOTLET_NO_FRACTIONAL") == null)
                self.fs_manager = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "zxdg_output_manager_v1")) {
            self.xdg_output_manager = try self.conn.bind(self.registry, name, iface, @min(version, 3));
            for (&self.outputs) |*o| if (o.id != 0) try self.ensureXdgOutput(o);
        } else if (eql(u8, iface, "zwp_relative_pointer_manager_v1")) {
            self.rel_manager = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "zwp_text_input_manager_v3")) {
            self.ti_manager = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wl_output")) {
            for (&self.outputs) |*o| {
                if (o.id != 0) continue;
                const v = @min(version, 4);
                o.* = .{ .global = name, .version = v };
                o.id = try self.conn.bind(self.registry, name, iface, v);
                try self.ensureXdgOutput(o);
                break;
            } else std.log.warn("more than {d} outputs; ignoring one", .{max_outputs});
        }
    }

    fn ensureXdgOutput(self: *Window, o: *Output) !void {
        if (self.xdg_output_manager == 0 or o.id == 0 or o.xdg != 0) return;
        o.xdg = self.conn.newId();
        try self.conn.request(self.xdg_output_manager, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
    }

    fn handleGlobalRemove(self: *Window, name: u32) !void {
        for (&self.outputs, 0..) |*o, slot| {
            if (o.id == 0 or o.global != name) continue;
            // tear down surfaces fullscreened on it (never surface 0: the
            // compositor moves that one, and the classic API relies on it)
            for (self.surfaces[0..self.n_surfaces], 0..) |*s, i| {
                s.entered &= ~(@as(u32, 1) << @intCast(slot));
                if (i != 0 and s.alive and s.output == name) {
                    self.destroySurface(@intCast(i));
                    try self.queue.append(self.alloc, .{ .resize = .{ .w = 0, .h = 0, .surface = @intCast(i) } });
                }
            }
            const c = &self.conn;
            if (o.xdg != 0) c.request(o.xdg, wl.zxdg_output_v1.destroy, &.{}) catch {};
            if (o.version >= 3) c.request(o.id, wl.wl_output.release, &.{}) catch {};
            o.* = .{};
            for (0..self.n_surfaces) |i| try self.updateIntScale(@intCast(i));
            try c.flush();
            return;
        }
    }

    pub fn deinit(self: *Window) void {
        self.dumpFrames();
        self.dropClipboardSource();
        self.endDrag();
        for (&self.surfaces) |*s| destroyPool(&self.conn, s);
        if (self.cursor_pool_mem.len > 0) sys.munmap(self.cursor_pool_mem);
        self.queue.deinit(self.alloc);
        self.kb.deinit();
        self.conn.deinit();
    }

    pub const OpenOptions = struct {
        fullscreen: bool = true,
        /// ask to be maximized (the work area: panels stay visible)
        maximized: bool = false,
        /// fallback size when the compositor lets the client decide
        width: u32 = 800,
        height: u32 = 500,
        /// premultiplied ARGB buffers: see-through where alpha < 255
        transparent: bool = false,
        /// a wlr-layer-shell surface when the compositor offers one;
        /// ignored otherwise (an xdg toplevel as the rest describes)
        layer: ?Layer = null,
    };

    /// Relative pointer motion since the last call (logical pixels); null
    /// when the compositor has no zwp_relative_pointer_v1 (or
    /// track_relative was not set before open()).
    pub fn takeRelative(self: *Window) ?[2]f64 {
        if (self.rel_pointer == 0) return null;
        defer self.rel_sum = .{ 0, 0 };
        return self.rel_sum;
    }

    /// The compositor offers zwlr_layer_shell_v1 (KDE, wlroots; not GNOME).
    pub fn hasLayerShell(self: *const Window) bool {
        return self.layer_shell != 0;
    }

    /// Create the toplevel; returns after the first configure, with buffers
    /// allocated (a .resize event will be queued).
    pub fn open(self: *Window, title: []const u8, opts: OpenOptions) !void {
        self.default_w = opts.width;
        self.default_h = opts.height;
        try self.createSurface(0, title, opts, 0, 0);
        self.n_surfaces = 1;
        try self.finishOpen();
    }

    /// Open one fullscreen surface per known output (up to max_surfaces),
    /// ordered left to right, top to bottom. Surface 0 is the first. Falls
    /// back to a single open() when the compositor announced no outputs.
    /// Returns after every surface got its first configure.
    pub fn openOutputs(self: *Window, title: []const u8) !void {
        var order: [max_outputs]u8 = undefined;
        var n: usize = 0;
        for (self.outputs, 0..) |o, slot| if (o.id != 0) {
            order[n] = @intCast(slot);
            n += 1;
        };
        if (n == 0) return self.open(title, .{ .fullscreen = true });
        const Ctx = struct {
            outs: []const Output,
            fn less(ctx: @This(), a: u8, b: u8) bool {
                const ra = ctx.outs[a].logicalRect();
                const rb = ctx.outs[b].logicalRect();
                return if (ra.x != rb.x) ra.x < rb.x else ra.y < rb.y;
            }
        };
        std.mem.sort(u8, order[0..n], Ctx{ .outs = &self.outputs }, Ctx.less);
        n = @min(n, max_surfaces);
        for (order[0..n], 0..) |slot, i| {
            const o = &self.outputs[slot];
            try self.createSurface(@intCast(i), title, .{ .fullscreen = true }, o.id, o.global);
            const s = &self.surfaces[i];
            s.int_scale = @max(1, o.scale);
            if (s.fs_obj == 0) s.scale120 = @intCast(s.int_scale * 120);
            setOutputRect(s, o);
        }
        self.n_surfaces = @intCast(n);
        try self.finishOpen();
    }

    /// One fullscreen surface on the output whose logical rectangle starts
    /// at x, y; open(.{ .fullscreen = true }) when there is none.
    pub fn openOnOutputAt(self: *Window, title: []const u8, x: i32, y: i32) !void {
        for (&self.outputs) |*o| {
            if (o.id == 0) continue;
            const r = o.logicalRect();
            if (r.x != x or r.y != y) continue;
            try self.createSurface(0, title, .{ .fullscreen = true }, o.id, o.global);
            const s = &self.surfaces[0];
            s.int_scale = @max(1, o.scale);
            if (s.fs_obj == 0) s.scale120 = @intCast(s.int_scale * 120);
            setOutputRect(s, o);
            self.n_surfaces = 1;
            return self.finishOpen();
        }
        return self.open(title, .{ .fullscreen = true });
    }

    fn setOutputRect(s: *Surface, o: *const Output) void {
        const r = o.logicalRect();
        s.x = r.x;
        s.y = r.y;
        s.out_w = @intCast(@max(0, r.w));
        s.out_h = @intCast(@max(0, r.h));
    }

    fn createSurface(self: *Window, idx: u8, title: []const u8, opts: OpenOptions, output_id: u32, output_global: u32) !void {
        const c = &self.conn;
        const s = &self.surfaces[idx];
        const fullscreen = opts.fullscreen;
        s.* = .{ .alive = true, .output = output_global, .transparent = opts.transparent };
        s.wl_surface = c.newId();
        try c.request(self.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = s.wl_surface }});
        if (self.viewporter != 0 and self.fs_manager != 0) {
            s.viewport = c.newId();
            try c.request(self.viewporter, wl.wp_viewporter.get_viewport, &.{ .{ .new_id = s.viewport }, .{ .object = s.wl_surface } });
            s.fs_obj = c.newId();
            try c.request(self.fs_manager, wl.wp_fractional_scale_manager_v1.get_fractional_scale, &.{ .{ .new_id = s.fs_obj }, .{ .object = s.wl_surface } });
        }
        if (opts.layer) |l| if (self.layer_shell != 0) {
            const L = wl.zwlr_layer_surface_v1;
            s.layer_surf = c.newId();
            try c.request(self.layer_shell, wl.zwlr_layer_shell_v1.get_layer_surface, &.{
                .{ .new_id = s.layer_surf }, .{ .object = s.wl_surface }, .{ .object = output_id },
                .{ .uint = l.layer },        .{ .string = l.namespace },
            });
            try c.request(s.layer_surf, L.set_size, &.{ .{ .uint = l.width }, .{ .uint = l.height } });
            try c.request(s.layer_surf, L.set_anchor, &.{.{ .uint = l.anchor }});
            try c.request(s.layer_surf, L.set_margin, &.{
                .{ .int = l.margin[0] }, .{ .int = l.margin[1] }, .{ .int = l.margin[2] }, .{ .int = l.margin[3] },
            });
            try c.request(s.layer_surf, L.set_exclusive_zone, &.{.{ .int = 0 }});
            // on-demand focus is v4; before it the only choice that does
            // not grab every key press is none
            var kb = l.keyboard;
            if (kb == L.keyboard_on_demand and self.layer_shell_version < 4) kb = L.keyboard_none;
            try c.request(s.layer_surf, L.set_keyboard_interactivity, &.{.{ .uint = kb }});
            s.pending_w = l.width;
            s.pending_h = l.height;
            try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
            return;
        };
        s.xdg_surf = c.newId();
        try c.request(self.wm_base, wl.xdg_wm_base.get_xdg_surface, &.{ .{ .new_id = s.xdg_surf }, .{ .object = s.wl_surface } });
        s.toplevel = c.newId();
        try c.request(s.xdg_surf, wl.xdg_surface.get_toplevel, &.{.{ .new_id = s.toplevel }});
        try c.request(s.toplevel, wl.xdg_toplevel.set_app_id, &.{.{ .string = "shotlet" }});
        try c.request(s.toplevel, wl.xdg_toplevel.set_title, &.{.{ .string = title }});
        if (fullscreen) {
            try c.request(s.toplevel, wl.xdg_toplevel.set_fullscreen, &.{.{ .object = output_id }});
        } else if (opts.maximized) {
            try c.request(s.toplevel, wl.xdg_toplevel.set_maximized, &.{});
        }
        try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
    }

    fn finishOpen(self: *Window) !void {
        const c = &self.conn;
        try self.updateSeatDevices();
        if (self.ddm != 0 and self.seat != 0 and self.data_device == 0) {
            self.data_device = c.newId();
            try c.request(self.ddm, wl.wl_data_device_manager.get_data_device, &.{ .{ .new_id = self.data_device }, .{ .object = self.seat } });
        }
        if (self.ti_manager != 0 and self.seat != 0 and self.text_input == 0) {
            self.text_input = c.newId();
            try c.request(self.ti_manager, wl.zwp_text_input_manager_v3.get_text_input, &.{ .{ .new_id = self.text_input }, .{ .object = self.seat } });
        }
        if (self.cursor_surface == 0) try self.initCursors();

        // wait for the initial configure of every surface
        while (true) {
            var all = true;
            for (self.surfaces[0..self.n_surfaces]) |s| {
                if (s.alive and !s.configured) all = false;
            }
            if (all) break;
            try self.dispatchOne();
        }
    }

    fn destroyPool(c: *wl.Connection, s: *Surface) void {
        for (&s.buffers) |*b| {
            if (b.id != 0) {
                c.request(b.id, wl.wl_buffer.destroy, &.{}) catch {};
                b.* = .{};
            }
        }
        if (s.pool != 0) {
            c.request(s.pool, wl.wl_shm_pool.destroy, &.{}) catch {};
            s.pool = 0;
        }
        if (s.pool_mem.len > 0) {
            sys.munmap(s.pool_mem);
            s.pool_mem = &.{};
        }
        if (s.pool_fd >= 0) {
            sys.close(s.pool_fd);
            s.pool_fd = -1;
        }
        s.last_presented = null;
    }

    /// Destroy one surface's protocol objects and buffers.
    fn destroySurface(self: *Window, idx: u8) void {
        const c = &self.conn;
        const s = &self.surfaces[idx];
        destroyPool(c, s);
        if (s.fs_obj != 0) c.request(s.fs_obj, 0, &.{}) catch {}; // wp_fractional_scale_v1.destroy
        if (s.viewport != 0) c.request(s.viewport, wl.wp_viewport.destroy, &.{}) catch {};
        if (s.toplevel != 0) c.request(s.toplevel, wl.xdg_toplevel.destroy, &.{}) catch {};
        if (s.layer_surf != 0) c.request(s.layer_surf, wl.zwlr_layer_surface_v1.destroy, &.{}) catch {};
        if (s.xdg_surf != 0) c.request(s.xdg_surf, wl.xdg_surface.destroy, &.{}) catch {};
        if (s.wl_surface != 0) c.request(s.wl_surface, wl.wl_surface.destroy, &.{}) catch {};
        s.* = .{};
        c.flush() catch {};
        if (idx == 0) self.syncPrimary();
    }

    fn createBuffers(self: *Window, idx: u8, w: u32, h: u32) !void {
        const s = &self.surfaces[idx];
        const c = &self.conn;
        destroyPool(c, s);
        const stride = w * 4;
        const buf_size: usize = @as(usize, stride) * h;
        const total = buf_size * 2;
        if (total > std.math.maxInt(i32)) return error.BufferTooLarge;

        s.pool_fd = try sys.memfdCreate("shotlet-shm", sys.MFD_CLOEXEC);
        try sys.ftruncate(s.pool_fd, total);
        s.pool_mem = try sys.mmapRw(s.pool_fd, total);

        s.pool = c.newId();
        try c.request(self.shm, wl.wl_shm.create_pool, &.{
            .{ .new_id = s.pool },
            .{ .fd = s.pool_fd },
            .{ .int = @intCast(total) },
        });
        for (&s.buffers, 0..) |*b, i| {
            b.id = c.newId();
            b.busy = false;
            b.pixels = @alignCast(s.pool_mem[i * buf_size ..][0..buf_size]);
            try c.request(s.pool, wl.wl_shm_pool.create_buffer, &.{
                .{ .new_id = b.id },
                .{ .int = @intCast(i * buf_size) },
                .{ .int = @intCast(w) },
                .{ .int = @intCast(h) },
                .{ .int = @intCast(stride) },
                .{ .uint = if (s.transparent) wl.wl_shm.format_argb8888 else wl.wl_shm.format_xrgb8888 },
            });
        }
        s.width = w;
        s.height = h;
        try c.flush(); // send while pool_fd is guaranteed open
        if (idx == 0) self.syncPrimary();
        try self.queue.append(self.alloc, .{ .resize = .{ .w = w, .h = h, .surface = idx } });
    }

    /// Recompute the physical buffer size from logical size and scale,
    /// recreate buffers if needed, and pin the viewport destination.
    fn applySize(self: *Window, idx: u8) !void {
        const s = &self.surfaces[idx];
        if (s.logical_w == 0 or s.logical_h == 0) return;
        const fractional = s.fs_obj != 0;
        if (!fractional) s.scale120 = @intCast(s.int_scale * 120);
        var size = bufferSize(s.logical_w, s.logical_h, s.scale120, fractional, s.int_scale);
        if (fractional) {
            if (self.coveredOutput(s)) |o| {
                if (outputBufferSize(s.logical_w, s.logical_h, size, o.logicalRect().w, o.logicalRect().h, o.mode_w, o.mode_h)) |px| size = px;
            }
        }
        if (size[0] == 0 or size[1] == 0) return;
        if (size[0] != s.width or size[1] != s.height or s.pool == 0) {
            try self.createBuffers(idx, size[0], size[1]);
        }
        if (s.viewport != 0) {
            try self.conn.request(s.viewport, wl.wp_viewport.set_destination, &.{
                .{ .int = @intCast(s.logical_w) },
                .{ .int = @intCast(s.logical_h) },
            });
        }
        if (idx == 0) self.syncPrimary();
    }

    /// The output a surface is fullscreen on: its assigned one, else the
    /// only output it entered.
    fn coveredOutput(self: *const Window, s: *const Surface) ?*const Output {
        var found: ?*const Output = null;
        for (&self.outputs, 0..) |*o, slot| {
            if (o.id == 0) continue;
            if (s.output != 0) {
                if (o.global == s.output) return o;
            } else if (s.entered & (@as(u32, 1) << @intCast(slot)) != 0) {
                if (found != null) return null;
                found = o;
            }
        }
        return found;
    }

    /// Integer-scale path (no wp_fractional_scale): follow the compositor's
    /// preferred_buffer_scale or the outputs the surface is on.
    fn updateIntScale(self: *Window, idx: u8) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.fs_obj != 0) return;
        var scales: [max_outputs]i32 = undefined;
        var n: usize = 0;
        var assigned: i32 = 1;
        for (self.outputs, 0..) |o, slot| {
            if (o.id == 0) continue;
            if (s.entered & (@as(u32, 1) << @intCast(slot)) != 0) {
                scales[n] = o.scale;
                n += 1;
            }
            if (o.global == s.output and s.output != 0) assigned = o.scale;
        }
        const k = pickIntScale(s.preferred_int, scales[0..n], assigned);
        if (k == s.int_scale) return;
        s.int_scale = k;
        s.scale120 = @intCast(k * 120);
        if (s.configured) {
            try self.applySize(idx);
            try self.conn.flush();
        }
        if (idx == 0) self.syncPrimary();
    }

    fn syncPrimary(self: *Window) void {
        const s = &self.surfaces[0];
        self.width = s.width;
        self.height = s.height;
        self.scale120 = s.scale120;
        self.scale = @max(1, (s.scale120 + 60) / 120);
        self.maximized = s.maximized;
        self.configured = s.configured;
        self.frame_pending = s.frame_pending;
    }

    /// The surfaces opened by open()/openOutputs(); check `alive`.
    pub fn surfaceList(self: *Window) []Surface {
        return self.surfaces[0..self.n_surfaces];
    }

    /// Outputs currently known (empty slots filtered out by the caller via
    /// `id != 0`).
    pub fn outputList(self: *Window) []const Output {
        return &self.outputs;
    }

    /// Returns a drawable back buffer as u32 pixels (0xAARRGGBB) for
    /// surface 0. Blocks until a buffer is free if both are busy.
    pub fn backBuffer(self: *Window) ![]u32 {
        return self.backBufferOf(0);
    }

    /// Back buffer of surface idx (s.width x s.height pixels).
    pub fn backBufferOf(self: *Window, idx: u8) ![]u32 {
        if (idx >= self.n_surfaces or !self.surfaces[idx].alive) return error.NoSuchSurface;
        var tries: usize = 0;
        while (true) {
            const s = &self.surfaces[idx];
            if (!s.alive) return error.NoSuchSurface;
            if (s.pool == 0) return error.NotConfigured;
            if (!s.buffers[s.cur_buf].busy) break;
            if (!s.buffers[1 - s.cur_buf].busy) {
                s.cur_buf = 1 - s.cur_buf;
                break;
            }
            try self.dispatchOne();
            tries += 1;
            if (tries > 1000) return error.BuffersStuck;
        }
        const s = &self.surfaces[idx];
        const b = &s.buffers[s.cur_buf];
        return @as([*]u32, @ptrCast(b.pixels.ptr))[0 .. b.pixels.len / 4];
    }

    /// Attach + commit surface 0's current back buffer.
    pub fn present(self: *Window) !void {
        return self.presentSurface(0);
    }

    /// Attach + commit the current back buffer of surface idx.
    pub fn presentSurface(self: *Window, idx: u8) !void {
        return self.presentDamaged(idx, null);
    }

    /// Like presentSurface, telling the compositor only `damage` (buffer
    /// pixels) changed; null means the whole buffer. The caller must have
    /// drawn everything else of this back buffer before (both buffers
    /// alternate).
    pub fn presentDamaged(self: *Window, idx: u8, damage: ?Rect) !void {
        if (idx >= self.n_surfaces) return error.NoSuchSurface;
        const s = &self.surfaces[idx];
        if (!s.alive or s.pool == 0) return error.NoSuchSurface;
        const c = &self.conn;
        const b = &s.buffers[s.cur_buf];
        if (s.fs_obj == 0 and s.committed_scale != s.int_scale and self.compositor_version >= 3) {
            try c.request(s.wl_surface, wl.wl_surface.set_buffer_scale, &.{.{ .int = s.int_scale }});
            s.committed_scale = s.int_scale;
        }
        try c.request(s.wl_surface, wl.wl_surface.attach, &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        const d = damage orelse Rect{ .x = 0, .y = 0, .w = @intCast(s.width), .h = @intCast(s.height) };
        try c.request(s.wl_surface, wl.wl_surface.damage_buffer, &.{
            .{ .int = d.x }, .{ .int = d.y }, .{ .int = d.w }, .{ .int = d.h },
        });
        if (!s.frame_pending) {
            s.frame_cb = c.newId();
            try c.request(s.wl_surface, wl.wl_surface.frame, &.{.{ .new_id = s.frame_cb }});
            s.frame_pending = true;
        }
        try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
        try c.flush();
        b.busy = true;
        s.last_presented = s.cur_buf;
        s.cur_buf = 1 - s.cur_buf;
        if (idx == 0) self.syncPrimary();
    }

    /// Debug aid: with SHOTLET_DUMP_FRAME=/path/prefix set, write the last
    /// presented frame of each surface to <prefix>-<index>.png. Runs once,
    /// when the window closes, so headless runs can be inspected.
    fn dumpFrames(self: *Window) void {
        const prefix = std.mem.span(std.c.getenv("SHOTLET_DUMP_FRAME") orelse return);
        if (prefix.len == 0) return;
        for (self.surfaces[0..self.n_surfaces], 0..) |*s, i| {
            const idx = s.last_presented orelse continue;
            const b = &s.buffers[idx];
            if (b.pixels.len == 0) continue;
            const px = @as([*]const u32, @ptrCast(b.pixels.ptr))[0 .. b.pixels.len / 4];
            writeDump(self.alloc, prefix, i, px, s.width, s.height);
            s.last_presented = null;
        }
    }

    fn writeDump(alloc: std.mem.Allocator, prefix: []const u8, index: usize, px: []const u32, w: u32, h: u32) void {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}-{d}.png", .{ prefix, index }) catch return;
        const data = png.encode(alloc, px, w, h) catch |err| {
            std.log.warn("frame dump: encode failed: {t}", .{err});
            return;
        };
        defer alloc.free(data);
        sys.writeFile(path, data) catch |err| {
            std.log.warn("frame dump: cannot write {s}: {t}", .{ path, err });
            return;
        };
        std.log.info("frame dump: wrote {s} ({d}x{d})", .{ path, w, h });
    }

    /// Blocking: next logical input event (including synthesized key
    /// repeats, which wake the wait when due).
    pub fn nextEvent(self: *Window) !InputEvent {
        while (self.queue.items.len == 0) {
            _ = try self.waitAndDispatch(-1);
        }
        return self.queue.orderedRemove(0);
    }

    /// Like nextEvent but returns null after timeout_ms with no events.
    pub fn nextEventTimeout(self: *Window, timeout_ms: i32) !?InputEvent {
        const deadline = keyboard.monotonicMs() + @max(0, timeout_ms);
        while (self.queue.items.len == 0) {
            const left = @max(0, deadline - keyboard.monotonicMs());
            const progressed = try self.waitAndDispatch(@intCast(left));
            if (!progressed and keyboard.monotonicMs() >= deadline) return null;
        }
        return self.queue.orderedRemove(0);
    }

    /// One wait step: queue a due key repeat, dispatch buffered events, or
    /// poll the socket for at most max_ms (-1 = forever), waking early for
    /// the next key repeat. Returns false when it timed out idle.
    fn waitAndDispatch(self: *Window, max_ms: i32) !bool {
        try self.pumpRepeat();
        if (self.queue.items.len > 0) return true;
        try self.conn.flush();
        if (try self.conn.pollEvent()) |ev| {
            try self.handleEvent(ev);
            return true;
        }
        var fds = [_]sys.pollfd{.{ .fd = self.conn.fd, .events = sys.POLL.IN, .revents = 0 }};
        const n = try sys.poll(&fds, self.pollTimeoutMs(max_ms));
        if (n > 0) {
            try self.dispatchOne();
            return true;
        }
        try self.pumpRepeat();
        return self.queue.items.len > 0;
    }

    /// How long a caller that polls conn.fd itself may sleep: max_ms
    /// (-1 = forever) shortened to the next pending key repeat. Such loops
    /// should call drainPending() after waking so repeats get queued.
    pub fn pollTimeoutMs(self: *const Window, max_ms: i32) i32 {
        const rep = self.kb.repeat.timeoutMs(keyboard.monotonicMs()) orelse return max_ms;
        const r: i32 = @intCast(@min(rep, std.math.maxInt(i32)));
        return if (max_ms < 0) r else @min(max_ms, r);
    }

    /// Queue a synthesized key press if the held key is due to repeat.
    fn pumpRepeat(self: *Window) !void {
        const code = self.kb.repeat.due(keyboard.monotonicMs()) orelse return;
        var key = self.translateKey(code, true, false);
        key.repeat = true;
        try self.queue.append(self.alloc, .{ .key = key });
    }

    /// Read and dispatch all events already buffered in the Wayland socket
    /// without blocking, plus any due key repeat. Call before rendering to
    /// get the latest input state.
    pub fn drainPending(self: *Window) !void {
        while (try self.conn.pollEvent()) |ev| {
            try self.handleEvent(ev);
        }
        try self.pumpRepeat();
    }

    fn dispatchOne(self: *Window) !void {
        const ev = try self.conn.readEvent();
        try self.handleEvent(ev);
    }

    const SurfaceObj = enum { wl_surface, xdg_surf, toplevel, layer_surf, fs_obj, frame_cb, buffer0, buffer1 };

    fn findSurfaceObj(self: *Window, obj: u32) ?struct { idx: u8, kind: SurfaceObj } {
        if (obj == 0) return null;
        for (self.surfaces[0..self.n_surfaces], 0..) |*s, i| {
            if (!s.alive) continue;
            const kind: SurfaceObj = if (obj == s.wl_surface) .wl_surface else if (obj == s.xdg_surf) .xdg_surf else if (obj == s.toplevel) .toplevel else if (obj == s.layer_surf) .layer_surf else if (obj == s.fs_obj) .fs_obj else if (obj == s.frame_cb) .frame_cb else if (obj == s.buffers[0].id) .buffer0 else if (obj == s.buffers[1].id) .buffer1 else continue;
            return .{ .idx = @intCast(i), .kind = kind };
        }
        return null;
    }

    fn surfaceIndexOf(self: *Window, wl_surface: u32) ?u8 {
        const f = self.findSurfaceObj(wl_surface) orelse return null;
        return if (f.kind == .wl_surface) f.idx else null;
    }

    fn outputSlotOf(self: *Window, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.outputs, 0..) |o, slot| if (o.id == obj) return slot;
        return null;
    }

    fn xdgOutputSlotOf(self: *Window, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.outputs, 0..) |o, slot| if (o.xdg == obj) return slot;
        return null;
    }

    fn handleEvent(self: *Window, ev: wl.Event) !void {
        const c = &self.conn;
        var r = wl.ArgReader{ .data = ev.body };

        if (ev.object == wl.wl_display.id) {
            switch (ev.opcode) {
                wl.wl_display.ev_error => {
                    const obj = try r.uint();
                    const code = try r.uint();
                    const msg = try r.string();
                    std.log.err("wayland protocol error on object {d} code {d}: {s}", .{ obj, code, msg });
                    return error.ProtocolError;
                },
                else => {}, // delete_id: ids are not recycled
            }
        } else if (ev.object == self.registry) {
            switch (ev.opcode) {
                wl.wl_registry.ev_global => {
                    const name = try r.uint();
                    const iface = try r.string();
                    const version = try r.uint();
                    try self.handleGlobal(name, iface, version);
                },
                wl.wl_registry.ev_global_remove => try self.handleGlobalRemove(try r.uint()),
                else => {},
            }
        } else if (ev.object == self.wm_base and ev.opcode == wl.xdg_wm_base.ev_ping) {
            const serial = try r.uint();
            try c.request(self.wm_base, wl.xdg_wm_base.pong, &.{.{ .uint = serial }});
            try c.flush();
        } else if (self.findSurfaceObj(ev.object)) |f| {
            try self.handleSurfaceEvent(f.idx, f.kind, ev.opcode, &r);
        } else if (self.outputSlotOf(ev.object)) |slot| {
            try self.handleOutput(slot, ev.opcode, &r);
        } else if (self.xdgOutputSlotOf(ev.object)) |slot| {
            try self.handleXdgOutput(slot, ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.data_device) {
            try self.handleDataDevice(ev.opcode, &r);
        } else if (self.offerSlot(ev.object)) |slot| {
            if (ev.opcode == wl.wl_data_offer.ev_offer) {
                const mime = try r.string();
                for (text_mimes, 0..) |m, i| {
                    if (std.mem.eql(u8, mime, m)) self.offers[slot].text |= @as(u3, 1) << @intCast(i);
                }
                for (self.accept_mimes[0..@min(8, self.accept_mimes.len)], 0..) |m, i| {
                    if (std.mem.eql(u8, mime, m)) self.offers[slot].accept |= @as(u8, 1) << @intCast(i);
                }
            }
        } else if (ev.object != 0 and ev.object == self.clipboard_source) {
            try self.handleClipboardSource(ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.drag_source) {
            try self.handleDragSource(ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.seat and ev.opcode == wl.wl_seat.ev_capabilities) {
            self.seat_caps = try r.uint();
            try self.updateSeatDevices();
            try c.flush();
        } else if (ev.object != 0 and ev.object == self.pointer) {
            try self.handlePointer(ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.rel_pointer and ev.opcode == 0) {
            // relative_motion: utime_hi, utime_lo, dx, dy (accelerated:
            // what the cursor moved), dx, dy unaccelerated
            _ = try r.uint();
            _ = try r.uint();
            self.rel_sum[0] += try r.fixed();
            self.rel_sum[1] += try r.fixed();
        } else if (ev.object != 0 and ev.object == self.keyboard) {
            try self.handleKeyboard(ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.text_input) {
            try self.handleTextInput(ev.opcode, &r);
        }
        // unknown objects/opcodes are skipped (header carries the size)
    }

    fn handleSurfaceEvent(self: *Window, idx: u8, kind: SurfaceObj, opcode: u16, r: *wl.ArgReader) !void {
        const c = &self.conn;
        const s = &self.surfaces[idx];
        switch (kind) {
            .toplevel => switch (opcode) {
                wl.xdg_toplevel.ev_configure => {
                    const w_ = try r.int();
                    const h_ = try r.int();
                    s.pending_w = @intCast(@max(0, w_));
                    s.pending_h = @intCast(@max(0, h_));
                    s.maximized = false;
                    const states = try r.array();
                    var si: usize = 0;
                    while (si + 4 <= states.len) : (si += 4) {
                        const st = std.mem.readInt(u32, states[si..][0..4], .little);
                        if (st == wl.xdg_toplevel.state_maximized) s.maximized = true;
                    }
                },
                wl.xdg_toplevel.ev_close => try self.queue.append(self.alloc, .close),
                wl.xdg_toplevel.ev_configure_bounds => {
                    s.bounds_w = @intCast(@max(0, try r.int()));
                    s.bounds_h = @intCast(@max(0, try r.int()));
                },
                else => {},
            },
            .layer_surf => switch (opcode) {
                wl.zwlr_layer_surface_v1.ev_configure => {
                    const serial = try r.uint();
                    const w_ = try r.uint();
                    const h_ = try r.uint();
                    try c.request(s.layer_surf, wl.zwlr_layer_surface_v1.ack_configure, &.{.{ .uint = serial }});
                    if (w_ > 0) s.pending_w = w_;
                    if (h_ > 0) s.pending_h = h_;
                    s.logical_w = if (s.pending_w > 0) s.pending_w else self.default_w;
                    s.logical_h = if (s.pending_h > 0) s.pending_h else self.default_h;
                    try self.applySize(idx);
                    s.configured = true;
                    try c.flush();
                },
                wl.zwlr_layer_surface_v1.ev_closed => try self.queue.append(self.alloc, .close),
                else => {},
            },
            .xdg_surf => if (opcode == wl.xdg_surface.ev_configure) {
                const serial = try r.uint();
                try c.request(s.xdg_surf, wl.xdg_surface.ack_configure, &.{.{ .uint = serial }});
                var want_w = if (s.pending_w > 0) s.pending_w + s.geom_extra_w else if (s.logical_w > 0) s.logical_w else if (s.out_w > 0) s.out_w else self.default_w;
                var want_h = if (s.pending_h > 0) s.pending_h + s.geom_extra_h else if (s.logical_h > 0) s.logical_h else if (s.out_h > 0) s.out_h else self.default_h;
                // respect compositor bounds for client-decided sizes
                if (s.pending_w == 0 and s.bounds_w > 0) want_w = @min(want_w, s.bounds_w);
                if (s.pending_h == 0 and s.bounds_h > 0) want_h = @min(want_h, s.bounds_h - @min(s.bounds_h / 20, 40));
                s.logical_w = want_w;
                s.logical_h = want_h;
                try self.applySize(idx);
                s.configured = true;
                try c.flush();
            },
            .fs_obj => if (opcode == wl.wp_fractional_scale_v1.ev_preferred_scale) {
                const new_scale = try r.uint();
                if (new_scale != s.scale120 and new_scale > 0) {
                    s.scale120 = new_scale;
                    if (s.configured) {
                        try self.applySize(idx);
                        try c.flush();
                    }
                }
            },
            .wl_surface => switch (opcode) {
                wl.wl_surface.ev_enter, wl.wl_surface.ev_leave => {
                    const out = try r.uint();
                    if (self.outputSlotOf(out)) |slot| {
                        const bit = @as(u32, 1) << @intCast(slot);
                        if (opcode == wl.wl_surface.ev_enter) s.entered |= bit else s.entered &= ~bit;
                        try self.updateIntScale(idx);
                        // the output decides the exact buffer size (outputBufferSize)
                        if (s.fs_obj != 0 and s.configured and s.output == 0) try self.applySize(idx);
                    }
                },
                wl.wl_surface.ev_preferred_buffer_scale => {
                    s.preferred_int = @max(1, try r.int());
                    try self.updateIntScale(idx);
                },
                else => {},
            },
            .frame_cb => if (opcode == wl.wl_callback.ev_done) {
                s.frame_pending = false;
                s.frame_cb = 0;
                try self.queue.append(self.alloc, .frame_done);
            },
            .buffer0 => if (opcode == wl.wl_buffer.ev_release) {
                s.buffers[0].busy = false;
            },
            .buffer1 => if (opcode == wl.wl_buffer.ev_release) {
                s.buffers[1].busy = false;
            },
        }
        if (idx == 0) self.syncPrimary();
    }

    fn copyStr(dst: []u8, src: []const u8) u8 {
        const n = @min(dst.len, src.len, 255);
        @memcpy(dst[0..n], src[0..n]);
        return @intCast(n);
    }

    fn handleOutput(self: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
        const o = &self.outputs[slot];
        switch (opcode) {
            wl.wl_output.ev_geometry => {
                o.geo_x = try r.int();
                o.geo_y = try r.int();
                if (o.version < 2) o.done = true;
            },
            wl.wl_output.ev_mode => {
                const flags = try r.uint();
                const w = try r.int();
                const h = try r.int();
                if (flags & wl.wl_output.mode_current != 0) {
                    o.mode_w = w;
                    o.mode_h = h;
                }
            },
            wl.wl_output.ev_scale => o.scale = @max(1, try r.int()),
            wl.wl_output.ev_name => o.name_len = copyStr(&o.name_buf, try r.string()),
            wl.wl_output.ev_description => o.desc_len = copyStr(&o.desc_buf, try r.string()),
            wl.wl_output.ev_done => try self.outputChanged(slot),
            else => {},
        }
    }

    fn handleXdgOutput(self: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
        const o = &self.outputs[slot];
        switch (opcode) {
            wl.zxdg_output_v1.ev_logical_position => {
                o.x = try r.int();
                o.y = try r.int();
                o.has_logical = true;
            },
            wl.zxdg_output_v1.ev_logical_size => {
                o.w = try r.int();
                o.h = try r.int();
                o.has_logical = true;
            },
            wl.zxdg_output_v1.ev_name => if (o.name_len == 0) {
                o.name_len = copyStr(&o.name_buf, try r.string());
            },
            wl.zxdg_output_v1.ev_done => try self.outputChanged(slot),
            else => {},
        }
    }

    /// An output's state is complete: refresh surfaces placed on it.
    fn outputChanged(self: *Window, slot: usize) !void {
        const o = &self.outputs[slot];
        o.done = true;
        for (self.surfaces[0..self.n_surfaces], 0..) |*s, i| {
            if (!s.alive) continue;
            if (s.output != 0 and s.output == o.global) setOutputRect(s, o);
            try self.updateIntScale(@intCast(i));
        }
    }

    /// Take the pointer and keyboard the seat actually has, and let go of
    /// ones it lost. Asking for a device the seat does not announce is
    /// legal but has crashed compositors (mutter's headless backend).
    fn updateSeatDevices(self: *Window) !void {
        if (self.seat == 0 or self.surfaces[0].wl_surface == 0) return;
        const c = &self.conn;
        const has_pointer = self.seat_caps & wl.wl_seat.cap_pointer != 0;
        const has_keyboard = self.seat_caps & wl.wl_seat.cap_keyboard != 0;
        if (has_pointer and self.pointer == 0) {
            self.pointer = c.newId();
            try c.request(self.seat, wl.wl_seat.get_pointer, &.{.{ .new_id = self.pointer }});
            if (self.rel_manager != 0 and self.track_relative) {
                self.rel_pointer = c.newId();
                // zwp_relative_pointer_manager_v1.get_relative_pointer
                try c.request(self.rel_manager, 1, &.{ .{ .new_id = self.rel_pointer }, .{ .object = self.pointer } });
            }
        } else if (!has_pointer and self.pointer != 0) {
            if (self.rel_pointer != 0) {
                try c.request(self.rel_pointer, 0, &.{}); // destroy
                self.rel_pointer = 0;
            }
            if (self.seat_version >= 3) try c.request(self.pointer, wl.wl_pointer.release, &.{});
            self.pointer = 0;
        }
        if (has_keyboard and self.keyboard == 0) {
            self.keyboard = c.newId();
            try c.request(self.seat, wl.wl_seat.get_keyboard, &.{.{ .new_id = self.keyboard }});
        } else if (!has_keyboard and self.keyboard != 0) {
            if (self.seat_version >= 3) try c.request(self.keyboard, wl.wl_keyboard.release, &.{});
            self.keyboard = 0;
            self.kb.leave();
        }
    }

    fn handlePointer(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_pointer.ev_leave => {
                self.pointer_in = false;
                if (self.report_leave) try self.queue.append(self.alloc, .{ .pointer_motion = .{ .x = -1, .y = -1, .surface = self.ptr_surface } });
            },
            wl.wl_pointer.ev_enter => {
                self.pointer_in = true;
                self.enter_serial = try r.uint();
                const surf = try r.uint();
                self.ptr_surface = self.surfaceIndexOf(surf) orelse 0;
                const f = self.pointerScale();
                self.ptr_x = (try r.fixed()) * f[0];
                self.ptr_y = (try r.fixed()) * f[1];
                try self.applyCursor();
            },
            wl.wl_pointer.ev_motion => {
                _ = try r.uint(); // time
                const f = self.pointerScale();
                self.ptr_x = (try r.fixed()) * f[0];
                self.ptr_y = (try r.fixed()) * f[1];
                const ev: InputEvent = .{ .pointer_motion = .{ .x = self.ptr_x, .y = self.ptr_y, .surface = self.ptr_surface } };
                // coalesce with a queued motion on the same surface
                if (self.queue.items.len > 0) {
                    const last = &self.queue.items[self.queue.items.len - 1];
                    if (last.* == .pointer_motion and last.pointer_motion.surface == self.ptr_surface) {
                        last.* = ev;
                        return;
                    }
                }
                try self.queue.append(self.alloc, ev);
            },
            wl.wl_pointer.ev_button => {
                const serial = try r.uint();
                _ = try r.uint(); // time
                const button = try r.uint();
                const state = try r.uint();
                self.input_serial = serial;
                try self.queue.append(self.alloc, .{ .pointer_button = .{
                    .button = button,
                    .pressed = state == 1,
                    .x = self.ptr_x,
                    .y = self.ptr_y,
                    .surface = self.ptr_surface,
                } });
            },
            wl.wl_pointer.ev_axis => {
                _ = try r.uint(); // time
                const axis = try r.uint();
                const value = try r.fixed();
                if (axis == 0) { // vertical
                    self.axis_value += value;
                    self.axis_pending = true;
                    // before v5 there is no frame event to wait for
                    if (self.seat_version < 5) try self.flushAxis();
                }
            },
            wl.wl_pointer.ev_axis_value120 => {
                const axis = try r.uint();
                const v120 = try r.int();
                if (axis == 0) {
                    self.axis_v120 = (self.axis_v120 orelse 0) + v120;
                    self.axis_pending = true;
                }
            },
            wl.wl_pointer.ev_frame => try self.flushAxis(),
            else => {},
        }
    }

    /// One scroll event per pointer frame, carrying both the smooth value
    /// and the wheel's exact notches when it sent them.
    fn flushAxis(self: *Window) !void {
        if (!self.axis_pending) return;
        try self.queue.append(self.alloc, .{ .pointer_axis = .{ .value = self.axis_value, .value120 = self.axis_v120, .surface = self.ptr_surface } });
        self.axis_value = 0;
        self.axis_v120 = null;
        self.axis_pending = false;
    }

    /// Buffer pixels per logical pixel, per axis (see outputBufferSize:
    /// the buffer is not always exactly logical * scale120 / 120).
    fn pointerScale(self: *const Window) [2]f64 {
        const s = &self.surfaces[self.ptr_surface];
        if (s.logical_w == 0 or s.logical_h == 0 or s.width == 0 or s.height == 0) {
            const f = @as(f64, @floatFromInt(s.scale120)) / 120.0;
            return .{ f, f };
        }
        return .{
            @as(f64, @floatFromInt(s.width)) / @as(f64, @floatFromInt(s.logical_w)),
            @as(f64, @floatFromInt(s.height)) / @as(f64, @floatFromInt(s.logical_h)),
        };
    }

    fn translateKey(self: *Window, code: u32, pressed: bool, use_compose: bool) Key {
        const t = self.kb.translate(code, pressed, use_compose);
        self.ctrl = t.ctrl;
        self.shift = t.shift;
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

    fn handleKeyboard(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_keyboard.ev_keymap => {
                const format = try r.uint();
                const size = try r.uint();
                if (self.conn.takeFd()) |fd| {
                    defer sys.close(fd);
                    self.kb.setKeymapFd(format, fd, size);
                }
            },
            wl.wl_keyboard.ev_key => {
                const serial = try r.uint();
                _ = try r.uint(); // time
                const code = try r.uint();
                const state = try r.uint();
                self.input_serial = serial;
                const pressed = state == 1;
                const key = self.translateKey(code, pressed, true);
                if (pressed) {
                    self.kb.repeat.press(code, self.kb.keyRepeats(code), keyboard.monotonicMs());
                } else {
                    self.kb.repeat.release(code);
                }
                try self.queue.append(self.alloc, .{ .key = key });
            },
            wl.wl_keyboard.ev_modifiers => {
                _ = try r.uint(); // serial
                const depressed = try r.uint();
                const latched = try r.uint();
                const locked = try r.uint();
                const group = try r.uint();
                self.kb.updateMods(depressed, latched, locked, group);
                const t = self.kb.translate(0, false, false);
                self.ctrl = t.ctrl;
                self.shift = t.shift;
            },
            wl.wl_keyboard.ev_repeat_info => {
                const rate = try r.int();
                const delay = try r.int();
                self.kb.repeat.setInfo(rate, delay);
            },
            wl.wl_keyboard.ev_enter => {
                self.kb_focus = true;
                self.input_serial = try r.uint();
                self.key_surface = self.surfaceIndexOf(try r.uint()) orelse 0;
                std.log.debug("keyboard focus: surface {d}", .{self.key_surface});
            },
            wl.wl_keyboard.ev_leave => {
                self.kb_focus = false;
                std.log.debug("keyboard focus lost", .{});
                self.kb.leave();
            },
            else => {},
        }
    }

    // --- text-input-v3 (IME) ---

    /// Enable or disable input-method composition. Call with true while
    /// the user edits text, passing the caret rectangle in buffer pixels of
    /// the focused surface (null keeps the last one); false when editing
    /// ends. No-op when the compositor lacks zwp_text_input_manager_v3.
    pub fn setTextInput(self: *Window, enabled: bool, cursor_rect: ?Rect) !void {
        if (cursor_rect) |rc| self.ti_rect = rc;
        const changed = enabled != self.ti_want;
        self.ti_want = enabled;
        if (self.text_input == 0 or !self.ti_focus) return;
        if (!changed and !enabled) return;
        try self.sendTextInputState(changed);
    }

    /// Whether IME composition is available (protocol bound).
    pub fn hasTextInput(self: *const Window) bool {
        return self.text_input != 0;
    }

    /// The IME preedit string being composed (empty when none).
    pub fn preedit(self: *const Window) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    fn sendTextInputState(self: *Window, reenable: bool) !void {
        const c = &self.conn;
        const ti = self.text_input;
        if (self.ti_want) {
            if (reenable or !self.ti_enabled) {
                try c.request(ti, wl.zwp_text_input_v3.enable, &.{});
                self.ti_enabled = true;
            }
            if (self.ti_rect) |rc| {
                const f = @as(f64, @floatFromInt(self.surfaces[self.ti_surface].scale120)) / 120.0;
                const lr = logicalRect(rc, f);
                try c.request(ti, wl.zwp_text_input_v3.set_cursor_rectangle, &.{
                    .{ .int = lr.x }, .{ .int = lr.y }, .{ .int = lr.w }, .{ .int = lr.h },
                });
            }
        } else if (self.ti_enabled) {
            try c.request(ti, wl.zwp_text_input_v3.disable, &.{});
            self.ti_enabled = false;
            try self.setPreedit("");
        }
        try c.request(ti, wl.zwp_text_input_v3.commit, &.{});
        try c.flush();
    }

    fn logicalRect(rc: Rect, f: f64) Rect {
        const d = if (f > 0) f else 1.0;
        return .{
            .x = @intFromFloat(@floor(@as(f64, @floatFromInt(rc.x)) / d)),
            .y = @intFromFloat(@floor(@as(f64, @floatFromInt(rc.y)) / d)),
            .w = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(rc.w)) / d)))),
            .h = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(rc.h)) / d)))),
        };
    }

    fn handleTextInput(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.zwp_text_input_v3.ev_enter => {
                self.ti_focus = true;
                self.ti_surface = self.surfaceIndexOf(try r.uint()) orelse 0;
                self.ti_enabled = false;
                if (self.ti_want) try self.sendTextInputState(true);
            },
            wl.zwp_text_input_v3.ev_leave => {
                self.ti_focus = false;
                self.ti_enabled = false;
                try self.setPreedit("");
            },
            wl.zwp_text_input_v3.ev_preedit_string => {
                const s = try r.string();
                self.ti_pending_preedit_len = @min(s.len, self.ti_pending_preedit.len);
                @memcpy(self.ti_pending_preedit[0..self.ti_pending_preedit_len], s[0..self.ti_pending_preedit_len]);
            },
            wl.zwp_text_input_v3.ev_commit_string => {
                const s = try r.string();
                const room = self.ti_pending_commit.len - self.ti_pending_commit_len;
                const n = @min(s.len, room);
                @memcpy(self.ti_pending_commit[self.ti_pending_commit_len..][0..n], s[0..n]);
                self.ti_pending_commit_len += n;
            },
            wl.zwp_text_input_v3.ev_done => {
                // apply in protocol order: commit text, then the new preedit
                // (cleared unless one was sent with this done)
                const commit = self.ti_pending_commit[0..self.ti_pending_commit_len];
                try self.queueText(commit);
                self.ti_pending_commit_len = 0;
                try self.setPreedit(self.ti_pending_preedit[0..self.ti_pending_preedit_len]);
                self.ti_pending_preedit_len = 0;
            },
            else => {}, // delete_surrounding_text: no surrounding text is sent
        }
    }

    /// Queue committed IME text as key-like events (code 0).
    fn queueText(self: *Window, s: []const u8) !void {
        var rest = s;
        while (rest.len > 0) {
            var key: Key = .{ .code = 0, .pressed = true, .ctrl = false, .shift = false };
            const n = utf8Chunk(rest, key.text_buf.len);
            @memcpy(key.text_buf[0..n], rest[0..n]);
            key.text_len = @intCast(n);
            try self.queue.append(self.alloc, .{ .key = key });
            rest = rest[n..];
        }
    }

    fn setPreedit(self: *Window, s: []const u8) !void {
        if (std.mem.eql(u8, s, self.preedit())) return;
        const n = utf8Chunk(s, self.preedit_buf.len);
        @memcpy(self.preedit_buf[0..n], s[0..n]);
        self.preedit_len = n;
        try self.queue.append(self.alloc, .{ .key = .{ .code = 0, .pressed = false, .ctrl = false, .shift = false, .preedit = true } });
    }

    // --- cursors ---

    const cursor_size = 27;

    fn initCursors(self: *Window) !void {
        const c = &self.conn;
        const buf_size: usize = cursor_size * cursor_size * 4;
        const total = buf_size * self.cursor_buffers.len;
        const fd = try sys.memfdCreate("shotlet-cursor", sys.MFD_CLOEXEC);
        // note: flushed before close below; fds travel with the queued bytes
        defer sys.close(fd);
        try sys.ftruncate(fd, total);
        self.cursor_pool_mem = try sys.mmapRw(fd, total);

        const pool = c.newId();
        try c.request(self.shm, wl.wl_shm.create_pool, &.{
            .{ .new_id = pool },
            .{ .fd = fd },
            .{ .int = @intCast(total) },
        });
        for (&self.cursor_buffers, 0..) |*id, i| {
            id.* = c.newId();
            try c.request(pool, wl.wl_shm_pool.create_buffer, &.{
                .{ .new_id = id.* },
                .{ .int = @intCast(i * buf_size) },
                .{ .int = cursor_size },
                .{ .int = cursor_size },
                .{ .int = cursor_size * 4 },
                .{ .uint = wl.wl_shm.format_argb8888 },
            });
            const pixels = @as([*]u32, @ptrCast(@alignCast(self.cursor_pool_mem.ptr)))[i * cursor_size * cursor_size ..][0 .. cursor_size * cursor_size];
            drawCursor(@as(Cursor, @fromBackingInt(@intCast(i))), pixels);
        }
        try c.request(pool, wl.wl_shm_pool.destroy, &.{});

        self.cursor_surface = c.newId();
        try c.request(self.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = self.cursor_surface }});
        try c.flush(); // must hit the wire while the memfd is still open
    }

    fn drawCursor(kind: Cursor, px: []u32) void {
        @memset(px, 0);
        var c = render.Canvas.init(px, cursor_size, cursor_size);
        const n: f64 = cursor_size;
        const mid = n / 2.0;
        const m: i32 = cursor_size / 2;
        const white: u32 = 0xFFFFFFFF;
        const black: u32 = 0xE6000000;
        const P = struct { x: i32, y: i32 };

        switch (kind) {
            .crosshair => {
                const arms = [4][2]P{
                    .{ .{ .x = m, .y = 0 }, .{ .x = m, .y = m - 4 } },
                    .{ .{ .x = m, .y = m + 4 }, .{ .x = m, .y = cursor_size - 1 } },
                    .{ .{ .x = 0, .y = m }, .{ .x = m - 4, .y = m } },
                    .{ .{ .x = m + 4, .y = m }, .{ .x = cursor_size - 1, .y = m } },
                };
                for (arms) |a| c.strokePolylineAA(a[0..], 3.4, black);
                for (arms) |a| c.strokePolylineAA(a[0..], 1.6, white);
                c.fillCircleAA(mid, mid, 1.2, white);
            },
            .arrow => {
                // classic pointer with outline
                c.fillTriangleAA(3, 1, 3, 19, 16, 12, black);
                c.fillTriangleAA(4, 4, 4, 16.5, 13.5, 11, white);
            },
            .move => {
                const arms = [4][2]P{
                    .{ .{ .x = m, .y = m }, .{ .x = m, .y = 1 } },
                    .{ .{ .x = m, .y = m }, .{ .x = m, .y = cursor_size - 2 } },
                    .{ .{ .x = m, .y = m }, .{ .x = 1, .y = m } },
                    .{ .{ .x = m, .y = m }, .{ .x = cursor_size - 2, .y = m } },
                };
                for (arms) |a| c.arrowAA(a[0].x, a[0].y, a[1].x, a[1].y, 4, black);
                for (arms) |a| c.arrowAA(a[0].x, a[0].y, a[1].x, a[1].y, 2, white);
            },
            .text => {
                const stem = [_]P{ .{ .x = m, .y = 3 }, .{ .x = m, .y = cursor_size - 4 } };
                c.strokePolylineAA(stem[0..], 3.2, black);
                c.strokePolylineAA(stem[0..], 1.4, white);
                c.fillRect(m - 3, 2, 7, 2, white);
                c.fillRect(m - 3, cursor_size - 4, 7, 2, white);
            },
            .resize_nwse, .resize_nesw, .resize_ns, .resize_ew => {
                const d: f64 = 9.0;
                var dx: f64 = 0;
                var dy: f64 = 0;
                switch (kind) {
                    .resize_nwse => {
                        dx = d * 0.707;
                        dy = d * 0.707;
                    },
                    .resize_nesw => {
                        dx = d * 0.707;
                        dy = -d * 0.707;
                    },
                    .resize_ns => dy = d,
                    .resize_ew => dx = d,
                    else => {},
                }
                const x0: i32 = @intFromFloat(mid - dx);
                const y0: i32 = @intFromFloat(mid - dy);
                const x1: i32 = @intFromFloat(mid + dx);
                const y1: i32 = @intFromFloat(mid + dy);
                c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x1, y1, 4, black);
                c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x0, y0, 4, black);
                c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x1, y1, 2, white);
                c.arrowAA(@intFromFloat(mid), @intFromFloat(mid), x0, y0, 2, white);
            },
        }
    }

    pub fn setCursor(self: *Window, kind: Cursor) !void {
        if (self.current_cursor == kind) return;
        self.current_cursor = kind;
        try self.applyCursor();
    }

    fn applyCursor(self: *Window) !void {
        if (self.pointer == 0 or self.cursor_surface == 0) return;
        const c = &self.conn;
        const idx: usize = @backingInt(self.current_cursor);
        try c.request(self.cursor_surface, wl.wl_surface.attach, &.{ .{ .object = self.cursor_buffers[idx] }, .{ .int = 0 }, .{ .int = 0 } });
        try c.request(self.cursor_surface, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = cursor_size }, .{ .int = cursor_size } });
        try c.request(self.cursor_surface, wl.wl_surface.commit, &.{});
        const hot: i32 = if (self.current_cursor == .arrow) 3 else cursor_size / 2;
        try c.request(self.pointer, wl.wl_pointer.set_cursor, &.{
            .{ .uint = self.enter_serial },
            .{ .object = self.cursor_surface },
            .{ .int = hot },
            .{ .int = if (self.current_cursor == .arrow) 2 else hot },
        });
        try c.flush();
    }

    /// Begin an interactive compositor-driven move (call on header drag).
    pub fn startMove(self: *Window) !void {
        const toplevel = self.surfaces[0].toplevel;
        if (self.seat == 0 or toplevel == 0) return;
        try self.conn.request(toplevel, wl.xdg_toplevel.move, &.{
            .{ .object = self.seat },
            .{ .uint = self.input_serial },
        });
        try self.conn.flush();
    }

    pub fn toggleMaximize(self: *Window) !void {
        const toplevel = self.surfaces[0].toplevel;
        if (toplevel == 0) return;
        const op: u16 = if (self.surfaces[0].maximized) wl.xdg_toplevel.unset_maximized else wl.xdg_toplevel.set_maximized;
        try self.conn.request(toplevel, op, &.{});
        try self.conn.flush();
    }

    pub fn minimize(self: *Window) !void {
        const toplevel = self.surfaces[0].toplevel;
        if (toplevel == 0) return;
        try self.conn.request(toplevel, wl.xdg_toplevel.set_minimized, &.{});
        try self.conn.flush();
    }

    /// Destroy the visible window(s) (keeps the connection alive so an
    /// offered clipboard selection can still be served).
    pub fn closeWindow(self: *Window) void {
        self.dumpFrames();
        if (self.text_input != 0) {
            self.conn.request(self.text_input, wl.zwp_text_input_v3.destroy, &.{}) catch {};
            self.text_input = 0;
        }
        for (0..self.n_surfaces) |i| self.destroySurface(@intCast(i));
        self.conn.flush() catch {};
    }

    pub fn hasClipboard(self: *const Window) bool {
        return self.clipboard_source != 0;
    }

    /// The PNG we offer on the clipboard (encoding it first if needed);
    /// null when we offer none or text.
    pub fn clipboardPng(self: *Window) ?[]const u8 {
        if (self.clipboard_source == 0) return null;
        if (self.clipboard_image) |image| return image.waitPng() catch null;
        if (self.clipboard_png.len > 0) return self.clipboard_png;
        return null;
    }

    // --- surface roles and regions ---

    /// Where surface idx takes pointer input, in its logical coordinates;
    /// null: everywhere. Elsewhere clicks reach the window below. Applied
    /// with the next present.
    pub fn setInputRegion(self: *Window, idx: u8, rects: ?[]const Rect) !void {
        const s = &self.surfaces[idx];
        if (!s.alive) return error.NoSuchSurface;
        const c = &self.conn;
        const rs = rects orelse {
            try c.request(s.wl_surface, wl.wl_surface.set_input_region, &.{.{ .object = 0 }});
            return;
        };
        const region = c.newId();
        try c.request(self.compositor, wl.wl_compositor.create_region, &.{.{ .new_id = region }});
        for (rs) |r| try c.request(region, wl.wl_region.add, &.{ .{ .int = r.x }, .{ .int = r.y }, .{ .int = r.w }, .{ .int = r.h } });
        try c.request(s.wl_surface, wl.wl_surface.set_input_region, &.{.{ .object = region }});
        try c.request(region, wl.wl_region.destroy, &.{});
    }

    /// The part of surface idx that is the window proper (logical
    /// coordinates), without its drawn shadow. xdg toplevels only.
    pub fn setWindowGeometry(self: *Window, idx: u8, r: Rect) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.xdg_surf == 0) return;
        s.geom_extra_w = s.logical_w -| @as(u32, @intCast(@max(0, r.w)));
        s.geom_extra_h = s.logical_h -| @as(u32, @intCast(@max(0, r.h)));
        try self.conn.request(s.xdg_surf, wl.xdg_surface.set_window_geometry, &.{ .{ .int = r.x }, .{ .int = r.y }, .{ .int = r.w }, .{ .int = r.h } });
    }

    /// Change a toplevel's title (window rules key on it).
    pub fn setTitle(self: *Window, idx: u8, title: []const u8) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.toplevel == 0) return;
        try self.conn.request(s.toplevel, wl.xdg_toplevel.set_title, &.{.{ .string = title }});
        try self.conn.flush();
    }

    /// The compositor's window menu (GNOME: Always on Top, Move, ...) at
    /// logical x, y of surface idx. Call from a button press.
    pub fn showWindowMenu(self: *Window, idx: u8, x: i32, y: i32) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.toplevel == 0 or self.seat == 0) return;
        try self.conn.request(s.toplevel, wl.xdg_toplevel.show_window_menu, &.{
            .{ .object = self.seat }, .{ .uint = self.input_serial }, .{ .int = x }, .{ .int = y },
        });
        try self.conn.flush();
    }

    /// Move or resize a layer surface (logical pixels; margins are top,
    /// right, bottom, left). A new size arrives as a .resize event.
    pub fn setLayerPlacement(self: *Window, idx: u8, width: u32, height: u32, margin: [4]i32) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.layer_surf == 0) return;
        const c = &self.conn;
        const L = wl.zwlr_layer_surface_v1;
        try c.request(s.layer_surf, L.set_size, &.{ .{ .uint = width }, .{ .uint = height } });
        try c.request(s.layer_surf, L.set_margin, &.{
            .{ .int = margin[0] }, .{ .int = margin[1] }, .{ .int = margin[2] }, .{ .int = margin[3] },
        });
        try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
        try c.flush();
    }

    /// Ask an xdg toplevel to become a new size (logical); takes effect at
    /// the next configure the compositor sends (or our own resize when it
    /// lets the client decide): used by windows that size themselves.
    pub fn resizeTo(self: *Window, idx: u8, width: u32, height: u32) !void {
        const s = &self.surfaces[idx];
        if (!s.alive or s.maximized) return;
        if (s.logical_w == width and s.logical_h == height) return;
        s.logical_w = width;
        s.logical_h = height;
        s.pending_w = 0;
        s.pending_h = 0;
        try self.applySize(idx);
        try self.conn.flush();
    }

    /// Begin an interactive move of surface idx (call on a button press).
    pub fn startMoveOf(self: *Window, idx: u8) !void {
        const s = &self.surfaces[idx];
        if (self.seat == 0 or s.toplevel == 0) return;
        try self.conn.request(s.toplevel, wl.xdg_toplevel.move, &.{ .{ .object = self.seat }, .{ .uint = self.input_serial } });
        try self.conn.flush();
    }

    // --- drag and drop out ---

    /// Start dragging an image out of surface idx; call on the button
    /// press (its serial starts the drag). Offers drag_mimes: `png_data`
    /// as image/png and `uri_list` as text/uri-list (copy semantics).
    /// Takes ownership of both on success. Follow drag_state.
    pub fn startDrag(self: *Window, idx: u8, png_data: []u8, uri_list: []u8, icon: ?DragIcon) !void {
        if (self.ddm == 0 or self.data_device == 0) return error.NoDataDevice;
        const s = &self.surfaces[idx];
        if (!s.alive) return error.NoSuchSurface;
        self.endDrag();
        const c = &self.conn;
        const source = c.newId();
        try c.request(self.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
        for (drag_mimes) |m| try c.request(source, wl.wl_data_source.offer, &.{.{ .string = m }});
        if (self.ddm_version >= 3) try c.request(source, wl.wl_data_source.set_actions, &.{.{ .uint = wl.dnd_action_copy }});
        var icon_id: u32 = 0;
        if (icon) |ic| icon_id = self.makeDragIcon(ic) catch 0;
        try c.request(self.data_device, wl.wl_data_device.start_drag, &.{
            .{ .object = source }, .{ .object = s.wl_surface }, .{ .object = icon_id }, .{ .uint = self.input_serial },
        });
        try c.flush();
        self.drag_source = source;
        self.drag_png = png_data;
        self.drag_uri = uri_list;
        self.drag_state = .active;
        self.drag_accepted = false;
    }

    fn makeDragIcon(self: *Window, ic: DragIcon) !u32 {
        const c = &self.conn;
        const size: usize = @as(usize, ic.width) * ic.height * 4;
        const fd = try sys.memfdCreate("shotlet-dnd", sys.MFD_CLOEXEC);
        defer sys.close(fd); // flushed below while still open
        try sys.ftruncate(fd, size);
        self.drag_icon_mem = try sys.mmapRw(fd, size);
        @memcpy(@as([*]u32, @ptrCast(@alignCast(self.drag_icon_mem.ptr)))[0 .. size / 4], ic.pixels[0 .. size / 4]);
        const pool = c.newId();
        try c.request(self.shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
        self.drag_icon_buf = c.newId();
        try c.request(pool, wl.wl_shm_pool.create_buffer, &.{
            .{ .new_id = self.drag_icon_buf }, .{ .int = 0 },                      .{ .int = @intCast(ic.width) },
            .{ .int = @intCast(ic.height) },   .{ .int = @intCast(ic.width * 4) }, .{ .uint = wl.wl_shm.format_argb8888 },
        });
        try c.request(pool, wl.wl_shm_pool.destroy, &.{});
        self.drag_icon = c.newId();
        try c.request(self.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = self.drag_icon }});
        const k = @max(1, ic.scale);
        if (self.compositor_version >= 3 and k > 1) try c.request(self.drag_icon, wl.wl_surface.set_buffer_scale, &.{.{ .int = k }});
        // the pointer holds the icon a little in from its top-left corner
        const hx: i32 = -@as(i32, @intCast(@min(ic.width / @as(u32, @intCast(k)) / 2, 40)));
        const hy: i32 = -@as(i32, @intCast(@min(ic.height / @as(u32, @intCast(k)) / 2, 30)));
        if (self.compositor_version >= 5) {
            try c.request(self.drag_icon, wl.wl_surface.attach, &.{ .{ .object = self.drag_icon_buf }, .{ .int = 0 }, .{ .int = 0 } });
            try c.request(self.drag_icon, wl.wl_surface.offset, &.{ .{ .int = hx }, .{ .int = hy } });
        } else {
            try c.request(self.drag_icon, wl.wl_surface.attach, &.{ .{ .object = self.drag_icon_buf }, .{ .int = hx }, .{ .int = hy } });
        }
        try c.request(self.drag_icon, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = std.math.maxInt(i32) }, .{ .int = std.math.maxInt(i32) } });
        try c.request(self.drag_icon, wl.wl_surface.commit, &.{});
        try c.flush(); // the memfd travels with these bytes
        return self.drag_icon;
    }

    fn handleDragSource(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_data_source.ev_target => {
                const mime = r.string() catch "";
                self.drag_accepted = mime.len > 0;
            },
            wl.wl_data_source.ev_send => {
                const mime = try r.string();
                const fd = self.conn.takeFd() orelse return;
                defer sys.close(fd);
                const data: []const u8 = switch (dragPayloadFor(mime) orelse return) {
                    .png => self.drag_png,
                    .uri_list => self.drag_uri,
                };
                sys.writeAllBlocking(fd, data) catch |err| switch (err) {
                    error.BrokenPipe, error.ConnectionReset => {},
                    else => std.log.warn("drag send failed: {t}", .{err}),
                };
                // before v3 there is no dnd_finished: a read is the drop
                if (self.ddm_version < 3) self.drag_state = .finished;
            },
            wl.wl_data_source.ev_dnd_drop_performed => {
                if (self.drag_state == .active) self.drag_state = .dropped;
            },
            wl.wl_data_source.ev_dnd_finished => {
                self.drag_state = .finished;
                self.releaseDragSource();
            },
            wl.wl_data_source.ev_cancelled => {
                if (self.drag_state != .finished) self.drag_state = .cancelled;
                self.releaseDragSource();
            },
            else => {},
        }
    }

    fn releaseDragSource(self: *Window) void {
        const c = &self.conn;
        if (self.drag_source != 0) c.request(self.drag_source, wl.wl_data_source.destroy, &.{}) catch {};
        self.drag_source = 0;
        if (self.drag_icon != 0) c.request(self.drag_icon, wl.wl_surface.destroy, &.{}) catch {};
        self.drag_icon = 0;
        if (self.drag_icon_buf != 0) c.request(self.drag_icon_buf, wl.wl_buffer.destroy, &.{}) catch {};
        self.drag_icon_buf = 0;
        if (self.drag_icon_mem.len > 0) sys.munmap(self.drag_icon_mem);
        self.drag_icon_mem = &.{};
        c.flush() catch {};
    }

    /// Drop the drag's source and payloads; drag_state becomes .none.
    pub fn endDrag(self: *Window) void {
        self.releaseDragSource();
        if (self.drag_png.len > 0) self.alloc.free(self.drag_png);
        if (self.drag_uri.len > 0) self.alloc.free(self.drag_uri);
        self.drag_png = &.{};
        self.drag_uri = &.{};
        self.drag_state = .none;
    }

    /// Claim the clipboard selection with an already-encoded image/png data
    /// source. Takes ownership of data on success. Call while the window still
    /// has focus (serial must be fresh).
    pub fn setClipboardPng(self: *Window, data: []u8) !void {
        try self.claimClipboardSource(&.{"image/png"});
        self.clipboard_png = data;
    }

    /// Claim the clipboard selection immediately, then encode the raw image in
    /// the background. Takes ownership of pixels on success.
    pub fn setClipboardImage(self: *Window, pixels: []u32, width: u32, height: u32) !void {
        const image = try ClipboardImage.create(self.alloc, pixels, width, height);
        errdefer image.deinit();
        try self.claimClipboardSource(&.{"image/png"});
        self.clipboard_image = image;
    }

    /// Put UTF-8 text on the clipboard. Takes ownership of `data` on
    /// success.
    pub fn setClipboardText(self: *Window, data: []u8) !void {
        try self.claimClipboardSource(&.{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" });
        self.clipboard_text = data;
    }

    fn claimClipboardSource(self: *Window, mimes: []const []const u8) !void {
        if (self.ddm == 0 or self.data_device == 0) return error.NoDataDevice;
        const c = &self.conn;
        const source = c.newId();
        try c.request(self.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
        for (mimes) |m| try c.request(source, wl.wl_data_source.offer, &.{.{ .string = m }});
        try c.request(self.data_device, wl.wl_data_device.set_selection, &.{ .{ .object = source }, .{ .uint = self.input_serial } });
        try c.flush();

        self.dropClipboardSource();
        self.clipboard_source = source;
    }

    /// Serve clipboard reads until another client replaces the selection.
    /// Blocks; safe to call after closeWindow().
    pub fn serveClipboard(self: *Window) !void {
        while (self.clipboard_source != 0) {
            const ev = try self.conn.readEvent();
            try self.handleEvent(ev);
            self.queue.clearRetainingCapacity();
        }
    }

    fn offerSlot(self: *const Window, id: u32) ?usize {
        if (id == 0) return null;
        for (self.offers, 0..) |o, i| if (o.id == id) return i;
        return null;
    }

    fn dropOffer(self: *Window, slot: usize) void {
        const id = self.offers[slot].id;
        if (id == 0) return;
        self.conn.request(id, wl.wl_data_offer.destroy, &.{}) catch {};
        if (self.selection_offer == id) self.selection_offer = 0;
        self.offers[slot] = .{};
    }

    fn handleDataDevice(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_data_device.ev_data_offer => {
                const id = try r.uint();
                // a free slot, else the oldest offer that is not the selection
                var slot: usize = 0;
                for (self.offers, 0..) |o, i| {
                    if (o.id == 0) {
                        slot = i;
                        break;
                    }
                    if (o.id != self.selection_offer) slot = i;
                }
                self.dropOffer(slot);
                self.offers[slot] = .{ .id = id };
            },
            wl.wl_data_device.ev_enter => {
                const serial = try r.uint();
                _ = try r.uint(); // surface
                _ = try r.fixed();
                _ = try r.fixed();
                self.dnd_offer = try r.uint();
                try self.answerDragOffer(serial);
            },
            wl.wl_data_device.ev_leave => self.dnd_offer = 0,
            wl.wl_data_device.ev_drop => try self.takeDrop(),
            wl.wl_data_device.ev_selection => {
                const id = try r.uint();
                // the previous selection offer is dead once replaced
                for (self.offers, 0..) |o, i| {
                    if (o.id != 0 and o.id != id and o.id == self.selection_offer) self.dropOffer(i);
                }
                self.selection_offer = id;
            },
            else => {},
        }
    }

    /// The best type of the drag offer we take, if any.
    fn dropMime(self: *const Window) ?[]const u8 {
        const slot = self.offerSlot(self.dnd_offer) orelse return null;
        const bits = self.offers[slot].accept;
        if (bits == 0) return null;
        return self.accept_mimes[@ctz(bits)];
    }

    fn answerDragOffer(self: *Window, serial: u32) !void {
        if (self.dnd_offer == 0 or self.accept_mimes.len == 0) return;
        const c = &self.conn;
        const mime = self.dropMime();
        if (mime) |m| {
            try c.request(self.dnd_offer, wl.wl_data_offer.accept, &.{ .{ .uint = serial }, .{ .string = m } });
        } else {
            try c.request(self.dnd_offer, wl.wl_data_offer.accept, &.{ .{ .uint = serial }, .null_string });
        }
        if (self.ddm_version >= 3) {
            const a: u32 = if (mime != null) wl.dnd_action_copy else 0;
            try c.request(self.dnd_offer, wl.wl_data_offer.set_actions, &.{ .{ .uint = a }, .{ .uint = a } });
        }
        try c.flush();
    }

    fn takeDrop(self: *Window) !void {
        const id = self.dnd_offer;
        const mime = self.dropMime() orelse return;
        const c = &self.conn;
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        {
            defer sys.close(fds[1]);
            try c.request(id, wl.wl_data_offer.receive, &.{ .{ .string = mime }, .{ .fd = fds[1] } });
            try c.flush();
        }
        const data = try readBounded(self.alloc, fds[0], 256 * 1024 * 1024, sys.monoMs() + 10_000);
        if (self.ddm_version >= 3) try c.request(id, wl.wl_data_offer.finish, &.{});
        if (self.offerSlot(id)) |slot| self.dropOffer(slot);
        self.dnd_offer = 0;
        try c.flush();
        if (self.dropped) |d| self.alloc.free(d.data);
        self.dropped = .{ .mime = mime, .data = data };
    }

    /// Plain text on the clipboard, or null when it holds none. Reads at
    /// most `max_bytes` and gives up after `timeout_ms` so a stuck source
    /// cannot freeze the UI. Caller owns the bytes.
    pub fn clipboardText(self: *Window, alloc: std.mem.Allocator, max_bytes: usize, timeout_ms: i64) !?[]u8 {
        // our own text: answering our own receive would need this very loop
        if (self.clipboard_source != 0 and self.clipboard_text.len > 0)
            return try alloc.dupe(u8, self.clipboard_text[0..@min(max_bytes, self.clipboard_text.len)]);
        const slot = self.offerSlot(self.selection_offer) orelse return null;
        const kinds = self.offers[slot].text;
        if (kinds == 0) return null;
        const mime = text_mimes[@ctz(kinds)];
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        {
            defer sys.close(fds[1]);
            try self.conn.request(self.selection_offer, wl.wl_data_offer.receive, &.{ .{ .string = mime }, .{ .fd = fds[1] } });
            try self.conn.flush(); // the fd travels with the flushed bytes
        }
        return try readBounded(alloc, fds[0], max_bytes, sys.monoMs() + timeout_ms);
    }

    fn handleClipboardSource(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_data_source.ev_send => {
                _ = try r.string(); // mime
                if (self.conn.takeFd()) |fd| {
                    defer sys.close(fd);
                    const clipboard_data = if (self.clipboard_text.len > 0) self.clipboard_text else if (self.clipboard_image) |image| image.waitPng() catch |err| {
                        std.log.warn("clipboard encode failed: {t}", .{err});
                        return;
                    } else self.clipboard_png;
                    sys.writeAllBlocking(fd, clipboard_data) catch |err| switch (err) {
                        error.BrokenPipe, error.ConnectionReset => {},
                        else => std.log.warn("clipboard send failed: {t}", .{err}),
                    };
                }
            },
            wl.wl_data_source.ev_cancelled => self.dropClipboardSource(),
            else => {},
        }
    }

    fn dropClipboardSource(self: *Window) void {
        if (self.clipboard_source != 0) {
            self.conn.request(self.clipboard_source, wl.wl_data_source.destroy, &.{}) catch {};
            self.clipboard_source = 0;
        }
        if (self.clipboard_text.len > 0) {
            self.alloc.free(self.clipboard_text);
            self.clipboard_text = &.{};
        }
        if (self.clipboard_png.len > 0) {
            self.alloc.free(self.clipboard_png);
            self.clipboard_png = &.{};
        }
        if (self.clipboard_image) |image| {
            image.deinit();
            self.clipboard_image = null;
        }
        self.conn.flush() catch {};
    }
};

test "window decls compile" {
    std.testing.refAllDecls(Window);
}

test "a surface covering one output gets the output's pixels" {
    const t = std.testing;
    // 2560x1440 panel at 1.4953: logical 1712x963, scale120 179 -> 2554x1436
    const approx = bufferSize(1712, 963, 179, true, 1);
    try t.expectEqual([2]u32{ 2554, 1436 }, approx);
    try t.expectEqual([2]u32{ 2560, 1440 }, outputBufferSize(1712, 963, approx, 1712, 963, 2560, 1440).?);
    // rotated panel: the mode is reported in native orientation
    try t.expectEqual([2]u32{ 1440, 2560 }, outputBufferSize(963, 1712, .{ 1436, 2554 }, 963, 1712, 2560, 1440).?);
    // not covering the output, or an implausible mode: keep the computed size
    try t.expect(outputBufferSize(800, 600, .{ 1200, 900 }, 1712, 963, 2560, 1440) == null);
    try t.expect(outputBufferSize(1712, 963, approx, 1712, 963, 3840, 2160) == null);
    try t.expect(outputBufferSize(1712, 963, approx, 1712, 963, 0, 0) == null);
}

test "buffer size for fractional and integer scales" {
    const t = std.testing;
    // fractional 1.25 on 1280x720 logical
    try t.expectEqual([2]u32{ 1600, 900 }, bufferSize(1280, 720, 150, true, 1));
    // fractional 1.0
    try t.expectEqual([2]u32{ 800, 500 }, bufferSize(800, 500, 120, true, 1));
    // integer 2: exact multiple so set_buffer_scale is legal
    try t.expectEqual([2]u32{ 1200, 1820 }, bufferSize(600, 910, 240, false, 2));
    // nonsense scale clamps to 1
    try t.expectEqual([2]u32{ 600, 910 }, bufferSize(600, 910, 120, false, 0));
}

test "integer scale selection" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 3), pickIntScale(3, &.{ 1, 2 }, 1)); // preferred wins
    try t.expectEqual(@as(i32, 2), pickIntScale(0, &.{ 1, 2 }, 1)); // max entered
    try t.expectEqual(@as(i32, 2), pickIntScale(0, &.{}, 2)); // assigned output
    try t.expectEqual(@as(i32, 1), pickIntScale(0, &.{}, 0));
}

test "utf8 chunking never splits a character" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), utf8Chunk("abc", 16));
    // 15 ASCII + "ñ" (2 bytes): the ñ must move to the next chunk
    const s = "aaaaaaaaaaaaaaañ";
    try t.expectEqual(@as(usize, 15), utf8Chunk(s, 16));
    // "€" is 3 bytes: 16 bytes of 5 euros + 1 -> 15
    try t.expectEqual(@as(usize, 15), utf8Chunk("€€€€€€", 16));
    // malformed continuation run still makes progress
    const junk: [20]u8 = @splat(0x80);
    try t.expect(utf8Chunk(&junk, 16) > 0);
}

test "caret rectangle converts to logical coordinates" {
    const r = Window.logicalRect(.{ .x = 301, .y = 50, .w = 3, .h = 41 }, 2.0);
    try std.testing.expectEqual(Rect{ .x = 150, .y = 25, .w = 2, .h = 21 }, r);
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

fn testWireString(buf: []u8, s: []const u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(s.len + 1), .little);
    @memcpy(buf[4..][0..s.len], s);
    const padded = std.mem.alignForward(usize, s.len + 1, 4);
    @memset(buf[4 + s.len .. 4 + padded], 0);
    return buf[0 .. 4 + padded];
}

test "text-input-v3 events become key-like text and preedit" {
    const t = std.testing;
    var win = Window{ .alloc = t.allocator, .conn = undefined };
    defer win.queue.deinit(t.allocator);
    var buf: [128]u8 = undefined;

    // preedit "n" (composition in progress), applied on done
    var r = wl.ArgReader{ .data = testWireString(&buf, "ñ") };
    try win.handleTextInput(wl.zwp_text_input_v3.ev_preedit_string, &r);
    try t.expectEqual(@as(usize, 0), win.queue.items.len); // nothing before done
    r = .{ .data = &[_]u8{ 1, 0, 0, 0 } };
    try win.handleTextInput(wl.zwp_text_input_v3.ev_done, &r);
    try t.expectEqualStrings("ñ", win.preedit());
    try t.expectEqual(@as(usize, 1), win.queue.items.len);
    const pe = win.queue.items[0].key;
    try t.expect(pe.preedit and !pe.pressed and pe.code == 0 and pe.text_len == 0);
    win.queue.clearRetainingCapacity();

    // commit a long string: split at character boundaries, preedit cleared
    const long = "¿Qué tal, señor? ñandú €€€";
    r = .{ .data = testWireString(&buf, long) };
    try win.handleTextInput(wl.zwp_text_input_v3.ev_commit_string, &r);
    r = .{ .data = &[_]u8{ 2, 0, 0, 0 } };
    try win.handleTextInput(wl.zwp_text_input_v3.ev_done, &r);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(t.allocator);
    var saw_preedit_clear = false;
    for (win.queue.items) |ev| {
        const k = ev.key;
        try t.expectEqual(@as(u32, 0), k.code);
        if (k.preedit) {
            saw_preedit_clear = true;
            continue;
        }
        try t.expect(k.pressed);
        try t.expect(std.unicode.utf8ValidateSlice(k.text()));
        try joined.appendSlice(t.allocator, k.text());
    }
    try t.expectEqualStrings(long, joined.items);
    try t.expect(saw_preedit_clear);
    try t.expectEqualStrings("", win.preedit());

    // malformed payload is an error, not a crash
    r = .{ .data = &[_]u8{ 9, 0, 0, 0, 'x' } };
    try t.expectError(error.Malformed, win.handleTextInput(wl.zwp_text_input_v3.ev_commit_string, &r));
}
