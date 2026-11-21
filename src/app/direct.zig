//! Direct capture: the desktop's own screenshot interface, no consent
//! dialog, no PipeWire. Tried before the portal (app/shot.zig):
//!
//! - wlroots compositors (sway, labwc, Hyprland, river...):
//!   ext-image-copy-capture-v1 with output capture sources when offered,
//!   else zwlr_screencopy_v1 (what grim uses). Every output into wl_shm
//!   buffers, so no GPU is needed.
//! - KDE KWin: org.kde.KWin.ScreenShot2.CaptureScreen per output. KWin only
//!   answers apps whose installed .desktop file lists the interface in
//!   X-KDE-DBUS-Restricted-Interfaces, matched by the executable: the Exec
//!   of the installed file must be the binary that runs (install.sh).
//!
//! Each output's picture is turned upright (its transform) and placed by
//! its logical rectangle (xdg_output), then stitched like the portal's
//! streams.

const std = @import("std");
const capture = @import("capture.zig");
const dbus = @import("../platform/dbus.zig");
const sys = @import("../platform/sys.zig");
const wl = @import("../platform/wayland.zig");
const env_mod = @import("env.zig");

pub const Method = enum {
    ext_image_copy_capture,
    wlr_screencopy,
    kwin_screenshot,

    pub fn label(self: Method) []const u8 {
        return switch (self) {
            .ext_image_copy_capture => "ext-image-copy-capture",
            .wlr_screencopy => "wlr-screencopy",
            .kwin_screenshot => "KWin ScreenShot2",
        };
    }
};

pub const Result = union(enum) {
    captured: struct { cap: capture.Capture, method: Method },
    /// no direct interface here (or KWin refused this binary): use the portal
    unavailable: []const u8,
};

const max_outputs = 16;

const Output = struct {
    global: u32,
    version: u32,
    id: u32 = 0,
    xdg: u32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    transform: u32 = 0,
    scale: i32 = 1,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    geo_x: i32 = 0,
    geo_y: i32 = 0,
    lx: i32 = 0,
    ly: i32 = 0,
    lw: i32 = 0,
    lh: i32 = 0,
    has_logical: bool = false,

    fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn logical(self: *const Output) capture.Monitor.Logical {
        if (self.has_logical and self.lw > 0 and self.lh > 0)
            return .{ .x = self.lx, .y = self.ly, .w = @intCast(self.lw), .h = @intCast(self.lh) };
        const sc = @max(1, self.scale);
        const swap = self.transform & 1 != 0;
        const w = @divTrunc(if (swap) self.mode_h else self.mode_w, sc);
        const h = @divTrunc(if (swap) self.mode_w else self.mode_h, sc);
        return .{ .x = self.geo_x, .y = self.geo_y, .w = @intCast(@max(1, w)), .h = @intCast(@max(1, h)) };
    }
};

// protocol opcodes
const ext_source_mgr = struct {
    const create_source = 0;
    const destroy = 1;
};
const ext_source = struct {
    const destroy = 0;
};
const ext_copy_mgr = struct {
    const create_session = 0;
    const destroy = 2;
};
const ext_session = struct {
    const create_frame = 0;
    const destroy = 1;
    const ev_buffer_size = 0;
    const ev_shm_format = 1;
    const ev_done = 4;
    const ev_stopped = 5;
};
const ext_frame = struct {
    const destroy = 0;
    const attach_buffer = 1;
    const damage_buffer = 2;
    const capture_ = 3;
    const ev_transform = 0;
    const ev_ready = 3;
    const ev_failed = 4;
};
const screencopy_mgr = struct {
    const capture_output = 0;
    const destroy = 2;
};
const screencopy_frame = struct {
    const copy = 0;
    const destroy = 1;
    const ev_buffer = 0;
    const ev_flags = 1;
    const ev_ready = 2;
    const ev_failed = 3;
    const ev_buffer_done = 6;
};

