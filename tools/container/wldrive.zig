//! shotlet-wldrive: virtual keyboard, pointer and screenshots for the
//! container e2e suite (tools/container/run.sh), on wlroots compositors
//! (sway, labwc) and on KWin. The counterpart of tools/e2e/drive.zig,
//! which does the same through Mutter's RemoteDesktop API on GNOME.
//!
//! - wlroots: zwlr_virtual_pointer_v1 + zwp_virtual_keyboard_v1 for input,
//!   zwlr_screencopy_v1 for pictures of an output.
//! - KWin: org_kde_kwin_fake_input for input (restricted: kwin_wayland must
//!   run with KWIN_WAYLAND_NO_PERMISSION_CHECKS=1), org.kde.KWin.ScreenShot2
//!   over D-Bus for pictures (KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1).
//!
//! Refuses to run unless SHOTLET_CONTAINER is set (the runner sets it), so
//! it can never type into a real desktop by accident. One command per line
//! on stdin, answered with one line on stdout: `ok [value]` or `err why`.
//! Monitors (MON) are numbered left to right, or named by connector.
//!
//!   key COMBO [down|up]   tap (or press/release) evdev keys: ctrl+c, a, #30
//!   type TEXT             tap the keys for lowercase letters, digits, space
//!   move MON X Y          absolute motion, logical pixels of monitor MON
//!   down|up|click [BTN]   left (default), right, middle
//!   wheel STEPS           vertical scroll (+ is down)
//!   monitors              "NAME:X,Y,WxH@SCALE ..." in the logical layout
//!   shot MON PATH         write the monitor's picture as a PNG; answers WxH
//!   find MON RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
//!                         "cx cy w h" of the first blob of that colour, in
//!                         the monitor's buffer pixels
//!   findpng PATH RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]   the same in a PNG file
//!   png PATH | pixel PATH X Y
//!   mkpng PATH W H RRGGBB a test picture: that colour framed in grey
//!   textpng PATH SIZE TEXT  black TEXT on white (Shotlet's text renderer)
//!   sleep MS | quit

const std = @import("std");
const kit = @import("shotlet");
const wl = kit.wayland;
const dbus = kit.dbus;
const sys = kit.sys;

const vp_mgr = struct {
    const create_virtual_pointer = 0;
};
const vp = struct {
    const motion_absolute = 1;
    const button = 2;
    const axis = 3;
    const frame = 4;
    const axis_source = 5;
    const axis_discrete = 7;
};
const vk_mgr = struct {
    const create_virtual_keyboard = 0;
};
const vk = struct {
    const keymap = 0;
    const key = 1;
    const modifiers = 2;
};
const fake = struct {
    const authenticate = 0;
    const button = 2;
    const axis = 3;
    const pointer_motion_absolute = 9; // since 3
    const keyboard_key = 10; // since 4
};
const sc_mgr = struct {
    const capture_output = 0;
};
const sc_frame = struct {
    const copy = 0;
    const destroy = 1;
    const ev_buffer = 0;
    const ev_flags = 1;
    const ev_ready = 2;
    const ev_failed = 3;
    const ev_buffer_done = 6;
};

