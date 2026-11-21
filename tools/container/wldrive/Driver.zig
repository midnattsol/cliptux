//! shotlet-wldrive's connection state: the Wayland globals and outputs it
//! tracks, and its virtual pointer and keyboard (wlroots' virtual input or
//! KWin's fake input).

const std = @import("std");
const kit = @import("shotlet");
const wl = kit.wayland;
const dbus = kit.dbus;
const sys = kit.sys;
const proto = @import("proto.zig");
const grab_ = @import("grab.zig");
const util = @import("util.zig");
const Output = proto.Output;
const vp = proto.vp;
const vk = proto.vk;
const fake = proto.fake;
const eql = util.eql;
const sleepMs = util.sleepMs;

const Driver = @This();

gpa: std.mem.Allocator,
conn: wl.Connection,
registry: u32 = 0,
g: proto.Globals = .{},
outputs: std.ArrayList(Output) = .empty,
kwin: bool = false,
bus: ?dbus.Connection = null,
pointer: u32 = 0,
keyboard: u32 = 0,
/// modifiers held on the virtual keyboard (xkb masks, us keymap)
mods: u32 = 0,
out: [512]u8 = undefined,

pub fn roundtrip(self: *Driver) !void {
    const cb = try self.conn.sync();
    try self.conn.flush();
    while (true) {
        const ev = try self.conn.readEvent();
        if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) return;
        try self.handle(ev);
    }
}

/// Read whatever events arrived meanwhile.
pub fn drain(self: *Driver) !void {
    try self.conn.flush();
    while (try sys.waitReadable(self.conn.fd, sys.monoMs())) {
        const ev = try self.conn.readEvent();
        try self.handle(ev);
        while (try self.conn.pollEvent()) |e| try self.handle(e);
    }
}

pub fn handle(self: *Driver, ev: wl.Event) !void {
    var r: wl.ArgReader = .{ .data = ev.body };
    if (ev.object == wl.wl_display.id and ev.opcode == wl.wl_display.ev_error) {
        _ = try r.uint();
        const code = try r.uint();
        std.debug.print("wldrive: protocol error {d}: {s}\n", .{ code, try r.string() });
        return error.ProtocolError;
    }
    if (ev.object == self.registry and ev.opcode == wl.wl_registry.ev_global) return self.onGlobal(&r);
    for (self.outputs.items) |*o| {
        if (o.id != 0 and ev.object == o.id) {
            try onOutputEvent(o, ev.opcode, &r);
        } else if (o.xdg != 0 and ev.object == o.xdg) {
            try onXdgOutputEvent(o, ev.opcode, &r);
        }
    }
}

/// A registry global: note outputs, bind the other globals used.
fn onGlobal(self: *Driver, r: *wl.ArgReader) !void {
    const name = try r.uint();
    const iface = try r.string();
    const version = try r.uint();
    if (eql(iface, "wl_output")) {
        try self.outputs.append(self.gpa, .{ .global = name });
    } else if (eql(iface, "wl_seat") and self.g.seat == 0) {
        self.g.seat = try self.conn.bind(self.registry, name, iface, 1);
    } else if (eql(iface, "wl_shm")) {
        self.g.shm = try self.conn.bind(self.registry, name, iface, 1);
    } else if (eql(iface, "zxdg_output_manager_v1")) {
        self.g.xdg_output_mgr = try self.conn.bind(self.registry, name, iface, @min(version, 3));
    } else if (eql(iface, "zwlr_virtual_pointer_manager_v1")) {
        self.g.vp_mgr = try self.conn.bind(self.registry, name, iface, 1);
    } else if (eql(iface, "zwp_virtual_keyboard_manager_v1")) {
        self.g.vk_mgr = try self.conn.bind(self.registry, name, iface, 1);
    } else if (eql(iface, "org_kde_kwin_fake_input")) {
        self.g.fake_version = @min(version, 4);
        self.g.fake = try self.conn.bind(self.registry, name, iface, self.g.fake_version);
    } else if (eql(iface, "zwlr_screencopy_manager_v1") and version >= 3) {
        self.g.screencopy_version = 3;
        self.g.screencopy = try self.conn.bind(self.registry, name, iface, 3);
    }
}

fn onOutputEvent(o: *Output, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_output.ev_scale => o.scale = try r.int(),
        wl.wl_output.ev_name => {
            const n = try r.string();
            if (o.name_len == 0) {
                o.name_len = @min(n.len, o.name_buf.len);
                @memcpy(o.name_buf[0..o.name_len], n[0..o.name_len]);
            }
        },
        else => {},
    }
}

fn onXdgOutputEvent(o: *Output, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.zxdg_output_v1.ev_logical_position => {
            o.x = try r.int();
            o.y = try r.int();
        },
        wl.zxdg_output_v1.ev_logical_size => {
            o.w = try r.int();
            o.h = try r.int();
        },
        else => {},
    }
}

/// Outputs left to right (then top to bottom).
pub fn sortOutputs(self: *Driver) void {
    const less = struct {
        fn f(_: void, a: Output, b: Output) bool {
            return if (a.x != b.x) a.x < b.x else a.y < b.y;
        }
    }.f;
    std.mem.sort(Output, self.outputs.items, {}, less);
}

