//! shotlet-drive: virtual keyboard and pointer for the end-to-end tests.
//!
//! Runs inside the private session of tools/e2e/session.sh (never on a real
//! desktop: it refuses to start unless HL_INNER is set). It opens a
//! org.gnome.Mutter.RemoteDesktop session plus a linked ScreenCast session
//! recording every monitor named on the command line, so absolute pointer
//! motion can target a monitor and `shot` can grab what the compositor
//! shows. Mutter ends the session when this process disconnects, so it
//! stays alive and reads one command per line on stdin, answering each with
//! one line on stdout: `ok [value]` or `err <reason>`.
//!
//!   key COMBO [down|up]   tap (or press/release) evdev keys: ctrl+shift+s,
//!                         altgr+e, semicolon, 30 (raw evdev code)
//!   hold NAME MS          press, wait MS, release (key repeat)
//!   keysym HEX            tap a keysym (mutter picks the keycode)
//!   move MON X Y          absolute motion, logical pixels of monitor MON
//!   rel DX DY             relative motion
//!   down|up|click [BTN]   left (default), right, middle
//!   wheel STEPS           discrete vertical scroll (+ is down)
//!   shot MON PATH         write the monitor's current picture as a PNG
//!   find MON RRGGBB [TOL] answer "cx cy w h" of the first blob of that colour
//!   png PATH              answer the image size, WxH
//!   pixel PATH X Y        answer one pixel as AARRGGBB hex
//!   sleep MS
//!   quit

const std = @import("std");
const kit = @import("shotlet");
const dbus = kit.dbus;
const sys = kit.sys;

const rd_dest = "org.gnome.Mutter.RemoteDesktop";
const sc_dest = "org.gnome.Mutter.ScreenCast";
const rd_session_iface = "org.gnome.Mutter.RemoteDesktop.Session";
const sc_session_iface = "org.gnome.Mutter.ScreenCast.Session";

const Monitor = struct {
    connector: []const u8,
    stream: []u8,
    node: u32 = 0,
};

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const vars = init.environ_map;
    if (vars.get("HL_INNER") == null) {
        std.debug.print("shotlet-drive: run me inside tools/e2e/session.sh\n", .{});
        std.process.exit(2);
    }
    const bus = vars.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoBus;
    const runtime = vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;

    var conn = try dbus.Connection.connectSession(gpa, bus);
    defer conn.deinit();

    // remote desktop session (input), then a screencast session tied to it
    const rd_path = try callPath(gpa, &conn, rd_dest, "/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop", "CreateSession", "", &.{});
    const session_id = try getStringProp(gpa, &conn, rd_dest, rd_path, rd_session_iface, "SessionId");
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    {
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("remote-desktop-session-id");
        try m.putVariantString(session_id);
        m.endArray(arr);
    }
    const sc_path = try callPath(gpa, &conn, sc_dest, "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession", "a{sv}", m.buf.items);

    try conn.addMatch("type='signal',interface='org.gnome.Mutter.ScreenCast.Stream',member='PipeWireStreamAdded'");
    var mons: std.ArrayList(Monitor) = .empty;
    for (args[1..]) |connector| {
        m.buf.clearRetainingCapacity();
        try m.putString(connector);
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("cursor-mode");
        try m.putVariantU32(1); // embedded: screenshots show the pointer
        m.endArray(arr);
        const stream = try callPath(gpa, &conn, sc_dest, sc_path, sc_session_iface, "RecordMonitor", "sa{sv}", m.buf.items);
        try mons.append(arena, .{ .connector = connector, .stream = stream });
    }
    try callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Start", "", &.{});

    // every stream announces its PipeWire node once started
    const deadline = sys.monoMs() + 10_000;
    var missing = mons.items.len;
    while (missing > 0) {
        var msg = (try conn.nextMessageDeadline(deadline)) orelse return error.NoPipeWireStream;
        defer msg.deinit(gpa);
        if (!msg.isSignal("org.gnome.Mutter.ScreenCast.Stream", "PipeWireStreamAdded")) continue;
        var r = msg.reader();
        const node = try r.readU32();
        for (mons.items) |*mon| {
            if (mon.node == 0 and std.mem.eql(u8, mon.stream, msg.path orelse "")) {
                mon.node = node;
                missing -= 1;
            }
        }
    }

    var d: Driver = .{ .gpa = gpa, .conn = &conn, .rd = rd_path, .mons = mons.items, .runtime = runtime };
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
        // drop signals and stray replies queued meanwhile
        while (conn.hasPending()) {
            var msg = (try conn.nextMessageDeadline(0)) orelse break;
            msg.deinit(gpa);
        }
    }
    callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Stop", "", &.{}) catch {};
}

fn reply(comptime fmt: []const u8, args: anytype) void {
    var out: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&out, fmt ++ "\n", args) catch "err reply too long\n";
    sys.writeAll(1, s) catch {};
}