const Client = struct {
    gpa: std.mem.Allocator,
    conn: wl.Connection,
    registry: u32 = 0,
    shm: u32 = 0,
    xdg_mgr: u32 = 0,
    ext_source_mgr: u32 = 0,
    ext_copy_mgr: u32 = 0,
    screencopy: u32 = 0,
    screencopy_version: u32 = 0,
    outputs: [max_outputs]Output = undefined,
    n_outputs: usize = 0,

    fn roundtrip(self: *Client) !void {
        const cb = try self.conn.sync();
        try self.conn.flush();
        while (true) {
            const ev = try self.conn.readEvent();
            if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) return;
            try self.handle(ev);
        }
    }

    fn handle(self: *Client, ev: wl.Event) !void {
        var r: wl.ArgReader = .{ .data = ev.body };
        if (ev.object == wl.wl_display.id and ev.opcode == wl.wl_display.ev_error) {
            _ = try r.uint();
            const code = try r.uint();
            std.log.info("direct capture: wayland error {d}: {s}", .{ code, try r.string() });
            return error.ProtocolError;
        }
        if (ev.object == self.registry and ev.opcode == wl.wl_registry.ev_global) {
            const gname = try r.uint();
            const iface = try r.string();
            const version = try r.uint();
            const eql = std.mem.eql;
            if (eql(u8, iface, "wl_output")) {
                if (self.n_outputs < max_outputs) {
                    self.outputs[self.n_outputs] = .{ .global = gname, .version = @min(version, 4) };
                    self.n_outputs += 1;
                }
            } else if (eql(u8, iface, "wl_shm")) {
                self.shm = try self.conn.bind(self.registry, gname, iface, 1);
            } else if (eql(u8, iface, "zxdg_output_manager_v1")) {
                self.xdg_mgr = try self.conn.bind(self.registry, gname, iface, @min(version, 3));
            } else if (eql(u8, iface, "ext_output_image_capture_source_manager_v1")) {
                self.ext_source_mgr = try self.conn.bind(self.registry, gname, iface, 1);
            } else if (eql(u8, iface, "ext_image_copy_capture_manager_v1")) {
                self.ext_copy_mgr = try self.conn.bind(self.registry, gname, iface, 1);
            } else if (eql(u8, iface, "zwlr_screencopy_manager_v1")) {
                self.screencopy_version = @min(version, 3);
                self.screencopy = try self.conn.bind(self.registry, gname, iface, self.screencopy_version);
            }
            return;
        }
        for (self.outputs[0..self.n_outputs]) |*o| {
            if (o.id != 0 and ev.object == o.id) {
                switch (ev.opcode) {
                    wl.wl_output.ev_geometry => {
                        o.geo_x = try r.int();
                        o.geo_y = try r.int();
                        _ = try r.int(); // physical size
                        _ = try r.int();
                        _ = try r.int(); // subpixel
                        _ = try r.string(); // make
                        _ = try r.string(); // model
                        o.transform = try r.uint() & 7;
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
                    wl.wl_output.ev_scale => o.scale = try r.int(),
                    wl.wl_output.ev_name => {
                        const n = try r.string();
                        o.name_len = @min(n.len, o.name_buf.len);
                        @memcpy(o.name_buf[0..o.name_len], n[0..o.name_len]);
                    },
                    else => {},
                }
                return;
            }
            if (o.xdg != 0 and ev.object == o.xdg) {
                switch (ev.opcode) {
                    wl.zxdg_output_v1.ev_logical_position => {
                        o.lx = try r.int();
                        o.ly = try r.int();
                        o.has_logical = true;
                    },
                    wl.zxdg_output_v1.ev_logical_size => {
                        o.lw = try r.int();
                        o.lh = try r.int();
                    },
                    wl.zxdg_output_v1.ev_name => if (o.name_len == 0) {
                        const n = try r.string();
                        o.name_len = @min(n.len, o.name_buf.len);
                        @memcpy(o.name_buf[0..o.name_len], n[0..o.name_len]);
                    },
                    else => {},
                }
                return;
            }
        }
    }

    /// Events for objects other than `obj` while waiting on it.
    fn next(self: *Client, obj: u32, deadline: i64) !wl.Event {
        while (true) {
            if (try self.conn.pollEvent()) |ev| {
                if (ev.object == obj) return ev;
                try self.handle(ev);
                continue;
            }
            try self.conn.flush();
            if (!try sys.waitReadable(self.conn.fd, deadline)) return error.Timeout;
            const ev = try self.conn.readEvent();
            if (ev.object == obj) return ev;
            try self.handle(ev);
        }
    }

    const Shm = struct {
        fd: sys.fd_t,
        mem: []align(std.heap.page_size_min) u8,
        buffer: u32,

        fn deinit(self: *Shm, c: *wl.Connection) void {
            c.request(self.buffer, wl.wl_buffer.destroy, &.{}) catch {};
            sys.munmap(self.mem);
            sys.close(self.fd);
        }
    };

    fn shmBuffer(self: *Client, format: u32, w: u32, h: u32, stride: u32) !Shm {
        const size = @as(usize, stride) * h;
        if (size == 0 or size > 1 << 30) return error.BadBufferSize;
        const fd = try sys.memfdCreate("shotlet-capture", sys.MFD_CLOEXEC);
        errdefer sys.close(fd);
        try sys.ftruncate(fd, size);
        const mem = try sys.mmapRw(fd, size);
        errdefer sys.munmap(mem);
        const c = &self.conn;
        const pool = c.newId();
        try c.request(self.shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
        const buffer = c.newId();
        try c.request(pool, wl.wl_shm_pool.create_buffer, &.{ .{ .new_id = buffer }, .{ .int = 0 }, .{ .int = @intCast(w) }, .{ .int = @intCast(h) }, .{ .int = @intCast(stride) }, .{ .uint = format } });
        try c.request(pool, wl.wl_shm_pool.destroy, &.{});
        return .{ .fd = fd, .mem = mem, .buffer = buffer };
    }

    /// One output with ext-image-copy-capture-v1.
    fn grabExt(self: *Client, o: *const Output) !Frame {
        const c = &self.conn;
        const deadline = sys.monoMs() + 5000;
        const source = c.newId();
        try c.request(self.ext_source_mgr, ext_source_mgr.create_source, &.{ .{ .new_id = source }, .{ .object = o.id } });
        defer c.request(source, ext_source.destroy, &.{}) catch {};
        const session = c.newId();
        try c.request(self.ext_copy_mgr, ext_copy_mgr.create_session, &.{ .{ .new_id = session }, .{ .object = source }, .{ .uint = 0 } });
        defer c.request(session, ext_session.destroy, &.{}) catch {};
        var w: u32 = 0;
        var h: u32 = 0;
        var format: ?u32 = null;
        while (true) {
            const ev = try self.next(session, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                ext_session.ev_buffer_size => {
                    w = try r.uint();
                    h = try r.uint();
                },
                ext_session.ev_shm_format => format = preferFormat(format, try r.uint()),
                ext_session.ev_stopped => return error.CaptureStopped,
                ext_session.ev_done => break,
                else => {},
            }
        }
        const fmt = format orelse return error.NoShmFormat;
        if (w == 0 or h == 0) return error.BadBufferSize;
        var shm = try self.shmBuffer(fmt, w, h, w * 4);
        defer shm.deinit(c);
        const frame = c.newId();
        try c.request(session, ext_session.create_frame, &.{.{ .new_id = frame }});
        defer c.request(frame, ext_frame.destroy, &.{}) catch {};
        try c.request(frame, ext_frame.attach_buffer, &.{.{ .object = shm.buffer }});
        try c.request(frame, ext_frame.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = @intCast(w) }, .{ .int = @intCast(h) } });
        try c.request(frame, ext_frame.capture_, &.{});
        var transform: u32 = 0;
        while (true) {
            const ev = try self.next(frame, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                ext_frame.ev_transform => transform = try r.uint() & 7,
                ext_frame.ev_failed => return error.CaptureFailed,
                ext_frame.ev_ready => break,
                else => {},
            }
        }
        return toFrame(self.gpa, shm.mem, fmt, w, h, w * 4, false, transform);
    }

    /// One output with zwlr_screencopy_v1.
    fn grabScreencopy(self: *Client, o: *const Output) !Frame {
        const c = &self.conn;
        const deadline = sys.monoMs() + 5000;
        const frame = c.newId();
        try c.request(self.screencopy, screencopy_mgr.capture_output, &.{ .{ .new_id = frame }, .{ .int = 0 }, .{ .object = o.id } });
        defer c.request(frame, screencopy_frame.destroy, &.{}) catch {};
        // format, width, height, stride of the best shm buffer offered
        var best: ?[4]u32 = null;
        var shm: ?Shm = null;
        defer if (shm) |*s| s.deinit(c);
        var flags: u32 = 0;
        while (true) {
            const ev = try self.next(frame, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                screencopy_frame.ev_buffer => {
                    const b = [4]u32{ try r.uint(), try r.uint(), try r.uint(), try r.uint() };
                    const pick = preferFormat(if (best) |x| x[0] else null, b[0]);
                    if (pick != null and pick.? == b[0]) best = b;
                    // before v3 there is no buffer_done: copy right away
                    if (self.screencopy_version < 3 and shm == null) try self.copyInto(frame, &shm, best orelse return error.NoShmFormat);
                },
                screencopy_frame.ev_buffer_done => try self.copyInto(frame, &shm, best orelse return error.NoShmFormat),
                screencopy_frame.ev_flags => flags = try r.uint(),
                screencopy_frame.ev_failed => return error.CaptureFailed,
                screencopy_frame.ev_ready => {
                    const b = best.?;
                    return toFrame(self.gpa, shm.?.mem, b[0], b[1], b[2], b[3], flags & 1 != 0, o.transform);
                },
                else => {},
            }
        }
    }

    fn copyInto(self: *Client, frame: u32, shm: *?Shm, b: [4]u32) !void {
        if (shm.* != null) return;
        shm.* = try self.shmBuffer(b[0], b[1], b[2], b[3]);
        try self.conn.request(frame, screencopy_frame.copy, &.{.{ .object = shm.*.?.buffer }});
        try self.conn.flush();
    }
};

