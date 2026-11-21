//! Native Wayland client: speaks the wire protocol directly over the
//! compositor's unix socket. No libwayland. Little-endian only.
//!
//! Message format: u32 object id, u32 (size << 16 | opcode), then args.
//! File descriptors travel out-of-band via SCM_RIGHTS.

const std = @import("std");
const sys = @import("sys.zig");

// --- interface opcodes (from wayland.xml / xdg-shell.xml) ---

pub const wl_display = struct {
    pub const id: u32 = 1;
    // requests
    pub const sync = 0;
    pub const get_registry = 1;
    // events
    pub const ev_error = 0;
    pub const ev_delete_id = 1;
};

pub const wl_registry = struct {
    pub const bind = 0;
    pub const ev_global = 0;
    pub const ev_global_remove = 1;
};

pub const wl_callback = struct {
    pub const ev_done = 0;
};

pub const wl_compositor = struct {
    pub const create_surface = 0;
    pub const create_region = 1;
};

pub const wl_region = struct {
    pub const destroy = 0;
    pub const add = 1;
    pub const subtract = 2;
};

pub const wl_shm = struct {
    pub const create_pool = 0;
    pub const ev_format = 0;
    pub const format_argb8888: u32 = 0;
    pub const format_xrgb8888: u32 = 1;
};

pub const wl_shm_pool = struct {
    pub const create_buffer = 0;
    pub const destroy = 1;
};

pub const wl_buffer = struct {
    pub const destroy = 0;
    pub const ev_release = 0;
};

pub const wl_surface = struct {
    pub const destroy = 0;
    pub const attach = 1;
    pub const damage = 2;
    pub const frame = 3;
    pub const set_opaque_region = 4;
    pub const set_input_region = 5;
    pub const commit = 6;
    pub const set_buffer_scale = 8;
    pub const damage_buffer = 9;
    pub const offset = 10; // since v5
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_preferred_buffer_scale = 2;
};

pub const wl_seat = struct {
    pub const get_pointer = 0;
    pub const get_keyboard = 1;
    pub const ev_capabilities = 0;
    pub const ev_name = 1;
    pub const cap_pointer: u32 = 1;
    pub const cap_keyboard: u32 = 2;
};

pub const wl_pointer = struct {
    pub const set_cursor = 0;
    pub const release = 1; // since v3
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_motion = 2;
    pub const ev_button = 3;
    pub const ev_axis = 4;
    pub const ev_frame = 5;
    pub const ev_axis_value120 = 9; // since v8
};

pub const wl_keyboard = struct {
    pub const release = 0; // since v3
    pub const ev_keymap = 0;
    pub const ev_enter = 1;
    pub const ev_leave = 2;
    pub const ev_key = 3;
    pub const ev_modifiers = 4;
    pub const ev_repeat_info = 5;
};

pub const wl_output = struct {
    pub const release = 0; // since v3
    pub const ev_geometry = 0;
    pub const ev_mode = 1;
    pub const ev_done = 2; // since v2
    pub const ev_scale = 3; // since v2
    pub const ev_name = 4; // since v4
    pub const ev_description = 5; // since v4
    pub const mode_current: u32 = 1;
};

pub const zxdg_output_manager_v1 = struct {
    pub const destroy = 0;
    pub const get_xdg_output = 1;
};

pub const zxdg_output_v1 = struct {
    pub const destroy = 0;
    pub const ev_logical_position = 0;
    pub const ev_logical_size = 1;
    pub const ev_done = 2;
    pub const ev_name = 3; // since v2
    pub const ev_description = 4; // since v2
};

pub const zwp_text_input_manager_v3 = struct {
    pub const destroy = 0;
    pub const get_text_input = 1;
};