const Driver = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    rd: []const u8,
    mons: []Monitor,
    runtime: []const u8,
    out: [64]u8 = undefined,

    fn run(self: *Driver, line: []const u8) ![]const u8 {
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
            const press = !eql(mode, "up");
            const release = !eql(mode, "down");
            if (press) for (codes[0..n]) |c| try self.keycode(c, true);
            if (release) {
                var i = n;
                while (i > 0) {
                    i -= 1;
                    try self.keycode(codes[i], false);
                }
            }
            return "";
        }
        if (eql(cmd, "hold")) {
            const code = keyCode(it.next() orelse return error.MissingArg) orelse return error.UnknownKey;
            const ms = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
            try self.keycode(code, true);
            sleepMs(ms);
            try self.keycode(code, false);
            return "";
        }
        if (eql(cmd, "keysym")) {
            const sym = try std.fmt.parseInt(u32, trimHex(it.next() orelse return error.MissingArg), 16);
            for ([_]bool{ true, false }) |state| {
                var m = dbus.Marshal.init(self.gpa);
                defer m.deinit();
                try m.putU32(sym);
                try m.putBool(state);
                try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyKeyboardKeysym", "ub", m.buf.items);
            }
            return "";
        }
        if (eql(cmd, "move")) {
            const mon = try self.monitor(it.next() orelse return error.MissingArg);
            const x = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            const y = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            var m = dbus.Marshal.init(self.gpa);
            defer m.deinit();
            try m.putString(mon.stream);
            try putDouble(&m, x);
            try putDouble(&m, y);
            try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyPointerMotionAbsolute", "sdd", m.buf.items);
            // let the client see enter/motion before a following click
            sleepMs(40);
            return "";
        }
        if (eql(cmd, "rel")) {
            const dx = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            const dy = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingArg);
            var m = dbus.Marshal.init(self.gpa);
            defer m.deinit();
            try putDouble(&m, dx);
            try putDouble(&m, dy);
            try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyPointerMotionRelative", "dd", m.buf.items);
            return "";
        }
        if (eql(cmd, "down") or eql(cmd, "up") or eql(cmd, "click")) {
            const name = it.next() orelse "left";
            const btn: i32 = if (eql(name, "left")) 0x110 else if (eql(name, "right")) 0x111 else if (eql(name, "middle")) 0x112 else return error.UnknownButton;
            if (!eql(cmd, "up")) try self.button(btn, true);
            if (!eql(cmd, "down")) try self.button(btn, false);
            return "";
        }
        if (eql(cmd, "wheel")) {
            const steps = try std.fmt.parseInt(i32, it.next() orelse return error.MissingArg, 10);
            var m = dbus.Marshal.init(self.gpa);
            defer m.deinit();
            try m.putU32(0); // vertical
            try m.putI32(steps);
            try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyPointerAxisDiscrete", "ui", m.buf.items);
            return "";
        }
        if (eql(cmd, "shot")) {
            const mon = try self.monitor(it.next() orelse return error.MissingArg);
            const path = it.next() orelse return error.MissingArg;
            return self.shot(mon, path);
        }
        if (eql(cmd, "find")) {
            const mon = try self.monitor(it.next() orelse return error.MissingArg);
            const rgb = try std.fmt.parseInt(u32, trimHex(it.next() orelse return error.MissingArg), 16);
            const tol = try std.fmt.parseInt(u32, it.next() orelse "24", 10);
            var frame = try self.grab(mon);
            defer frame.deinit();
            const box = try findBlob(self.gpa, frame.pixels, frame.width, frame.height, rgb, tol);
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
        if (eql(cmd, "sleep")) {
            sleepMs(try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10));
            return "";
        }
        if (eql(cmd, "monitors")) {
            var w: usize = 0;
            for (self.mons) |mon| {
                const s = std.fmt.bufPrint(self.out[w..], "{s}{s}", .{ if (w > 0) " " else "", mon.connector }) catch break;
                w += s.len;
            }
            return self.out[0..w];
        }
        if (eql(cmd, "quit")) return "";
        return error.UnknownCommand;
    }

    fn monitor(self: *Driver, name: []const u8) !*Monitor {
        for (self.mons) |*mon| if (eql(mon.connector, name)) return mon;
        const i = std.fmt.parseInt(usize, name, 10) catch return error.UnknownMonitor;
        if (i >= self.mons.len) return error.UnknownMonitor;
        return &self.mons[i];
    }

    fn keycode(self: *Driver, code: u32, state: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putU32(code);
        try m.putBool(state);
        try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyKeyboardKeycode", "ub", m.buf.items);
        // give the compositor a beat so clients see distinct events
        sleepMs(15);
    }

    fn button(self: *Driver, btn: i32, state: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putI32(btn);
        try m.putBool(state);
        try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, "NotifyPointerButton", "ib", m.buf.items);
        sleepMs(15);
    }

    /// The monitor's current picture, over a fresh PipeWire connection.
    fn grab(self: *Driver, mon: *Monitor) !kit.pw.Frame {
        var sock_path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&sock_path, "{s}/pipewire-0", .{self.runtime});
        const fd = try sys.socketUnixStream();
        sys.connectUnix(fd, p) catch |err| {
            sys.close(fd);
            return err;
        };
        var frame: [1]kit.pw.Frame = undefined;
        try kit.pw.grabFrames(fd, &.{mon.node}, &frame, 5000);
        return frame[0];
    }

    fn shot(self: *Driver, mon: *Monitor, path: []const u8) ![]const u8 {
        var frame = try self.grab(mon);
        defer frame.deinit();
        const data = try kit.png.encode(self.gpa, frame.pixels, frame.width, frame.height);
        defer self.gpa.free(data);
        sys.unlink(path) catch {};
        try sys.writeFile(path, data);
        return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ frame.width, frame.height }) catch "";
    }
};