const Frame = struct { pixels: []u32, width: u32, height: u32 };

// wl_shm formats (DRM fourcc, except the first two)
const fmt_argb8888: u32 = 0;
const fmt_xrgb8888: u32 = 1;
const fmt_abgr8888: u32 = 0x34324241; // AB24
const fmt_xbgr8888: u32 = 0x34324258; // XB24
const fmt_argb2101010: u32 = 0x30335241; // AR30
const fmt_xrgb2101010: u32 = 0x30335258; // XR30
const fmt_abgr2101010: u32 = 0x30334241; // AB30
const fmt_xbgr2101010: u32 = 0x30334258; // XB30

/// How good a format is for us: 0 = not understood.
fn formatRank(f: u32) u8 {
    return switch (f) {
        fmt_xrgb8888, fmt_argb8888 => 3,
        fmt_xbgr8888, fmt_abgr8888 => 2,
        fmt_xrgb2101010, fmt_argb2101010, fmt_xbgr2101010, fmt_abgr2101010 => 1,
        else => 0,
    };
}

fn preferFormat(have: ?u32, offered: u32) ?u32 {
    const h = if (have) |x| formatRank(x) else 0;
    return if (formatRank(offered) > h) offered else have;
}

/// One 32-bit pixel of `format` as opaque 0xFFRRGGBB.
fn convert(format: u32, p: u32) u32 {
    return 0xFF000000 | switch (format) {
        fmt_xrgb8888, fmt_argb8888 => p & 0xFFFFFF,
        fmt_xbgr8888, fmt_abgr8888 => (p & 0x00FF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16),
        fmt_xrgb2101010, fmt_argb2101010 => (((p >> 22) & 0xFF) << 16) | (((p >> 12) & 0xFF) << 8) | ((p >> 2) & 0xFF),
        fmt_xbgr2101010, fmt_abgr2101010 => (((p >> 2) & 0xFF) << 16) | (((p >> 12) & 0xFF) << 8) | ((p >> 22) & 0xFF),
        else => 0,
    };
}

