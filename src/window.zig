//! Fullscreen software-rendered window on top of the raw Wayland client:
//! registry/global management, shm double buffering, pointer/keyboard input,
//! custom cursors and clipboard ownership.

const std = @import("std");
const sys = @import("sys.zig");
const wl = @import("wayland.zig");
const render = @import("render.zig");

pub const InputEvent = union(enum) {
    pointer_motion: struct { x: f64, y: f64 },
    pointer_button: struct { button: u32, pressed: bool, x: f64, y: f64 },
    /// vertical scroll, positive = down
    pointer_axis: struct { value: f64 },
    key: struct { code: u32, pressed: bool, ctrl: bool, shift: bool },
    /// buffer was (re)created at this pixel size; caller must redraw
    resize: struct { w: u32, h: u32 },
    close,
    frame_done,
};

pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

// evdev key codes (linux/input-event-codes.h)
pub const KEY_ESC: u32 = 1;
pub const KEY_ENTER: u32 = 28;
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_SPACE: u32 = 57;
pub const KEY_DELETE: u32 = 111;
pub const KEY_LEFTCTRL: u32 = 29;
pub const KEY_RIGHTCTRL: u32 = 97;
pub const KEY_LEFTSHIFT: u32 = 42;
pub const KEY_RIGHTSHIFT: u32 = 54;

const Buffer = struct {
    id: u32 = 0,
    busy: bool = false,
    pixels: []align(std.heap.page_size_min) u8 = &.{},
};

pub const Cursor = enum { crosshair, arrow, move, text, resize_nwse, resize_nesw, resize_ns, resize_ew };