pub const zwp_text_input_v3 = struct {
    pub const destroy = 0;
    pub const enable = 1;
    pub const disable = 2;
    pub const set_surrounding_text = 3;
    pub const set_text_change_cause = 4;
    pub const set_content_type = 5;
    pub const set_cursor_rectangle = 6;
    pub const commit = 7;
    pub const ev_enter = 0;
    pub const ev_leave = 1;
    pub const ev_preedit_string = 2;
    pub const ev_commit_string = 3;
    pub const ev_delete_surrounding_text = 4;
    pub const ev_done = 5;
};

pub const xdg_wm_base = struct {
    pub const create_positioner = 1;
    pub const get_xdg_surface = 2;
    pub const pong = 3;
    pub const ev_ping = 0;
};

pub const xdg_surface = struct {
    pub const destroy = 0;
    pub const get_toplevel = 1;
    pub const set_window_geometry = 3;
    pub const ack_configure = 4;
    pub const ev_configure = 0;
};

pub const xdg_toplevel = struct {
    pub const destroy = 0;
    pub const set_title = 2;
    pub const set_app_id = 3;
    pub const set_parent = 1;
    pub const show_window_menu = 4;
    pub const move = 5;
    pub const set_max_size = 7;
    pub const set_min_size = 8;
    pub const set_maximized = 9;
    pub const unset_maximized = 10;
    pub const set_fullscreen = 11;
    pub const set_minimized = 13;
    pub const ev_configure = 0;
    pub const ev_close = 1;
    pub const ev_configure_bounds = 2;
    pub const state_maximized: u32 = 1;
};

/// wlr-layer-shell-unstable-v1 (KDE, wlroots compositors; not mutter)
pub const zwlr_layer_shell_v1 = struct {
    pub const get_layer_surface = 0;
    pub const layer_bottom: u32 = 1;
    pub const layer_top: u32 = 2;
    pub const layer_overlay: u32 = 3;
};

pub const zwlr_layer_surface_v1 = struct {
    pub const set_size = 0;
    pub const set_anchor = 1;
    pub const set_exclusive_zone = 2;
    pub const set_margin = 3;
    pub const set_keyboard_interactivity = 4;
    pub const ack_configure = 6;
    pub const destroy = 7;
    pub const ev_configure = 0;
    pub const ev_closed = 1;
    pub const anchor_top: u32 = 1;
    pub const anchor_bottom: u32 = 2;
    pub const anchor_left: u32 = 4;
    pub const anchor_right: u32 = 8;
    pub const keyboard_none: u32 = 0;
    pub const keyboard_exclusive: u32 = 1;
    pub const keyboard_on_demand: u32 = 2; // since v4
};

pub const wp_viewporter = struct {
    pub const get_viewport = 1;
};

pub const wp_viewport = struct {
    pub const destroy = 0;
    pub const set_destination = 2;
};

pub const wp_fractional_scale_manager_v1 = struct {
    pub const get_fractional_scale = 1;
};

pub const wp_fractional_scale_v1 = struct {
    pub const ev_preferred_scale = 0;
};

pub const wl_data_device_manager = struct {
    pub const create_data_source = 0;
    pub const get_data_device = 1;
};

pub const wl_data_source = struct {
    pub const offer = 0;
    pub const destroy = 1;
    pub const set_actions = 2; // since v3
    pub const ev_target = 0;
    pub const ev_send = 1;
    pub const ev_cancelled = 2;
    pub const ev_dnd_drop_performed = 3; // since v3
    pub const ev_dnd_finished = 4; // since v3
    pub const ev_action = 5; // since v3
};

pub const wl_data_device = struct {
    pub const start_drag = 0;
    pub const set_selection = 1;
    pub const ev_data_offer = 0;
    pub const ev_enter = 1;
    pub const ev_leave = 2;
    pub const ev_motion = 3;
    pub const ev_drop = 4;
    pub const ev_selection = 5;
};

/// wl_data_device_manager.dnd_action bits
pub const dnd_action_copy: u32 = 1;
pub const dnd_action_move: u32 = 2;

pub const wl_data_offer = struct {
    pub const accept = 0;
    pub const receive = 1;
    pub const destroy = 2;
    pub const finish = 3; // since v3
    pub const set_actions = 4; // since v3
    pub const ev_offer = 0;
};