/// The buffer as upright 0xAARRGGBB pixels: formats converted, flipped
/// when y-inverted, and the output's transform applied so the picture
/// reads as the monitor shows it.
fn toFrame(gpa: std.mem.Allocator, mem: []const u8, format: u32, w: u32, h: u32, stride: u32, y_invert: bool, transform: u32) !Frame {
    const src = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(src);
    for (0..h) |y| {
        const sy = if (y_invert) h - 1 - y else y;
        const row = mem[sy * stride ..][0 .. w * 4];
        for (0..w) |x| src[y * w + x] = convert(format, std.mem.readInt(u32, row[x * 4 ..][0..4], .little));
    }
    return transformed(gpa, src, w, h, transform);
}

/// Apply a wl_output transform to a buffer: the buffer is what the
/// output's panel scans out, the result what the person sees.
fn transformed(gpa: std.mem.Allocator, src: []const u32, w: u32, h: u32, transform: u32) !Frame {
    const swap = transform & 1 != 0;
    const dw = if (swap) h else w;
    const dh = if (swap) w else h;
    const out = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..dh) |y| for (0..dw) |x| {
        const s = sourceOf(transform, @intCast(x), @intCast(y), w, h);
        out[y * dw + x] = src[@as(usize, s[1]) * w + s[0]];
    };
    return .{ .pixels = out, .width = dw, .height = dh };
}