const Output = struct {
    global: u32,
    id: u32 = 0,
    xdg: u32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,

    fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const Globals = struct {
    compositor: u32 = 0,
    shm: u32 = 0,
    seat: u32 = 0,
    xdg_output_mgr: u32 = 0,
    vp_mgr: u32 = 0,
    vk_mgr: u32 = 0,
    fake: u32 = 0,
    fake_version: u32 = 0,
    screencopy: u32 = 0,
    screencopy_version: u32 = 0,
};

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const gpa = gpa_state.allocator();
    const vars = init.environ_map;
    if (vars.get("SHOTLET_CONTAINER") == null) {
        std.debug.print("shotlet-wldrive: run me inside tools/container/run.sh\n", .{});
        std.process.exit(2);
    }
    const runtime = vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    const display = vars.get("WAYLAND_DISPLAY") orelse "wayland-0";

    var d: Driver = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime, display) };
    defer d.conn.deinit();
    d.registry = try d.conn.getRegistry();
    try d.roundtrip();
    // outputs: logical position, size and connector name
    for (d.outputs.items) |*o| {
        o.id = try d.conn.bind(d.registry, o.global, "wl_output", 4);
        if (d.g.xdg_output_mgr != 0) {
            o.xdg = d.conn.newId();
            try d.conn.request(d.g.xdg_output_mgr, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
        }
    }
    try d.roundtrip();
    try d.roundtrip();
    d.sortOutputs();

    if (d.g.fake != 0) {
        d.kwin = true;
        try d.conn.request(d.g.fake, fake.authenticate, &.{ .{ .string = "shotlet-wldrive" }, .{ .string = "e2e tests" } });
        if (d.g.fake_version < 4) return fail("org_kde_kwin_fake_input v{d}: no keyboard", .{d.g.fake_version});
        d.bus = try dbus.Connection.connectSession(gpa, vars.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoBus);
    } else if (d.g.vp_mgr != 0 and d.g.vk_mgr != 0 and d.g.seat != 0) {
        d.pointer = d.conn.newId();
        try d.conn.request(d.g.vp_mgr, vp_mgr.create_virtual_pointer, &.{ .{ .object = d.g.seat }, .{ .new_id = d.pointer } });
        d.keyboard = d.conn.newId();
        try d.conn.request(d.g.vk_mgr, vk_mgr.create_virtual_keyboard, &.{ .{ .object = d.g.seat }, .{ .new_id = d.keyboard } });
        const path = vars.get("WLDRIVE_KEYMAP") orelse return fail("WLDRIVE_KEYMAP: an xkb keymap file is needed", .{});
        try d.uploadKeymap(path);
    } else {
        return fail("no virtual input: neither wlroots' virtual pointer/keyboard nor KWin's fake input", .{});
    }
    try d.roundtrip();
    reply("ok ready", .{});

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const line = std.mem.trim(u8, buf[0..nl], " \t\r");
            const quit = std.mem.eql(u8, line, "quit");
            if (line.len > 0 and line[0] != '#') {
                if (d.run(line)) |val| {
                    if (val.len > 0) reply("ok {s}", .{val}) else reply("ok", .{});
                } else |err| reply("err {t}", .{err});
            }
            std.mem.copyForwards(u8, buf[0..], buf[nl + 1 .. len]);
            len -= nl + 1;
            if (quit) break;
            continue;
        }
        if (len == buf.len) return error.LineTooLong;
        const n = try sys.read(0, buf[len..]);
        if (n == 0) break;
        len += n;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    reply("err " ++ fmt, args);
    return error.Setup;
}

fn reply(comptime fmt: []const u8, args: anytype) void {
    var out: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&out, fmt ++ "\n", args) catch "err reply too long\n";
    sys.writeAll(1, s) catch {};
}

const Frame = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