// --- marshaling helper types ---

/// Argument value for requests.
pub const Arg = union(enum) {
    uint: u32,
    int: i32,
    fixed: f64, // converted to 24.8
    string: []const u8,
    /// a null string (length 0 on the wire)
    null_string: void,
    object: u32, // 0 for null
    new_id: u32,
    fd: i32, // sent via SCM_RIGHTS
    array: []const u8,
};

pub const Event = struct {
    object: u32,
    opcode: u16,
    /// argument payload; valid until the next readEvent call
    body: []const u8,
};

/// Sequential decoder for event arguments. Every accessor is bounds
/// checked: a short or malformed payload yields error.Malformed instead of
/// reading past the message.
pub const ArgReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub const Error = error{Malformed};

    pub fn uint(self: *ArgReader) Error!u32 {
        if (self.data.len < 4 or self.pos > self.data.len - 4) return error.Malformed;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
    }
    pub fn int(self: *ArgReader) Error!i32 {
        return @bitCast(try self.uint());
    }
    pub fn fixed(self: *ArgReader) Error!f64 {
        const raw: i32 = try self.int();
        return @as(f64, @floatFromInt(raw)) / 256.0;
    }
    /// Length-prefixed, NUL-terminated, padded to 4. A zero length is the
    /// null string and reads as "".
    pub fn string(self: *ArgReader) Error![]const u8 {
        const len = try self.uint(); // includes NUL
        if (len == 0) return "";
        const padded = std.mem.alignForward(usize, len, 4);
        if (padded > self.data.len - self.pos) return error.Malformed;
        const raw = self.data[self.pos..][0..len];
        if (raw[len - 1] != 0) return error.Malformed;
        const s = raw[0 .. len - 1];
        if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Malformed;
        self.pos += padded;
        return s;
    }
    pub fn array(self: *ArgReader) Error![]const u8 {
        const len = try self.uint();
        const padded = std.mem.alignForward(usize, len, 4);
        if (padded > self.data.len - self.pos) return error.Malformed;
        const s = self.data[self.pos..][0..len];
        self.pos += padded;
        return s;
    }
};