/// The buffer pixel shown at (x, y) of the transformed picture.
/// wl_output transforms turn the content counter-clockwise; "flipped" ones
/// mirror it around the vertical axis first.
fn sourceOf(transform: u32, x: u32, y: u32, w: u32, h: u32) [2]u32 {
    // undo the rotation, then the flip
    const flip = transform & 4 != 0;
    var sx: u32 = undefined;
    var sy: u32 = undefined;
    switch (transform & 3) {
        0 => {
            sx = x;
            sy = y;
        },
        // 90 counter-clockwise: the picture's top row is the buffer's
        // right column, read downwards from the top
        1 => {
            sx = w - 1 - y;
            sy = x;
        },
        2 => {
            sx = w - 1 - x;
            sy = h - 1 - y;
        },
        3 => {
            sx = y;
            sy = h - 1 - x;
        },
        else => unreachable,
    }
    if (flip) sx = w - 1 - sx;
    return .{ sx, sy };
}

test "formats convert to opaque RGB" {
    try std.testing.expectEqual(@as(u32, 0xFF112233), convert(fmt_xrgb8888, 0x00112233));
    try std.testing.expectEqual(@as(u32, 0xFF112233), convert(fmt_xbgr8888, 0x00332211));
    // 10 bits per channel: top 8 bits kept
    const r10: u32 = 0x3FC;
    const g10: u32 = 0x204;
    const b10: u32 = 0x004;
    try std.testing.expectEqual(@as(u32, 0xFFFF8101), convert(fmt_xrgb2101010, (r10 << 20) | (g10 << 10) | b10));
    try std.testing.expectEqual(@as(u32, 0xFFFF8101), convert(fmt_xbgr2101010, (b10 << 20) | (g10 << 10) | r10));
    try std.testing.expectEqual(@as(?u32, fmt_xrgb8888), preferFormat(fmt_xbgr2101010, fmt_xrgb8888));
    try std.testing.expectEqual(@as(?u32, fmt_xbgr8888), preferFormat(fmt_xbgr8888, 0x12345678));
}

test "transforms turn the buffer upright" {
    const gpa = std.testing.allocator;
    // a 3x2 buffer: a b c / d e f
    const src = [_]u32{ 'a', 'b', 'c', 'd', 'e', 'f' };
    const cases = [_]struct { t: u32, w: u32, want: []const u8 }{
        .{ .t = 0, .w = 3, .want = "abcdef" },
        .{ .t = 1, .w = 2, .want = "cfbead" },
        .{ .t = 2, .w = 3, .want = "fedcba" },
        .{ .t = 3, .w = 2, .want = "daebfc" },
        .{ .t = 4, .w = 3, .want = "cbafed" },
    };
    for (cases) |cs| {
        const f = try transformed(gpa, &src, 3, 2, cs.t);
        defer gpa.free(f.pixels);
        try std.testing.expectEqual(cs.w, f.width);
        for (f.pixels, cs.want) |p, ch| try std.testing.expectEqual(@as(u32, ch), p);
    }
}