/// Bounding box (x0, y0, x1, y1) of the first blob, in reading order, of
/// pixels within `tol` (per channel) of `rgb`: e.g. a dialog's accent
/// coloured default button.
fn findBlob(gpa: std.mem.Allocator, px: []const u32, w: u32, h: u32, rgb: u32, tol: u32) ![4]u32 {
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
    const start = for (px, 0..) |p, i| {
        if (near(p, rgb, tol)) break i;
    } else return error.NotFound;
    var seen = try gpa.alloc(bool, px.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
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
    return box;
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

fn putDouble(m: *dbus.Marshal, v: f64) !void {
    try m.putU64(@bitCast(v));
}

/// evdev key codes by name (US physical positions; the compositor's keymap
/// decides what they type)
fn keyCode(name: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, name, 10)) |c| return c else |_| {}
    if (name.len == 1) {
        const c = name[0];
        const letters = "qwertyuiop"; // 16..25
        const row2 = "asdfghjkl"; // 30..38
        const row3 = "zxcvbnm"; // 44..50
        if (std.mem.indexOfScalar(u8, letters, c)) |i| return @intCast(16 + i);
        if (std.mem.indexOfScalar(u8, row2, c)) |i| return @intCast(30 + i);
        if (std.mem.indexOfScalar(u8, row3, c)) |i| return @intCast(44 + i);
        if (c >= '1' and c <= '9') return @intCast(2 + c - '1');
        if (c == '0') return 11;
    }
    const table = [_]struct { []const u8, u32 }{
        .{ "esc", 1 },       .{ "minus", 12 },     .{ "equal", 13 },      .{ "backspace", 14 },
        .{ "tab", 15 },      .{ "leftbrace", 26 }, .{ "rightbrace", 27 }, .{ "enter", 28 },
        .{ "ctrl", 29 },     .{ "semicolon", 39 }, .{ "apostrophe", 40 }, .{ "grave", 41 },
        .{ "shift", 42 },    .{ "backslash", 43 }, .{ "comma", 51 },      .{ "dot", 52 },
        .{ "slash", 53 },    .{ "rshift", 54 },    .{ "alt", 56 },        .{ "space", 57 },
        .{ "capslock", 58 }, .{ "f1", 59 },        .{ "f2", 60 },         .{ "102nd", 86 },
        .{ "rctrl", 97 },    .{ "altgr", 100 },    .{ "home", 102 },      .{ "up", 103 },
        .{ "pageup", 104 },  .{ "left", 105 },     .{ "right", 106 },     .{ "end", 107 },
        .{ "down", 108 },    .{ "pagedown", 109 }, .{ "insert", 110 },    .{ "delete", 111 },
        .{ "super", 125 },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
    return null;
}

fn callPath(gpa: std.mem.Allocator, conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ![]u8 {
    const serial = try conn.callMethod(dest, path, iface, member, sig, body);
    var msg = try conn.waitReply(serial);
    defer msg.deinit(gpa);
    var r = msg.reader();
    return gpa.dupe(u8, try r.readString());
}

fn callVoid(conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !void {
    const serial = try conn.callMethod(dest, path, iface, member, sig, body);
    var msg = try conn.waitReply(serial);
    msg.deinit(conn.alloc);
}

fn getStringProp(gpa: std.mem.Allocator, conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, prop: []const u8) ![]u8 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(iface);
    try m.putString(prop);
    const serial = try conn.callMethod(dest, path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items);
    var msg = try conn.waitReply(serial);
    defer msg.deinit(gpa);
    var r = msg.reader();
    return switch (try r.readVariant()) {
        .string => |s| gpa.dupe(u8, s),
        else => error.BadProperty,
    };
}