pub const Connection = struct {
    fd: sys.fd_t,
    alloc: std.mem.Allocator,
    next_id: u32 = 2, // 1 is wl_display
    buf: [128 * 1024]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    in_fds: std.ArrayList(sys.fd_t) = .empty,
    out: std.ArrayList(u8) = .empty,
    out_fds: std.ArrayList(sys.fd_t) = .empty,

    pub fn connect(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8) !Connection {
        var path_buf: [256]u8 = undefined;
        const path = if (display.len > 0 and display[0] == '/')
            display
        else
            try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ runtime_dir, display });

        const fd = try sys.socketUnixStream();
        errdefer sys.close(fd);
        try sys.connectUnix(fd, path);
        return .{ .fd = fd, .alloc = alloc };
    }

    pub fn deinit(self: *Connection) void {
        for (self.in_fds.items) |fd| sys.close(fd);
        self.in_fds.deinit(self.alloc);
        self.out.deinit(self.alloc);
        self.out_fds.deinit(self.alloc);
        sys.close(self.fd);
    }

    pub fn newId(self: *Connection) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    /// Queue a request; call flush() to send.
    pub fn request(self: *Connection, object: u32, opcode: u16, args: []const Arg) !void {
        var size: usize = 8;
        for (args) |a| size += switch (a) {
            .uint, .int, .object, .new_id, .null_string => 4,
            .fixed => 4,
            .fd => 0,
            .string => |s| 4 + std.mem.alignForward(usize, s.len + 1, 4),
            .array => |s| 4 + std.mem.alignForward(usize, s.len, 4),
        };

        if (size > 0xFFFF) return error.MessageTooLarge; // wire size field is u16
        const w = &self.out;
        try w.ensureUnusedCapacity(self.alloc, size);
        appendU32(w, self.alloc, object);
        appendU32(w, self.alloc, (@as(u32, @intCast(size)) << 16) | opcode);
        for (args) |a| switch (a) {
            .uint => |v| appendU32(w, self.alloc, v),
            .int => |v| appendU32(w, self.alloc, @bitCast(v)),
            .object, .new_id => |v| appendU32(w, self.alloc, v),
            .null_string => appendU32(w, self.alloc, 0),
            .fixed => |v| appendU32(w, self.alloc, @bitCast(@as(i32, @intFromFloat(v * 256.0)))),
            .fd => |fd| try self.out_fds.append(self.alloc, fd),
            .string => |s| {
                appendU32(w, self.alloc, @intCast(s.len + 1));
                w.appendSliceAssumeCapacity(s);
                const padded = std.mem.alignForward(usize, s.len + 1, 4);
                w.appendNTimesAssumeCapacity(0, padded - s.len);
            },
            .array => |s| {
                appendU32(w, self.alloc, @intCast(s.len));
                w.appendSliceAssumeCapacity(s);
                const padded = std.mem.alignForward(usize, s.len, 4);
                w.appendNTimesAssumeCapacity(0, padded - s.len);
            },
        };
    }

    fn appendU32(w: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) void {
        _ = alloc;
        w.appendSliceAssumeCapacity(std.mem.asBytes(&v));
    }

    pub fn flush(self: *Connection) !void {
        if (self.out.items.len == 0) return;
        var sent: usize = 0;
        var fds_sent = false;
        while (sent < self.out.items.len) {
            const fds: []const sys.fd_t = if (!fds_sent) self.out_fds.items else &.{};
            sent += try sys.sendWithFds(self.fd, self.out.items[sent..], fds);
            fds_sent = true;
        }
        self.out.clearRetainingCapacity();
        self.out_fds.clearRetainingCapacity();
    }

    /// Take the oldest received fd (for events that carry one, e.g. keymap).
    pub fn takeFd(self: *Connection) ?sys.fd_t {
        if (self.in_fds.items.len == 0) return null;
        return self.in_fds.orderedRemove(0);
    }

    /// Blocking: returns the next event. Flushes pending requests first.
    pub fn readEvent(self: *Connection) !Event {
        try self.flush();
        while (true) {
            if (try self.parseEvent()) |ev| return ev;
            // compact buffer
            if (self.buf_start > 0) {
                std.mem.copyForwards(u8, self.buf[0 .. self.buf_end - self.buf_start], self.buf[self.buf_start..self.buf_end]);
                self.buf_end -= self.buf_start;
                self.buf_start = 0;
            }
            const n = try sys.recvWithFds(self.fd, self.buf[self.buf_end..], &self.in_fds, self.alloc);
            if (n == 0) return error.Disconnected;
            self.buf_end += n;
        }
    }

    /// Non-blocking variant: returns null when no complete event is buffered.
    pub fn pollEvent(self: *Connection) !?Event {
        return self.parseEvent();
    }

    fn parseEvent(self: *Connection) !?Event {
        const ev = (try parseMessage(self.buf[self.buf_start..self.buf_end])) orelse return null;
        self.buf_start += ev.size;
        return ev.event;
    }

    // --- convenience wrappers ---
    // --- convenience wrappers ---

    pub fn sync(self: *Connection) !u32 {
        const cb = self.newId();
        try self.request(wl_display.id, wl_display.sync, &.{.{ .new_id = cb }});
        return cb;
    }

    pub fn getRegistry(self: *Connection) !u32 {
        const reg = self.newId();
        try self.request(wl_display.id, wl_display.get_registry, &.{.{ .new_id = reg }});
        return reg;
    }

    pub fn bind(self: *Connection, registry: u32, name: u32, interface: []const u8, version: u32) !u32 {
        const id = self.newId();
        try self.request(registry, wl_registry.bind, &.{
            .{ .uint = name },
            .{ .string = interface },
            .{ .uint = version },
            .{ .new_id = id },
        });
        return id;
    }
};