const Driver = struct {
    gpa: std.mem.Allocator,
    conn: wl.Connection,
    registry: u32 = 0,
    g: Globals = .{},
    outputs: std.ArrayList(Output) = .empty,
    kwin: bool = false,
    bus: ?dbus.Connection = null,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    /// modifiers held on the virtual keyboard (xkb masks, us keymap)
    mods: u32 = 0,
    out: [512]u8 = undefined,

    fn roundtrip(self: *Driver) !void {
        const cb = try self.conn.sync();
        try self.conn.flush();
        while (true) {
            const ev = try self.conn.readEvent();
            if (ev.object == cb and ev.opcode == wl.wl_callback.ev_done) return;
            try self.handle(ev);
        }
    }

    /// Read whatever events arrived meanwhile.
    fn drain(self: *Driver) !void {
        try self.conn.flush();
        while (try sys.waitReadable(self.conn.fd, sys.monoMs())) {
            const ev = try self.conn.readEvent();
            try self.handle(ev);
            while (try self.conn.pollEvent()) |e| try self.handle(e);
        }
    }

    fn handle(self: *Driver, ev: wl.Event) !void {
        var r: wl.ArgReader = .{ .data = ev.body };
        if (ev.object == wl.wl_display.id and ev.opcode == wl.wl_display.ev_error) {
            _ = try r.uint();
            const code = try r.uint();
            std.debug.print("wldrive: protocol error {d}: {s}\n", .{ code, try r.string() });
            return error.ProtocolError;
        }
        if (ev.object == self.registry and ev.opcode == wl.wl_registry.ev_global) {
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
            return;
        }
        for (self.outputs.items) |*o| {
            if (o.id != 0 and ev.object == o.id) {
                switch (ev.opcode) {
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
            } else if (o.xdg != 0 and ev.object == o.xdg) {
                switch (ev.opcode) {
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
        }
    }

    fn sortOutputs(self: *Driver) void {
        const less = struct {
            fn f(_: void, a: Output, b: Output) bool {
                return if (a.x != b.x) a.x < b.x else a.y < b.y;
            }
        }.f;
        std.mem.sort(Output, self.outputs.items, {}, less);
    }

    fn uploadKeymap(self: *Driver, path: []const u8) !void {
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

    fn run(self: *Driver, line: []const u8) ![]const u8 {
        defer self.drain() catch {};
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse return "";
        if (eql(cmd, "key")) {
            const combo = it.next() orelse return error.MissingArg;
            const mode = it.next() orelse "tap";
            var codes: [8]u32 = undefined;
            var n: usize = 0;
            var parts = std.mem.splitScalar(u8, combo, '+');
            while (parts.next()) |p| {
                if (n == codes.len) return error.TooManyKeys;
                codes[n] = keyCode(p) orelse return error.UnknownKey;
                n += 1;
            }
            if (!eql(mode, "up")) for (codes[0..n]) |c| try self.key(c, true);
            if (!eql(mode, "down")) {
                var i = n;
                while (i > 0) {
                    i -= 1;
                    try self.key(codes[i], false);
                }
            }
            return "";
        }
        if (eql(cmd, "type")) {
            const rest = std.mem.trimStart(u8, line[cmd.len..], " \t");
            for (rest) |c| {
                const name: []const u8 = if (c == ' ') "space" else &.{c};
                const code = keyCode(name) orelse return error.UnknownKey;
                try self.key(code, true);
                try self.key(code, false);
            }
            return "";
        }
        if (eql(cmd, "move")) {
            const o = try self.monitor(it.next() orelse return error.MissingArg);
            const x = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            const y = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            const gx = @as(f64, @floatFromInt(o.x)) + x;
            const gy = @as(f64, @floatFromInt(o.y)) + y;
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
            return "";
        }
        if (eql(cmd, "down") or eql(cmd, "up") or eql(cmd, "click")) {
            const name = it.next() orelse "left";
            const btn: u32 = if (eql(name, "left")) 0x110 else if (eql(name, "right")) 0x111 else if (eql(name, "middle")) 0x112 else return error.UnknownButton;
            if (!eql(cmd, "up")) try self.button(btn, true);
            if (!eql(cmd, "down")) try self.button(btn, false);
            return "";
        }
        if (eql(cmd, "wheel")) {
            const steps = try std.fmt.parseInt(i32, it.next() orelse return error.MissingArg, 10);
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
            return "";
        }
        if (eql(cmd, "monitors")) {
            var w: usize = 0;
            for (self.outputs.items) |o| {
                const s = std.fmt.bufPrint(self.out[w..], "{s}{s}:{d},{d},{d}x{d}@{d}", .{ if (w > 0) " " else "", o.name(), o.x, o.y, o.w, o.h, o.scale }) catch break;
                w += s.len;
            }
            return self.out[0..w];
        }
        if (eql(cmd, "shot")) {
            const o = try self.monitor(it.next() orelse return error.MissingArg);
            const path = it.next() orelse return error.MissingArg;
            const f = try self.grab(o);
            defer self.gpa.free(f.pixels);
            const data = try kit.png.encode(self.gpa, f.pixels, f.width, f.height);
            defer self.gpa.free(data);
            sys.unlink(path) catch {};
            try sys.writeFile(path, data);
            return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ f.width, f.height });
        }
        if (eql(cmd, "find") or eql(cmd, "findpng")) {
            const what = it.next() orelse return error.MissingArg;
            const rgb = try std.fmt.parseInt(u32, trimHex(it.next() orelse return error.MissingArg), 16);
            const tol = try std.fmt.parseInt(u32, it.next() orelse "24", 10);
            const min_w = try std.fmt.parseInt(u32, it.next() orelse "1", 10);
            const f: Frame = if (eql(cmd, "find")) try self.grab(try self.monitor(what)) else blk: {
                const data = try sys.readFileAlloc(self.gpa, what, 256 * 1024 * 1024);
                defer self.gpa.free(data);
                const img = try kit.png.decode(self.gpa, data);
                break :blk .{ .pixels = img.pixels, .width = img.width, .height = img.height };
            };
            defer self.gpa.free(f.pixels);
            if (it.next()) |first| {
                var region: [4]u32 = undefined;
                region[0] = try std.fmt.parseInt(u32, first, 10);
                for (region[1..]) |*v| v.* = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
                for (f.pixels, 0..) |*p, i| {
                    const x: u32 = @intCast(i % f.width);
                    const y: u32 = @intCast(i / f.width);
                    if (x < region[0] or y < region[1] or x >= region[2] or y >= region[3]) p.* = ~rgb;
                }
            }
            const box = try findBlob(self.gpa, f.pixels, f.width, f.height, rgb, tol, min_w);
            return std.fmt.bufPrint(&self.out, "{d} {d} {d} {d}", .{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, box[2] - box[0] + 1, box[3] - box[1] + 1 });
        }
        if (eql(cmd, "png") or eql(cmd, "pixel")) {
            const path = it.next() orelse return error.MissingArg;
            const data = try sys.readFileAlloc(self.gpa, path, 256 * 1024 * 1024);
            defer self.gpa.free(data);
            var img = try kit.png.decode(self.gpa, data);
            defer img.deinit(self.gpa);
            if (eql(cmd, "png")) return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ img.width, img.height });
            const x = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
            const y = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
            if (x >= img.width or y >= img.height) return error.OutOfImage;
            return std.fmt.bufPrint(&self.out, "{x:0>8}", .{img.pixels[@as(usize, y) * img.width + x]});
        }
        if (eql(cmd, "mkpng")) {
            // a W x H picture: a dark grey frame around a RRGGBB rectangle
            const path = it.next() orelse return error.MissingArg;
            const w = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
            const h = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
            const rgb = try std.fmt.parseInt(u32, trimHex(it.next() orelse return error.MissingArg), 16);
            const px = try self.gpa.alloc(u32, @as(usize, w) * h);
            defer self.gpa.free(px);
            for (px, 0..) |*p, i| {
                const x = i % w;
                const y = i / w;
                const inner = x >= w / 5 and x < w - w / 5 and y >= h / 5 and y < h - h / 5;
                p.* = if (inner) 0xFF000000 | rgb else 0xFF303030;
            }
            return self.writePng(path, px, w, h);
        }
        if (eql(cmd, "textpng")) {
            // black text on white, in Shotlet's own text renderer
            const path = it.next() orelse return error.MissingArg;
            const size = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            const first = it.next() orelse return error.MissingArg;
            const s = line[@intFromPtr(first.ptr) - @intFromPtr(line.ptr) ..];
            kit.text.init(self.gpa);
            defer kit.text.deinit();
            if (!kit.text.available()) return error.NoFont;
            const w: u32 = @intCast(kit.text.width(size, s) + 80);
            const h: u32 = @intFromFloat(size * 3);
            const px = try self.gpa.alloc(u32, @as(usize, w) * h);
            defer self.gpa.free(px);
            @memset(px, 0xFFFFFFFF);
            var c = kit.render.Canvas.init(px, w, h);
            kit.text.draw(&c, 40, @intFromFloat(size), size, 0xFF000000, s);
            return self.writePng(path, px, w, h);
        }
        if (eql(cmd, "sleep")) {
            sleepMs(try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10));
            return "";
        }
        if (eql(cmd, "quit")) return "";
        return error.UnknownCommand;
    }

    fn writePng(self: *Driver, path: []const u8, px: []const u32, w: u32, h: u32) ![]const u8 {
        const data = try kit.png.encode(self.gpa, px, w, h);
        defer self.gpa.free(data);
        sys.unlink(path) catch {};
        try sys.writeFile(path, data);
        return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ w, h });
    }

    fn monitor(self: *Driver, name: []const u8) !*Output {
        for (self.outputs.items) |*o| if (eql(o.name(), name)) return o;
        const i = std.fmt.parseInt(usize, name, 10) catch return error.UnknownMonitor;
        if (i >= self.outputs.items.len) return error.UnknownMonitor;
        return &self.outputs.items[i];
    }

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

    fn key(self: *Driver, code: u32, pressed: bool) !void {
        if (self.kwin) {
            try self.conn.request(self.g.fake, fake.keyboard_key, &.{ .{ .uint = code }, .{ .uint = @intFromBool(pressed) } });
        } else {
            try self.conn.request(self.keyboard, vk.key, &.{ .{ .uint = now() }, .{ .uint = code }, .{ .uint = @intFromBool(pressed) } });
            // wlroots does not derive modifiers from a virtual keyboard's
            // keys: say which are held
            const m = modMask(code);
            if (m != 0) {
                if (pressed) self.mods |= m else self.mods &= ~m;
                try self.conn.request(self.keyboard, vk.modifiers, &.{ .{ .uint = self.mods }, .{ .uint = 0 }, .{ .uint = 0 }, .{ .uint = 0 } });
            }
        }
        try self.conn.flush();
        sleepMs(15);
    }

    fn button(self: *Driver, btn: u32, pressed: bool) !void {
        if (self.kwin) {
            try self.conn.request(self.g.fake, fake.button, &.{ .{ .uint = btn }, .{ .uint = @intFromBool(pressed) } });
        } else {
            try self.conn.request(self.pointer, vp.button, &.{ .{ .uint = now() }, .{ .uint = btn }, .{ .uint = @intFromBool(pressed) } });
            try self.conn.request(self.pointer, vp.frame, &.{});
        }
        try self.conn.flush();
        sleepMs(15);
    }

    fn grab(self: *Driver, o: *const Output) !Frame {
        if (self.kwin) return self.grabKWin(o);
        if (self.g.screencopy == 0) return error.NoScreencopy;
        return self.grabScreencopy(o);
    }

    /// One frame of an output with zwlr_screencopy_v1 (v3), into wl_shm.
    fn grabScreencopy(self: *Driver, o: *const Output) !Frame {
        const c = &self.conn;
        const frame = c.newId();
        try c.request(self.g.screencopy, sc_mgr.capture_output, &.{ .{ .new_id = frame }, .{ .int = 0 }, .{ .object = o.id } });
        try c.flush();
        defer c.request(frame, sc_frame.destroy, &.{}) catch {};
        var fmt: ?[4]u32 = null; // format, width, height, stride
        var flags: u32 = 0;
        var pool_fd: sys.fd_t = -1;
        defer if (pool_fd >= 0) sys.close(pool_fd);
        var mem: []align(std.heap.page_size_min) u8 = &.{};
        defer if (mem.len > 0) sys.munmap(mem);
        var buffer: u32 = 0;
        defer if (buffer != 0) c.request(buffer, wl.wl_buffer.destroy, &.{}) catch {};
        while (true) {
            const ev = try c.readEvent();
            if (ev.object != frame) {
                try self.handle(ev);
                continue;
            }
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                sc_frame.ev_buffer => {
                    const f = [4]u32{ try r.uint(), try r.uint(), try r.uint(), try r.uint() };
                    if (fmt == null and (bgrOrder(f[0]) != null)) fmt = f;
                },
                sc_frame.ev_flags => flags = try r.uint(),
                sc_frame.ev_buffer_done => {
                    const f = fmt orelse return error.NoShmFormat;
                    const size = @as(usize, f[3]) * f[2];
                    pool_fd = try sys.memfdCreate("shot", 0);
                    try sys.ftruncate(pool_fd, size);
                    mem = try sys.mmapRw(pool_fd, size);
                    const pool = c.newId();
                    try c.request(self.g.shm, wl.wl_shm.create_pool, &.{ .{ .new_id = pool }, .{ .fd = pool_fd }, .{ .int = @intCast(size) } });
                    buffer = c.newId();
                    try c.request(pool, wl.wl_shm_pool.create_buffer, &.{ .{ .new_id = buffer }, .{ .int = 0 }, .{ .int = @intCast(f[1]) }, .{ .int = @intCast(f[2]) }, .{ .int = @intCast(f[3]) }, .{ .uint = f[0] } });
                    try c.request(pool, wl.wl_shm_pool.destroy, &.{});
                    try c.request(frame, sc_frame.copy, &.{.{ .object = buffer }});
                    try c.flush();
                },
                sc_frame.ev_failed => return error.ScreencopyFailed,
                sc_frame.ev_ready => {
                    const f = fmt.?;
                    const px = try self.gpa.alloc(u32, @as(usize, f[1]) * f[2]);
                    for (0..f[2]) |y| {
                        const sy = if (flags & 1 != 0) f[2] - 1 - y else y;
                        const row = mem[sy * f[3] ..][0 .. f[1] * 4];
                        const swap = bgrOrder(f[0]).?;
                        for (0..f[1]) |x| {
                            const p = std.mem.readInt(u32, row[x * 4 ..][0..4], .little);
                            px[y * f[1] + x] = 0xFF000000 | if (swap) (p & 0xFF00) | ((p >> 16) & 0xFF) | ((p & 0xFF) << 16) else p;
                        }
                    }
                    return .{ .pixels = px, .width = f[1], .height = f[2] };
                },
                else => {},
            }
        }
    }

    /// One frame of an output with org.kde.KWin.ScreenShot2.CaptureScreen:
    /// raw pixels written to a pipe, described by the reply.
    fn grabKWin(self: *Driver, o: *const Output) !Frame {
        const bus = &(self.bus orelse return error.NoBus);
        const p = try sys.pipe();
        defer sys.close(p[0]);
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(o.name());
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("native-resolution");
        try m.putVariantBool(true);
        m.endArray(arr);
        try m.putU32(0); // fd index
        const serial = bus.callMethodFds("org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", "CaptureScreen", "sa{sv}h", m.buf.items, &.{p[1]}) catch |err| {
            sys.close(p[1]);
            return err;
        };
        sys.close(p[1]);
        var msg = try bus.waitReplyTimeout(serial, 10_000);
        defer msg.deinit(self.gpa);
        if (msg.type == .@"error") {
            var er = msg.reader();
            std.debug.print("wldrive: ScreenShot2: {s}\n", .{er.readString() catch "?"});
            return error.ScreenShotRefused;
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
            if (eql(e.key, "width")) w = v else if (eql(e.key, "height")) h = v else if (eql(e.key, "stride")) stride = v else if (eql(e.key, "format")) format = v;
        }
        // QImage::Format_RGB32 (4), ARGB32 (5), ARGB32_Premultiplied (6)
        if (format < 4 or format > 6 or w == 0 or h == 0) return error.UnknownImageFormat;
        const size = @as(usize, stride) * h;
        const raw = try self.gpa.alloc(u8, size);
        defer self.gpa.free(raw);
        var got: usize = 0;
        const deadline = sys.monoMs() + 10_000;
        while (got < size) {
            if (!try sys.waitReadable(p[0], deadline)) return error.ShortImage;
            const n = try sys.read(p[0], raw[got..]);
            if (n == 0) return error.ShortImage;
            got += n;
        }
        const px = try self.gpa.alloc(u32, @as(usize, w) * h);
        for (0..h) |y| for (0..w) |x| {
            px[y * w + x] = std.mem.readInt(u32, raw[y * stride + x * 4 ..][0..4], .little) | 0xFF000000;
        };
        return .{ .pixels = px, .width = w, .height = h };
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

/// xkb modifier masks of the us keymap's modifier keys
fn modMask(code: u32) u32 {
    return switch (code) {
        42, 54 => 1, // Shift
        29, 97 => 4, // Control
        56 => 8, // Mod1 (Alt)
        125 => 64, // Mod4 (Super)
        100 => 128, // Mod5 (AltGr)
        else => 0,
    };
}

fn findBlob(gpa: std.mem.Allocator, px: []const u32, w: u32, h: u32, rgb: u32, tol: u32, min_w: u32) ![4]u32 {
    const near = struct {
        fn f(p: u32, c: u32, t: u32) bool {
            inline for (.{ 0, 8, 16 }) |sh| {
                const a: i32 = @intCast((p >> sh) & 0xFF);
                const b: i32 = @intCast((c >> sh) & 0xFF);
                if (@abs(a - b) > t) return false;
            }
            return true;
        }
    }.f;
    var seen = try gpa.alloc(bool, px.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (px, 0..) |p, start| {
        if (seen[start] or !near(p, rgb, tol)) continue;
        try stack.append(gpa, start);
        seen[start] = true;
        var box = [4]u32{ w, h, 0, 0 };
        while (stack.pop()) |i| {
            const x: u32 = @intCast(i % w);
            const y: u32 = @intCast(i / w);
            box = .{ @min(box[0], x), @min(box[1], y), @max(box[2], x), @max(box[3], y) };
            const nbrs = [4]?usize{
                if (x > 0) i - 1 else null,
                if (x + 1 < w) i + 1 else null,
                if (y > 0) i - w else null,
                if (y + 1 < h) i + w else null,
            };
            for (nbrs) |n| if (n) |j| if (!seen[j] and near(px[j], rgb, tol)) {
                seen[j] = true;
                try stack.append(gpa, j);
            };
        }
        if (box[2] - box[0] + 1 >= min_w) return box;
    }
    return error.NotFound;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn trimHex(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
}

fn sleepMs(ms: u32) void {
    var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// evdev key codes by name (US physical positions)
fn keyCode(name: []const u8) ?u32 {
    if (name.len > 1 and name[0] == '#') return std.fmt.parseInt(u32, name[1..], 10) catch null;
    if (name.len == 1) {
        const c = name[0];
        if (std.mem.indexOfScalar(u8, "qwertyuiop", c)) |i| return @intCast(16 + i);
        if (std.mem.indexOfScalar(u8, "asdfghjkl", c)) |i| return @intCast(30 + i);
        if (std.mem.indexOfScalar(u8, "zxcvbnm", c)) |i| return @intCast(44 + i);
        if (c >= '1' and c <= '9') return @intCast(2 + c - '1');
        if (c == '0') return 11;
    }
    const table = [_]struct { []const u8, u32 }{
        .{ "esc", 1 },        .{ "minus", 12 },     .{ "equal", 13 },      .{ "backspace", 14 },
        .{ "tab", 15 },       .{ "leftbrace", 26 }, .{ "rightbrace", 27 }, .{ "enter", 28 },
        .{ "ctrl", 29 },      .{ "semicolon", 39 }, .{ "apostrophe", 40 }, .{ "grave", 41 },
        .{ "shift", 42 },     .{ "backslash", 43 }, .{ "comma", 51 },      .{ "dot", 52 },
        .{ "slash", 53 },     .{ "rshift", 54 },    .{ "alt", 56 },        .{ "space", 57 },
        .{ "capslock", 58 },  .{ "f1", 59 },        .{ "f2", 60 },         .{ "rctrl", 97 },
        .{ "altgr", 100 },    .{ "home", 102 },     .{ "up", 103 },        .{ "pageup", 104 },
        .{ "left", 105 },     .{ "right", 106 },    .{ "end", 107 },       .{ "down", 108 },
        .{ "pagedown", 109 }, .{ "insert", 110 },   .{ "delete", 111 },    .{ "super", 125 },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
    return null;
}