/// Capture every output directly. `bus` is used for KWin.
pub fn captureAll(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, bus: *dbus.Connection) !Result {
    var cl: Client = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime_dir, display) };
    defer cl.conn.deinit();
    cl.registry = try cl.conn.getRegistry();
    try cl.roundtrip();
    for (cl.outputs[0..cl.n_outputs]) |*o| {
        o.id = try cl.conn.bind(cl.registry, o.global, "wl_output", o.version);
        if (cl.xdg_mgr != 0) {
            o.xdg = cl.conn.newId();
            try cl.conn.request(cl.xdg_mgr, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
        }
    }
    try cl.roundtrip();
    try cl.roundtrip();
    if (cl.n_outputs == 0) return .{ .unavailable = "no outputs" };

    const method: Method = if (cl.ext_source_mgr != 0 and cl.ext_copy_mgr != 0 and cl.shm != 0)
        .ext_image_copy_capture
    else if (cl.screencopy != 0 and cl.shm != 0)
        .wlr_screencopy
    else
        .kwin_screenshot;

    var frames: [max_outputs]Frame = undefined;
    var n: usize = 0;
    defer for (frames[0..n]) |f| gpa.free(f.pixels);
    var parts: [max_outputs]capture.Part = undefined;
    for (cl.outputs[0..cl.n_outputs]) |*o| {
        frames[n] = switch (method) {
            .ext_image_copy_capture => cl.grabExt(o) catch |err| blk: {
                // a compositor may offer both and fail one: try screencopy
                if (cl.screencopy == 0) return err;
                std.log.info("direct capture: ext-image-copy-capture failed ({t}); wlr-screencopy", .{err});
                break :blk try cl.grabScreencopy(o);
            },
            .wlr_screencopy => try cl.grabScreencopy(o),
            .kwin_screenshot => (try kwinScreen(gpa, bus, o.name())) orelse return .{ .unavailable = kwin_refused },
        };
        parts[n] = .{ .pixels = frames[n].pixels, .width = frames[n].width, .height = frames[n].height, .logical = o.logical() };
        std.log.debug("direct capture: {s} {d}x{d} at {any}", .{ o.name(), frames[n].width, frames[n].height, o.logical() });
        n += 1;
    }
    std.log.info("direct capture: {d} outputs with {s}", .{ n, method.label() });
    return .{ .captured = .{ .cap = try capture.stitch(gpa, parts[0..n]), .method = method } };
}

var kwin_refused: []const u8 = "no direct capture interface";