pub const Parsed = struct { event: Event, size: usize };

/// Decode one message header from `buf`. Returns null when the message is
/// not complete yet, error.Malformed when the header can never be valid
/// (a size below the 8-byte header or not a multiple of 4), so a corrupt
/// stream cannot spin the reader or index out of bounds.
pub fn parseMessage(buf: []const u8) error{Malformed}!?Parsed {
    if (buf.len < 8) return null;
    const object = std.mem.readInt(u32, buf[0..4], .little);
    const size_op = std.mem.readInt(u32, buf[4..8], .little);
    const size: usize = size_op >> 16;
    const opcode: u16 = @truncate(size_op);
    if (size < 8 or size % 4 != 0) return error.Malformed;
    if (buf.len < size) return null;
    return .{ .event = .{ .object = object, .opcode = opcode, .body = buf[8..size] }, .size = size };
}

test "arg reader strings" {
    // string "hi\x00" padded to 4: len=3
    const data = [_]u8{ 3, 0, 0, 0, 'h', 'i', 0, 0, 42, 0, 0, 0 };
    var r = ArgReader{ .data = &data };
    try std.testing.expectEqualStrings("hi", try r.string());
    try std.testing.expectEqual(@as(u32, 42), try r.uint());
    try std.testing.expectError(error.Malformed, r.uint());
}

test "arg reader rejects malformed payloads" {
    const E = error.Malformed;
    // short uint
    var r = ArgReader{ .data = &[_]u8{ 1, 2 } };
    try std.testing.expectError(E, r.uint());
    // string length past the end
    r = .{ .data = &[_]u8{ 200, 0, 0, 0, 'a', 'b', 0, 0 } };
    try std.testing.expectError(E, r.string());
    // string without its NUL terminator
    r = .{ .data = &[_]u8{ 3, 0, 0, 0, 'a', 'b', 'c', 0 } };
    try std.testing.expectError(E, r.string());
    // embedded NUL
    r = .{ .data = &[_]u8{ 4, 0, 0, 0, 'a', 0, 'c', 0 } };
    try std.testing.expectError(E, r.string());
    // padding runs past the end
    r = .{ .data = &[_]u8{ 2, 0, 0, 0, 'a', 0 } };
    try std.testing.expectError(E, r.string());
    // huge array length (would overflow naive pos + len)
    r = .{ .data = &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 } };
    try std.testing.expectError(E, r.array());
    // null string is fine
    r = .{ .data = &[_]u8{ 0, 0, 0, 0 } };
    try std.testing.expectEqualStrings("", try r.string());
    // valid array
    r = .{ .data = &[_]u8{ 2, 0, 0, 0, 7, 8, 0, 0 } };
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, try r.array());
}

test "message parser rejects bad sizes" {
    // size 0 used to loop forever
    try std.testing.expectError(error.Malformed, parseMessage(&[_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 }));
    // size 4 (< header) used to panic
    try std.testing.expectError(error.Malformed, parseMessage(&[_]u8{ 1, 0, 0, 0, 0, 0, 4, 0 }));
    // unaligned size
    try std.testing.expectError(error.Malformed, parseMessage(&[_]u8{ 1, 0, 0, 0, 0, 0, 10, 0, 0, 0 }));
    // incomplete header or body: wait for more
    try std.testing.expect((try parseMessage(&[_]u8{ 1, 0, 0 })) == null);
    try std.testing.expect((try parseMessage(&[_]u8{ 1, 0, 0, 0, 2, 0, 12, 0 })) == null);
    // complete message with a 4-byte body
    const ok = (try parseMessage(&[_]u8{ 1, 0, 0, 0, 2, 0, 12, 0, 9, 0, 0, 0, 0xEE })).?;
    try std.testing.expectEqual(@as(usize, 12), ok.size);
    try std.testing.expectEqual(@as(u16, 2), ok.event.opcode);
    try std.testing.expectEqual(@as(usize, 4), ok.event.body.len);
}