pub const Window = struct {
    alloc: std.mem.Allocator,
    conn: wl.Connection,

    // globals
    registry: u32 = 0,
    compositor: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    ddm: u32 = 0, // wl_data_device_manager
    viewporter: u32 = 0,
    fs_manager: u32 = 0, // wp_fractional_scale_manager_v1

    // window objects
    surface: u32 = 0,
    xdg_surf: u32 = 0,
    toplevel: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    data_device: u32 = 0,
    viewport: u32 = 0,
    fs_obj: u32 = 0, // wp_fractional_scale_v1
    scale120: u32 = 120, // fractional scale numerator (120 = 1.0)
    logical_w: u32 = 0,
    logical_h: u32 = 0,

    // shm
    pool: u32 = 0,
    pool_fd: sys.fd_t = -1,
    pool_mem: []align(std.heap.page_size_min) u8 = &.{},
    buffers: [2]Buffer = .{ .{}, .{} },
    cur_buf: usize = 0,

    // state
    width: u32 = 0, // buffer pixels
    height: u32 = 0,
    scale: u32 = 1,
    pending_w: u32 = 0, // from xdg_toplevel.configure (surface coords)
    pending_h: u32 = 0,
    default_w: u32 = 800, // used when the compositor lets the client decide
    default_h: u32 = 500,
    bounds_w: u32 = 0, // from xdg_toplevel.configure_bounds (logical)
    bounds_h: u32 = 0,
    maximized: bool = false,
    configured: bool = false,
    frame_pending: bool = false,
    frame_cb: u32 = 0,

    // input state
    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    ctrl: bool = false,
    shift: bool = false,
    enter_serial: u32 = 0,
    input_serial: u32 = 0, // last button/key serial, for set_selection

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

        self.registry = try self.conn.getRegistry();
        const done = try self.conn.sync();
        // collect globals until sync callback fires
        var synced = false;
        while (!synced) {
            const ev = try self.conn.readEvent();
            if (ev.object == done and ev.opcode == wl.wl_callback.ev_done) {
                synced = true;
            } else if (ev.object == self.registry and ev.opcode == wl.wl_registry.ev_global) {
                var r = wl.ArgReader{ .data = ev.body };
                const name = r.uint();
                const iface = r.string();
                const version = r.uint();
                try self.handleGlobal(name, iface, version);
            }
        }
        if (self.compositor == 0 or self.shm == 0 or self.wm_base == 0)
            return error.MissingGlobals;
        return self;
    }

    fn handleGlobal(self: *Window, name: u32, iface: []const u8, version: u32) !void {
        const eql = std.mem.eql;
        if (eql(u8, iface, "wl_compositor")) {
            self.compositor = try self.conn.bind(self.registry, name, iface, @min(version, 4));
        } else if (eql(u8, iface, "wl_shm")) {
            self.shm = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wl_seat") and self.seat == 0) {
            self.seat = try self.conn.bind(self.registry, name, iface, @min(version, 5));
        } else if (eql(u8, iface, "wl_data_device_manager")) {
            self.ddm = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wp_viewporter")) {
            self.viewporter = try self.conn.bind(self.registry, name, iface, 1);
        } else if (eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            self.fs_manager = try self.conn.bind(self.registry, name, iface, 1);
        }
    }

    pub fn deinit(self: *Window) void {
        self.destroyPool();
        if (self.cursor_pool_mem.len > 0) sys.munmap(self.cursor_pool_mem);
        self.queue.deinit(self.alloc);
        self.conn.deinit();
    }

    pub const OpenOptions = struct {
        fullscreen: bool = true,
        /// fallback size when the compositor lets the client decide
        width: u32 = 800,
        height: u32 = 500,
    };

    /// Create the toplevel; returns after the first configure, with buffers
    /// allocated (a .resize event will be queued).
    pub fn open(self: *Window, title: []const u8, opts: OpenOptions) !void {
        self.default_w = opts.width;
        self.default_h = opts.height;
        const c = &self.conn;
        self.surface = c.newId();
        try c.request(self.compositor, wl.wl_compositor.create_surface, &.{.{ .new_id = self.surface }});
        if (self.viewporter != 0 and self.fs_manager != 0) {
            self.viewport = c.newId();
            try c.request(self.viewporter, wl.wp_viewporter.get_viewport, &.{ .{ .new_id = self.viewport }, .{ .object = self.surface } });
            self.fs_obj = c.newId();
            try c.request(self.fs_manager, wl.wp_fractional_scale_manager_v1.get_fractional_scale, &.{ .{ .new_id = self.fs_obj }, .{ .object = self.surface } });
        }
        self.xdg_surf = c.newId();
        try c.request(self.wm_base, wl.xdg_wm_base.get_xdg_surface, &.{ .{ .new_id = self.xdg_surf }, .{ .object = self.surface } });
        self.toplevel = c.newId();
        try c.request(self.xdg_surf, wl.xdg_surface.get_toplevel, &.{.{ .new_id = self.toplevel }});
        try c.request(self.toplevel, wl.xdg_toplevel.set_app_id, &.{.{ .string = "cliptux" }});
        try c.request(self.toplevel, wl.xdg_toplevel.set_title, &.{.{ .string = title }});
        if (opts.fullscreen) {
            try c.request(self.toplevel, wl.xdg_toplevel.set_fullscreen, &.{.{ .object = 0 }});
        }
        try c.request(self.surface, wl.wl_surface.commit, &.{});

        if (self.seat != 0) {
            self.pointer = c.newId();
            try c.request(self.seat, wl.wl_seat.get_pointer, &.{.{ .new_id = self.pointer }});
            self.keyboard = c.newId();
            try c.request(self.seat, wl.wl_seat.get_keyboard, &.{.{ .new_id = self.keyboard }});
        }
        if (self.ddm != 0 and self.seat != 0) {
            self.data_device = c.newId();
            try c.request(self.ddm, wl.wl_data_device_manager.get_data_device, &.{ .{ .new_id = self.data_device }, .{ .object = self.seat } });
        }
        try self.initCursors();

        // wait for initial configure
        while (!self.configured) {
            try self.dispatchOne();
        }
    }

    fn destroyPool(self: *Window) void {
        const c = &self.conn;
        for (&self.buffers) |*b| {
            if (b.id != 0) {
                c.request(b.id, wl.wl_buffer.destroy, &.{}) catch {};
                b.* = .{};
            }
        }
        if (self.pool != 0) {
            c.request(self.pool, wl.wl_shm_pool.destroy, &.{}) catch {};
            self.pool = 0;
        }
        if (self.pool_mem.len > 0) {
            sys.munmap(self.pool_mem);
            self.pool_mem = &.{};
        }
        if (self.pool_fd >= 0) {
            sys.close(self.pool_fd);
            self.pool_fd = -1;
        }
    }

    fn createBuffers(self: *Window, w: u32, h: u32) !void {
        self.destroyPool();
        const stride = w * 4;
        const buf_size: usize = @as(usize, stride) * h;
        const total = buf_size * 2;

        self.pool_fd = try sys.memfdCreate("cliptux-shm", sys.MFD_CLOEXEC);
        try sys.ftruncate(self.pool_fd, total);
        self.pool_mem = try sys.mmapRw(self.pool_fd, total);

        const c = &self.conn;
        self.pool = c.newId();
        try c.request(self.shm, wl.wl_shm.create_pool, &.{
            .{ .new_id = self.pool },
            .{ .fd = self.pool_fd },
            .{ .int = @intCast(total) },
        });
        for (&self.buffers, 0..) |*b, i| {
            b.id = c.newId();
            b.busy = false;
            b.pixels = @alignCast(self.pool_mem[i * buf_size ..][0..buf_size]);
            try c.request(self.pool, wl.wl_shm_pool.create_buffer, &.{
                .{ .new_id = b.id },
                .{ .int = @intCast(i * buf_size) },
                .{ .int = @intCast(w) },
                .{ .int = @intCast(h) },
                .{ .int = @intCast(stride) },
                .{ .uint = wl.wl_shm.format_xrgb8888 },
            });
        }
        self.width = w;
        self.height = h;
        try c.flush(); // send while pool_fd is guaranteed open
        try self.queue.append(self.alloc, .{ .resize = .{ .w = w, .h = h } });
    }

    /// Recompute the physical buffer size from logical size and fractional
    /// scale, recreate buffers if needed, and pin the viewport destination.
    fn applySize(self: *Window) !void {
        if (self.logical_w == 0 or self.logical_h == 0) return;
        const w = (self.logical_w * self.scale120 + 60) / 120;
        const h = (self.logical_h * self.scale120 + 60) / 120;
        if (w == 0 or h == 0) return;
        if (w != self.width or h != self.height or self.pool == 0) {
            try self.createBuffers(w, h);
        }
        if (self.viewport != 0) {
            try self.conn.request(self.viewport, wl.wp_viewport.set_destination, &.{
                .{ .int = @intCast(self.logical_w) },
                .{ .int = @intCast(self.logical_h) },
            });
        }
    }

    /// Returns a drawable back buffer as u32 pixels (0xAARRGGBB).
    /// Blocks until a buffer is free if both are busy.
    pub fn backBuffer(self: *Window) ![]u32 {
        var tries: usize = 0;
        while (self.buffers[self.cur_buf].busy) {
            if (!self.buffers[1 - self.cur_buf].busy) {
                self.cur_buf = 1 - self.cur_buf;
                break;
            }
            try self.dispatchOne();
            tries += 1;
            if (tries > 1000) return error.BuffersStuck;
        }
        const b = &self.buffers[self.cur_buf];
        return @as([*]u32, @ptrCast(b.pixels.ptr))[0 .. b.pixels.len / 4];
    }

    /// Attach + commit the current back buffer.
    pub fn present(self: *Window) !void {
        const c = &self.conn;
        const b = &self.buffers[self.cur_buf];
        try c.request(self.surface, wl.wl_surface.attach, &.{ .{ .object = b.id }, .{ .int = 0 }, .{ .int = 0 } });
        try c.request(self.surface, wl.wl_surface.damage_buffer, &.{
            .{ .int = 0 },                    .{ .int = 0 },
            .{ .int = @intCast(self.width) }, .{ .int = @intCast(self.height) },
        });
        if (!self.frame_pending) {
            self.frame_cb = c.newId();
            try c.request(self.surface, wl.wl_surface.frame, &.{.{ .new_id = self.frame_cb }});
            self.frame_pending = true;
        }
        try c.request(self.surface, wl.wl_surface.commit, &.{});
        try c.flush();
        b.busy = true;
        self.cur_buf = 1 - self.cur_buf;
    }

    /// Blocking: next logical input event.
    pub fn nextEvent(self: *Window) !InputEvent {
        while (self.queue.items.len == 0) {
            try self.dispatchOne();
        }
        return self.queue.orderedRemove(0);
    }

    /// Like nextEvent but returns null after timeout_ms with no events.
    pub fn nextEventTimeout(self: *Window, timeout_ms: i32) !?InputEvent {
        while (self.queue.items.len == 0) {
            try self.conn.flush();
            if (self.conn.pollEvent()) |ev| {
                try self.handleEvent(ev);
                continue;
            }
            var fds = [_]sys.pollfd{.{ .fd = self.conn.fd, .events = sys.POLL.IN, .revents = 0 }};
            const n = try sys.poll(&fds, timeout_ms);
            if (n == 0) return null;
            try self.dispatchOne();
        }
        return self.queue.orderedRemove(0);
    }

    fn dispatchOne(self: *Window) !void {
        const ev = try self.conn.readEvent();
        try self.handleEvent(ev);
    }

    fn handleEvent(self: *Window, ev: wl.Event) !void {
        const c = &self.conn;
        var r = wl.ArgReader{ .data = ev.body };

        if (ev.object == wl.wl_display.id) {
            switch (ev.opcode) {
                wl.wl_display.ev_error => {
                    const obj = r.uint();
                    const code = r.uint();
                    const msg = r.string();
                    std.log.err("wayland protocol error on object {d} code {d}: {s}", .{ obj, code, msg });
                    return error.ProtocolError;
                },
                else => {}, // delete_id: ids are not recycled
            }
        } else if (ev.object == self.wm_base and ev.opcode == wl.xdg_wm_base.ev_ping) {
            const serial = r.uint();
            try c.request(self.wm_base, wl.xdg_wm_base.pong, &.{.{ .uint = serial }});
            try c.flush();
        } else if (ev.object == self.toplevel) {
            switch (ev.opcode) {
                wl.xdg_toplevel.ev_configure => {
                    const w_ = r.int();
                    const h_ = r.int();
                    self.pending_w = @intCast(@max(0, w_));
                    self.pending_h = @intCast(@max(0, h_));
                    self.maximized = false;
                    const states = r.array();
                    var si: usize = 0;
                    while (si + 4 <= states.len) : (si += 4) {
                        const st = std.mem.readInt(u32, states[si..][0..4], .little);
                        if (st == wl.xdg_toplevel.state_maximized) self.maximized = true;
                    }
                },
                wl.xdg_toplevel.ev_close => try self.queue.append(self.alloc, .close),
                2 => { // configure_bounds
                    self.bounds_w = @intCast(@max(0, r.int()));
                    self.bounds_h = @intCast(@max(0, r.int()));
                },
                else => {},
            }
        } else if (ev.object == self.xdg_surf and ev.opcode == wl.xdg_surface.ev_configure) {
            const serial = r.uint();
            try c.request(self.xdg_surf, wl.xdg_surface.ack_configure, &.{.{ .uint = serial }});
            var want_w = if (self.pending_w > 0) self.pending_w else if (self.logical_w > 0) self.logical_w else self.default_w;
            var want_h = if (self.pending_h > 0) self.pending_h else if (self.logical_h > 0) self.logical_h else self.default_h;
            // respect compositor bounds for client-decided sizes
            if (self.pending_w == 0 and self.bounds_w > 0) want_w = @min(want_w, self.bounds_w);
            if (self.pending_h == 0 and self.bounds_h > 0) want_h = @min(want_h, self.bounds_h - @min(self.bounds_h / 20, 40));
            self.logical_w = want_w;
            self.logical_h = want_h;
            try self.applySize();
            self.configured = true;
            try c.flush();
        } else if (ev.object != 0 and ev.object == self.fs_obj and ev.opcode == wl.wp_fractional_scale_v1.ev_preferred_scale) {
            const new_scale = r.uint();
            if (new_scale != self.scale120 and new_scale > 0) {
                self.scale120 = new_scale;
                if (self.configured) {
                    try self.applySize();
                    try c.flush();
                }
            }
        } else if (ev.object == self.frame_cb and ev.opcode == wl.wl_callback.ev_done) {
            self.frame_pending = false;
            try self.queue.append(self.alloc, .frame_done);
        } else if (ev.object == self.pointer) {
            try self.handlePointer(ev.opcode, &r);
        } else if (ev.object == self.keyboard) {
            try self.handleKeyboard(ev.opcode, &r);
        } else if (ev.object != 0 and ev.object == self.buffers[0].id and ev.opcode == wl.wl_buffer.ev_release) {
            self.buffers[0].busy = false;
        } else if (ev.object != 0 and ev.object == self.buffers[1].id and ev.opcode == wl.wl_buffer.ev_release) {
            self.buffers[1].busy = false;
        }
        // unknown objects/opcodes are skipped (header carries the size)
    }

    fn handlePointer(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_pointer.ev_enter => {
                self.enter_serial = r.uint();
                _ = r.uint(); // surface
                const f = self.pointerScale();
                self.ptr_x = r.fixed() * f;
                self.ptr_y = r.fixed() * f;
                try self.applyCursor();
            },
            wl.wl_pointer.ev_motion => {
                _ = r.uint(); // time
                const f = self.pointerScale();
                self.ptr_x = r.fixed() * f;
                self.ptr_y = r.fixed() * f;
                try self.queue.append(self.alloc, .{ .pointer_motion = .{ .x = self.ptr_x, .y = self.ptr_y } });
            },
            wl.wl_pointer.ev_button => {
                const serial = r.uint();
                _ = r.uint(); // time
                const button = r.uint();
                const state = r.uint();
                self.input_serial = serial;
                try self.queue.append(self.alloc, .{ .pointer_button = .{
                    .button = button,
                    .pressed = state == 1,
                    .x = self.ptr_x,
                    .y = self.ptr_y,
                } });
            },
            wl.wl_pointer.ev_axis => {
                _ = r.uint(); // time
                const axis = r.uint();
                const value = r.fixed();
                if (axis == 0) { // vertical
                    try self.queue.append(self.alloc, .{ .pointer_axis = .{ .value = value } });
                }
            },
            else => {},
        }
    }

    fn pointerScale(self: *const Window) f64 {
        return @as(f64, @floatFromInt(self.scale120)) / 120.0;
    }

    fn handleKeyboard(self: *Window, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.wl_keyboard.ev_keymap => {
                // we use raw evdev codes; just close the keymap fd
                if (self.conn.takeFd()) |fd| sys.close(fd);
            },
            wl.wl_keyboard.ev_key => {
                const serial = r.uint();
                _ = r.uint(); // time
                const code = r.uint();
                const state = r.uint();
                self.input_serial = serial;
                switch (code) {
                    KEY_LEFTCTRL, KEY_RIGHTCTRL => self.ctrl = state == 1,
                    KEY_LEFTSHIFT, KEY_RIGHTSHIFT => self.shift = state == 1,
                    else => {},
                }
                try self.queue.append(self.alloc, .{ .key = .{
                    .code = code,
                    .pressed = state == 1,
                    .ctrl = self.ctrl,
                    .shift = self.shift,
                } });
            },
            wl.wl_keyboard.ev_modifiers => {
                _ = r.uint(); // serial
                const depressed = r.uint();
                // conventional xkb modifier bit positions
                self.ctrl = (depressed & (1 << 2)) != 0;
                self.shift = (depressed & (1 << 0)) != 0;
            },
            wl.wl_keyboard.ev_enter => {
                self.input_serial = r.uint();
            },
            else => {},
        }
    }

    // --- cursors ---

    const cursor_size = 27;

    fn initCursors(self: *Window) !void {
        const c = &self.conn;
        const buf_size: usize = cursor_size * cursor_size * 4;
        const total = buf_size * self.cursor_buffers.len;
        const fd = try sys.memfdCreate("cliptux-cursor", sys.MFD_CLOEXEC);
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
            drawCursor(@as(Cursor, @enumFromInt(i)), pixels);
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
        const idx: usize = @intFromEnum(self.current_cursor);
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
        if (self.seat == 0 or self.toplevel == 0) return;
        try self.conn.request(self.toplevel, wl.xdg_toplevel.move, &.{
            .{ .object = self.seat },
            .{ .uint = self.input_serial },
        });
        try self.conn.flush();
    }

    pub fn toggleMaximize(self: *Window) !void {
        const op: u16 = if (self.maximized) wl.xdg_toplevel.unset_maximized else wl.xdg_toplevel.set_maximized;
        try self.conn.request(self.toplevel, op, &.{});
        try self.conn.flush();
    }

    pub fn minimize(self: *Window) !void {
        try self.conn.request(self.toplevel, wl.xdg_toplevel.set_minimized, &.{});
        try self.conn.flush();
    }

    /// Destroy the visible window (keeps the connection alive so an offered
    /// clipboard selection can still be served).
    pub fn closeWindow(self: *Window) void {
        const c = &self.conn;
        if (self.toplevel != 0) c.request(self.toplevel, wl.xdg_toplevel.destroy, &.{}) catch {};
        if (self.xdg_surf != 0) c.request(self.xdg_surf, wl.xdg_surface.destroy, &.{}) catch {};
        if (self.surface != 0) c.request(self.surface, wl.wl_surface.destroy, &.{}) catch {};
        self.toplevel = 0;
        self.xdg_surf = 0;
        self.surface = 0;
        c.flush() catch {};
    }

    /// Claim the clipboard selection with an image/png data source.
    /// Call while the window still has focus (serial must be fresh).
    pub fn claimClipboardPng(self: *Window) !u32 {
        if (self.ddm == 0 or self.data_device == 0) return error.NoDataDevice;
        const c = &self.conn;
        const source = c.newId();
        try c.request(self.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
        try c.request(source, wl.wl_data_source.offer, &.{.{ .string = "image/png" }});
        try c.request(self.data_device, wl.wl_data_device.set_selection, &.{ .{ .object = source }, .{ .uint = self.input_serial } });
        try c.flush();
        return source;
    }

    /// Serve clipboard reads until another client replaces the selection.
    /// Blocks; safe to call after closeWindow().
    pub fn serveClipboard(self: *Window, source: u32, data: []const u8) !void {
        const c = &self.conn;
        while (true) {
            const ev = try self.conn.readEvent();
            if (ev.object == source) {
                var r = wl.ArgReader{ .data = ev.body };
                switch (ev.opcode) {
                    wl.wl_data_source.ev_send => {
                        _ = r.string(); // mime
                        if (self.conn.takeFd()) |fd| {
                            sys.writeAll(fd, data) catch {};
                            sys.close(fd);
                        }
                    },
                    wl.wl_data_source.ev_cancelled => {
                        try c.request(source, wl.wl_data_source.destroy, &.{});
                        try c.flush();
                        return;
                    },
                    else => {},
                }
            } else {
                try self.handleEvent(ev);
                self.queue.clearRetainingCapacity();
            }
        }
    }
};
