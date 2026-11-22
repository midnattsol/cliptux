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
const dbus = @import("../platform/linux/dbus.zig");
const sys = @import("../platform/linux/sys.zig");
const wl = @import("../platform/linux/wayland.zig");
const kwin = @import("direct_kwin.zig");

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

    fn setName(self: *Output, n: []const u8) void {
        self.name_len = @min(n.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], n[0..self.name_len]);
    }

    fn onOutputEvent(o: *Output, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
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
            wl.wl_output.ev_name => o.setName(try r.string()),
            else => {},
        }
    }

    fn onXdgOutputEvent(o: *Output, opcode: u16, r: *wl.ArgReader) !void {
        switch (opcode) {
            wl.zxdg_output_v1.ev_logical_position => {
                o.lx = try r.int();
                o.ly = try r.int();
                o.has_logical = true;
            },
            wl.zxdg_output_v1.ev_logical_size => {
                o.lw = try r.int();
                o.lh = try r.int();
            },
            wl.zxdg_output_v1.ev_name => if (o.name_len == 0) o.setName(try r.string()),
            else => {},
        }
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
        if (ev.object == self.registry and ev.opcode == wl.wl_registry.ev_global) return self.onGlobal(&r);
        for (self.outputs[0..self.n_outputs]) |*o| {
            if (o.id != 0 and ev.object == o.id) return o.onOutputEvent(ev.opcode, &r);
            if (o.xdg != 0 and ev.object == o.xdg) return o.onXdgOutputEvent(ev.opcode, &r);
        }
    }

    /// A registry global: outputs are noted, the capture interfaces bound.
    fn onGlobal(self: *Client, r: *wl.ArgReader) !void {
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

    /// Binds the registry and every output, with its xdg_output, and
    /// waits until their geometry is known.
    fn discoverOutputs(cl: *Client) !void {
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
    }

    /// The best interface the compositor offers; KWin's when none.
    fn method(cl: *const Client) Method {
        return if (cl.ext_source_mgr != 0 and cl.ext_copy_mgr != 0 and cl.shm != 0)
            .ext_image_copy_capture
        else if (cl.screencopy != 0 and cl.shm != 0)
            .wlr_screencopy
        else
            .kwin_screenshot;
    }

    /// One output's picture; null when KWin refused this binary.
    fn grab(cl: *Client, o: *const Output, m: Method, bus: *dbus.Connection) !?Frame {
        return switch (m) {
            .ext_image_copy_capture => cl.grabExt(o) catch |err| {
                // a compositor may offer both and fail one: try screencopy
                if (cl.screencopy == 0) return err;
                std.log.info("direct capture: ext-image-copy-capture failed ({t}); wlr-screencopy", .{err});
                return try cl.grabScreencopy(o);
            },
            .wlr_screencopy => try cl.grabScreencopy(o),
            .kwin_screenshot => try kwin.screen(cl.gpa, bus, o.name()),
        };
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

const pixels = @import("direct/pixels.zig");
pub const Frame = pixels.Frame;
pub const fmt_argb8888 = pixels.fmt_argb8888;
pub const fmt_xrgb8888 = pixels.fmt_xrgb8888;
pub const fmt_abgr8888 = pixels.fmt_abgr8888;
pub const fmt_xbgr8888 = pixels.fmt_xbgr8888;
pub const fmt_argb2101010 = pixels.fmt_argb2101010;
pub const fmt_xrgb2101010 = pixels.fmt_xrgb2101010;
pub const fmt_abgr2101010 = pixels.fmt_abgr2101010;
pub const fmt_xbgr2101010 = pixels.fmt_xbgr2101010;
pub const convert = pixels.convert;
const preferFormat = pixels.preferFormat;
const toFrame = pixels.toFrame;

comptime {
    _ = pixels;
}

/// Capture every output directly. `bus` is used for KWin.
pub fn captureAll(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, bus: *dbus.Connection) !Result {
    var cl: Client = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime_dir, display) };
    defer cl.conn.deinit();
    try cl.discoverOutputs();
    if (cl.n_outputs == 0) return .{ .unavailable = "no outputs" };
    const method = cl.method();

    var frames: [max_outputs]Frame = undefined;
    var n: usize = 0;
    defer for (frames[0..n]) |f| gpa.free(f.pixels);
    var parts: [max_outputs]capture.Part = undefined;
    for (cl.outputs[0..cl.n_outputs]) |*o| {
        frames[n] = (try cl.grab(o, method, bus)) orelse return .{ .unavailable = kwin.refused };
        parts[n] = .{ .pixels = frames[n].pixels, .width = frames[n].width, .height = frames[n].height, .logical = o.logical() };
        std.log.debug("direct capture: {s} {d}x{d} at {any}", .{ o.name(), frames[n].width, frames[n].height, o.logical() });
        n += 1;
    }
    std.log.info("direct capture: {d} outputs with {s}", .{ n, method.label() });
    return .{ .captured = .{ .cap = try capture.stitch(gpa, parts[0..n]), .method = method } };
}

/// The direct interface a capture would use now, without capturing;
/// null when there is none (the portal then). KWin counts when it is on
/// the bus, though it may still refuse this binary.
pub fn probe(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, bus: *dbus.Connection) ?Method {
    var cl: Client = .{ .gpa = gpa, .conn = wl.Connection.connect(gpa, runtime_dir, display) catch return null };
    defer cl.conn.deinit();
    cl.registry = cl.conn.getRegistry() catch return null;
    cl.roundtrip() catch return null;
    const m = cl.method();
    if (m != .kwin_screenshot) return m;
    return if (bus.nameHasOwner("org.kde.KWin") catch false) m else null;
}