/// Hand the xkb keymap file at `path` to the virtual keyboard.
pub fn uploadKeymap(self: *Driver, path: []const u8) !void {
    const text = try sys.readFileAlloc(self.gpa, path, 1 << 20);
    defer self.gpa.free(text);
    const fd = try sys.memfdCreate("keymap", 0);
    defer sys.close(fd);
    const size = text.len + 1;
    try sys.ftruncate(fd, size);
    const mem = try sys.mmapRw(fd, size);
    defer sys.munmap(mem);
    @memcpy(mem[0..text.len], text);
    mem[text.len] = 0;
    try self.conn.request(self.keyboard, vk.keymap, &.{ .{ .uint = 1 }, .{ .fd = fd }, .{ .uint = @intCast(size) } });
    try self.conn.flush();
}

fn now() u32 {
    return @truncate(@as(u64, @intCast(sys.monoMs())));
}

/// A monitor by connector name or by its number, left to right.
pub fn monitor(self: *Driver, name: []const u8) !*Output {
    for (self.outputs.items) |*o| if (eql(o.name(), name)) return o;
    const i = std.fmt.parseInt(usize, name, 10) catch return error.UnknownMonitor;
    if (i >= self.outputs.items.len) return error.UnknownMonitor;
    return &self.outputs.items[i];
}

/// The logical layout's bounding box: x, y, width, height.
fn layoutBox(self: *const Driver) [4]i32 {
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (self.outputs.items) |o| {
        x0 = @min(x0, o.x);
        y0 = @min(y0, o.y);
        x1 = @max(x1, o.x + o.w);
        y1 = @max(y1, o.y + o.h);
    }
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

/// Absolute pointer motion to the global logical point gx, gy.
pub fn moveTo(self: *Driver, gx: f64, gy: f64) !void {
    if (self.kwin) {
        try self.conn.request(self.g.fake, fake.pointer_motion_absolute, &.{ .{ .fixed = gx }, .{ .fixed = gy } });
    } else {
        // absolute motion maps onto the whole layout's bounding box
        const box = self.layoutBox();
        try self.conn.request(self.pointer, vp.motion_absolute, &.{
            .{ .uint = now() },
            .{ .uint = @intFromFloat(@max(0, gx - @as(f64, @floatFromInt(box[0])))) },
            .{ .uint = @intFromFloat(@max(0, gy - @as(f64, @floatFromInt(box[1])))) },
            .{ .uint = @intCast(box[2]) },
            .{ .uint = @intCast(box[3]) },
        });
        try self.conn.request(self.pointer, vp.frame, &.{});
    }
    try self.conn.flush();
    sleepMs(40);
}

/// Vertical scroll by `steps` wheel clicks (+ is down).
pub fn wheel(self: *Driver, steps: i32) !void {
    const v: f64 = @floatFromInt(steps * 15);
    if (self.kwin) {
        try self.conn.request(self.g.fake, fake.axis, &.{ .{ .uint = 0 }, .{ .fixed = v } });
    } else {
        try self.conn.request(self.pointer, vp.axis_source, &.{.{ .uint = 0 }});
        try self.conn.request(self.pointer, vp.axis_discrete, &.{ .{ .uint = now() }, .{ .uint = 0 }, .{ .fixed = v }, .{ .int = steps } });
        try self.conn.request(self.pointer, vp.frame, &.{});
    }
    try self.conn.flush();
    sleepMs(30);
}

pub fn key(self: *Driver, code: u32, pressed: bool) !void {
    if (self.kwin) {
        try self.conn.request(self.g.fake, fake.keyboard_key, &.{ .{ .uint = code }, .{ .uint = @intFromBool(pressed) } });
    } else {
        try self.conn.request(self.keyboard, vk.key, &.{ .{ .uint = now() }, .{ .uint = code }, .{ .uint = @intFromBool(pressed) } });
        // wlroots does not derive modifiers from a virtual keyboard's
        // keys: say which are held
        const m = util.modMask(code);
        if (m != 0) {
            if (pressed) self.mods |= m else self.mods &= ~m;
            try self.conn.request(self.keyboard, vk.modifiers, &.{ .{ .uint = self.mods }, .{ .uint = 0 }, .{ .uint = 0 }, .{ .uint = 0 } });
        }
    }
    try self.conn.flush();
    sleepMs(15);
}

pub fn button(self: *Driver, btn: u32, pressed: bool) !void {
    if (self.kwin) {
        try self.conn.request(self.g.fake, fake.button, &.{ .{ .uint = btn }, .{ .uint = @intFromBool(pressed) } });
    } else {
        try self.conn.request(self.pointer, vp.button, &.{ .{ .uint = now() }, .{ .uint = btn }, .{ .uint = @intFromBool(pressed) } });
        try self.conn.request(self.pointer, vp.frame, &.{});
    }
    try self.conn.flush();
    sleepMs(15);
}

/// The output's current picture (the caller frees its pixels).
pub fn grab(self: *Driver, o: *const Output) !grab_.Frame {
    if (self.kwin) return grab_.kwin(self, o);
    if (self.g.screencopy == 0) return error.NoScreencopy;
    return grab_.screencopy(self, o);
}

/// Write `px` as a PNG at `path`; answers WxH.
pub fn writePng(self: *Driver, path: []const u8, px: []const u32, w: u32, h: u32) ![]const u8 {
    const data = try kit.png.encode(self.gpa, px, w, h);
    defer self.gpa.free(data);
    sys.unlink(path) catch {};
    try sys.writeFile(path, data);
    return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ w, h });
}
