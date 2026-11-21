//! Pictures of an output for shotlet-wldrive: zwlr_screencopy_v1 on
//! wlroots, org.kde.KWin.ScreenShot2 over D-Bus on KWin.

const std = @import("std");
const kit = @import("shotlet");
const wl = kit.wayland;
const dbus = kit.dbus;
const sys = kit.sys;
const proto = @import("proto.zig");
const Driver = @import("Driver.zig");
const Output = proto.Output;
const sc_mgr = proto.sc_mgr;
const sc_frame = proto.sc_frame;
const eql = @import("util.zig").eql;

/// 0xAARRGGBB pixels, owned by the caller.
pub const Frame = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

/// One frame of an output with zwlr_screencopy_v1 (v3), into wl_shm.
pub fn screencopy(d: *Driver, o: *const Output) !Frame {
    const c = &d.conn;
    const frame = c.newId();
    try c.request(d.g.screencopy, sc_mgr.capture_output, &.{ .{ .new_id = frame }, .{ .int = 0 }, .{ .object = o.id } });
    try c.flush();
    defer c.request(frame, sc_frame.destroy, &.{}) catch {};
    var shm: ShmCopy = .{};
    defer shm.deinit(c);
    while (true) {
        const ev = try c.readEvent();
        if (ev.object != frame) {
            try d.handle(ev);
            continue;
        }
        var r: wl.ArgReader = .{ .data = ev.body };
        switch (ev.opcode) {
            sc_frame.ev_buffer => {
                const f = [4]u32{ try r.uint(), try r.uint(), try r.uint(), try r.uint() };
                if (shm.fmt == null and (bgrOrder(f[0]) != null)) shm.fmt = f;
            },
            sc_frame.ev_flags => shm.flags = try r.uint(),
            sc_frame.ev_buffer_done => try shm.copy(c, d.g.shm, frame),
            sc_frame.ev_failed => return error.ScreencopyFailed,
            sc_frame.ev_ready => return shm.toFrame(d.gpa),
            else => {},
        }
    }
}

/// The wl_shm buffer a screencopy frame is copied into.
const ShmCopy = struct {
    fmt: ?[4]u32 = null, // format, width, height, stride
    flags: u32 = 0,
    pool_fd: sys.fd_t = -1,
    mem: []align(std.heap.page_size_min) u8 = &.{},
    buffer: u32 = 0,

    fn deinit(self: *ShmCopy, c: *wl.Connection) void {
        if (self.buffer != 0) c.request(self.buffer, wl.wl_buffer.destroy, &.{}) catch {};
        if (self.mem.len > 0) sys.munmap(self.mem);
        if (self.pool_fd >= 0) sys.close(self.pool_fd);
    }

    /// A buffer of the format offered, and the request to copy into it.
    fn copy(self: *ShmCopy, c: *wl.Connection, shm: u32, frame: u32) !void {
        const f = self.fmt orelse return error.NoShmFormat;
        const size = @as(usize, f[3]) * f[2];
        self.pool_fd = try sys.memfdCreate("shot", 0);
        try sys.ftruncate(self.pool_fd, size);
        self.mem = try sys.mmapRw(self.pool_fd, size);
        const pool = c.newId();
        try c.request(shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = self.pool_fd }, .{ .int = @intCast(size) } });
        self.buffer = c.newId();
        try c.request(pool, wl.wl_shm_pool.create_buffer, &.{ .{ .new_id = self.buffer }, .{ .int = 0 }, .{ .int = @intCast(f[1]) }, .{ .int = @intCast(f[2]) }, .{ .int = @intCast(f[3]) }, .{ .uint = f[0] } });
        try c.request(pool, wl.wl_shm_pool.destroy, &.{});
        try c.request(frame, sc_frame.copy, &.{.{ .object = self.buffer }});
        try c.flush();
    }

    /// The copied picture as 0xAARRGGBB, upright.
    fn toFrame(self: *const ShmCopy, gpa: std.mem.Allocator) !Frame {
        const f = self.fmt.?;
        const px = try gpa.alloc(u32, @as(usize, f[1]) * f[2]);
        for (0..f[2]) |y| {
            const sy = if (self.flags & 1 != 0) f[2] - 1 - y else y;
            const row = self.mem[sy * f[3] ..][0 .. f[1] * 4];
            const swap = bgrOrder(f[0]).?;
            for (0..f[1]) |x| {
                const p = std.mem.readInt(u32, row[x * 4 ..][0..4], .little);
                px[y * f[1] + x] = 0xFF000000 | if (swap) (p & 0xFF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16) else p;
            }
        }
        return .{ .pixels = px, .width = f[1], .height = f[2] };
    }
};