/// One KWin output via org.kde.KWin.ScreenShot2, at its native
/// resolution, without the pointer. Null when KWin is not running here or
/// refuses this binary (kwin_refused says why).
fn kwinScreen(gpa: std.mem.Allocator, bus: *dbus.Connection, output_name: []const u8) !?Frame {
    if (output_name.len == 0) {
        kwin_refused = "outputs without names";
        return null;
    }
    const p = try sys.pipe();
    defer sys.close(p[0]);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(output_name);
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("native-resolution");
    try m.putVariantBool(true);
    try m.beginStruct();
    try m.putString("include-cursor");
    try m.putVariantBool(false);
    m.endArray(arr);
    try m.putU32(0); // fd index
    const serial = bus.callMethodFds("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureScreen", "sa{sv}h", m.buf.items, &.{p[1]}) catch |err| {
        sys.close(p[1]);
        if (err == error.NoFdPassing) {
            kwin_refused = "the session bus passes no file descriptors";
            return null;
        }
        return err;
    };
    sys.close(p[1]);
    var msg = try bus.waitReplyOrError(serial, 10_000);
    defer msg.deinit(gpa);
    if (msg.type == .@"error") {
        const e = msg.error_name orelse "";
        kwin_refused = if (std.mem.indexOf(u8, e, "NoAuthorized") != null)
            "KWin refused: the installed .desktop file does not list org.kde.KWin.ScreenShot2 for this executable"
        else if (std.mem.eql(u8, e, "org.freedesktop.DBus.Error.ServiceUnknown") or std.mem.eql(u8, e, "org.freedesktop.DBus.Error.UnknownObject") or std.mem.eql(u8, e, "org.freedesktop.DBus.Error.UnknownMethod"))
            "no direct capture interface"
        else
            "KWin ScreenShot2 failed";
        std.log.info("direct capture: {s} ({s})", .{ kwin_refused, e });
        return null;
    }
    var w: u32 = 0;
    var h: u32 = 0;
    var stride: u32 = 0;
    var format: u32 = 0;
    var r = msg.reader();
    var dict = try r.readDictSV();
    while (try dict.next()) |e| {
        const v: u32 = switch (e.value) {
            .u32_ => |x| x,
            else => continue,
        };
        const eql = std.mem.eql;
        if (eql(u8, e.key, "width")) w = v else if (eql(u8, e.key, "height")) h = v else if (eql(u8, e.key, "stride")) stride = v else if (eql(u8, e.key, "format")) format = v;
    }
    if (w == 0 or h == 0 or stride < w * 4 or qimageConvert(format, 0) == null) return error.UnknownImageFormat;
    const size = @as(usize, stride) * h;
    const raw = try gpa.alloc(u8, size);
    defer gpa.free(raw);
    var got: usize = 0;
    const deadline = sys.monoMs() + 10_000;
    while (got < size) {
        if (!try sys.waitReadable(p[0], deadline)) return error.ShortImage;
        const k = try sys.read(p[0], raw[got..]);
        if (k == 0) return error.ShortImage;
        got += k;
    }
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = qimageConvert(format, std.mem.readInt(u32, raw[y * stride + x * 4 ..][0..4], .little)).?;
    };
    return .{ .pixels = px, .width = w, .height = h };
}

/// A 32-bit QImage pixel (little-endian word) as 0xFFRRGGBB; null for
/// formats not handled.
fn qimageConvert(format: u32, p: u32) ?u32 {
    return switch (format) {
        // RGB32, ARGB32, ARGB32_Premultiplied: 0xAARRGGBB words
        4, 5, 6 => 0xFF000000 | (p & 0xFFFFFF),
        // RGBX8888, RGBA8888(_Premultiplied): bytes R G B A
        16, 17, 18 => convert(fmt_xbgr8888, p),
        // BGR30, A2BGR30_Premultiplied: 2-10-10-10, blue high
        19, 20 => convert(fmt_xbgr2101010, p),
        // RGB30, A2RGB30_Premultiplied
        21, 22 => convert(fmt_xrgb2101010, p),
        else => null,
    };
}

test "QImage formats" {
    try std.testing.expectEqual(@as(?u32, 0xFF112233), qimageConvert(4, 0x00112233));
    try std.testing.expectEqual(@as(?u32, 0xFF112233), qimageConvert(17, 0xFF332211));
    try std.testing.expectEqual(@as(?u32, null), qimageConvert(3, 0));
}

/// How the last capture got its pixels, for Settings
/// ($XDG_STATE_HOME/shotlet/capture-path).
pub const Path = enum { direct, portal };

pub fn remember(home: []const u8, path: Path) void {
    if (lastPath(home) == path) return;
    var dbuf: [1024]u8 = undefined;
    const dir = env_mod.stateDir(&dbuf, home) catch return;
    sys.mkdirAll(dir, 0o700);
    var pbuf: [1100]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/capture-path", .{dir}) catch return;
    sys.writeFile(p, @tagName(path)) catch {};
}

pub fn lastPath(home: []const u8) ?Path {
    var dbuf: [1024]u8 = undefined;
    const dir = env_mod.stateDir(&dbuf, home) catch return null;
    var pbuf: [1100]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{s}/capture-path", .{dir}) catch return null;
    var buf: [16]u8 = undefined;
    const fd = sys.openRead(p) catch return null;
    defer sys.close(fd);
    const n = sys.read(fd, &buf) catch return null;
    return std.meta.stringToEnum(Path, std.mem.trim(u8, buf[0..n], " \n"));
}