/// Whether a 32-bit wl_shm format has red and blue swapped against
/// 0xAARRGGBB (GLES renderers offer ABGR); null for formats not handled.
fn bgrOrder(format: u32) ?bool {
    return switch (format) {
        wl.wl_shm.format_argb8888, wl.wl_shm.format_xrgb8888 => false,
        0x34324241, 0x34324258 => true, // AB24, XB24
        else => null,
    };
}

/// One frame of an output with org.kde.KWin.ScreenShot2.CaptureScreen:
/// raw pixels written to a pipe, described by the reply.
pub fn kwin(d: *Driver, o: *const Output) !Frame {
    const bus = &(d.bus orelse return error.NoBus);
    const p = try sys.pipe();
    defer sys.close(p[0]);
    var msg = try captureScreen(d.gpa, bus, o.name(), p[1]);
    defer msg.deinit(d.gpa);
    if (msg.type == .@"error") {
        var er = msg.reader();
        std.debug.print("wldrive: ScreenShot2: {s}\n", .{er.readString() catch "?"});
        return error.ScreenShotRefused;
    }
    const img = try imageInfo(&msg);
    const raw = try d.gpa.alloc(u8, @as(usize, img.stride) * img.h);
    defer d.gpa.free(raw);
    try readAll(p[0], raw);
    const px = try d.gpa.alloc(u32, @as(usize, img.w) * img.h);
    for (0..img.h) |y| for (0..img.w) |x| {
        px[y * img.w + x] = std.mem.readInt(u32, raw[y * img.stride + x * 4 ..][0..4], .little) | 0xFF000000;
    };
    return .{ .pixels = px, .width = img.w, .height = img.h };
}

/// Ask KWin for the screen `name` at its native resolution, into the pipe
/// end `fd` (closed here); its reply.
fn captureScreen(gpa: std.mem.Allocator, bus: *dbus.Connection, name: []const u8, fd: sys.fd_t) !dbus.Message {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(name);
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("native-resolution");
    try m.putVariantBool(true);
    m.endArray(arr);
    try m.putU32(0); // fd index
    const serial = bus.callMethodFds("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureScreen", "sa{sv}h", m.buf.items, &.{fd}) catch |err| {
        sys.close(fd);
        return err;
    };
    sys.close(fd);
    return bus.waitReplyTimeout(serial, 10_000);
}

const ImageInfo = struct { w: u32 = 0, h: u32 = 0, stride: u32 = 0, format: u32 = 0 };

/// The picture's size and layout from CaptureScreen's reply.
fn imageInfo(msg: *dbus.Message) !ImageInfo {
    var img: ImageInfo = .{};
    var r = msg.reader();
    var dict = try r.readDictSV();
    while (try dict.next()) |e| {
        const v: u32 = switch (e.value) {
            .u32_ => |x| x,
            else => continue,
        };
        if (eql(e.key, "width")) img.w = v else if (eql(e.key, "height")) img.h = v else if (eql(e.key, "stride")) img.stride = v else if (eql(e.key, "format")) img.format = v;
    }
    // QImage::Format_RGB32 (4), ARGB32 (5), ARGB32_Premultiplied (6)
    if (img.format < 4 or img.format > 6 or img.w == 0 or img.h == 0) return error.UnknownImageFormat;
    return img;
}

/// Fill `buf` from `fd`, within 10 s.
fn readAll(fd: sys.fd_t, buf: []u8) !void {
    var got: usize = 0;
    const deadline = sys.monoMs() + 10_000;
    while (got < buf.len) {
        if (!try sys.waitReadable(fd, deadline)) return error.ShortImage;
        const n = try sys.read(fd, buf[got..]);
        if (n == 0) return error.ShortImage;
        got += n;
    }
}
