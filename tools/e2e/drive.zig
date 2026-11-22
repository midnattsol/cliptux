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
//!                         altgr+e, semicolon, 2, #30 (raw evdev code)
//!   hold NAME MS          press, wait MS, release (key repeat)
//!   keysym HEX            tap a keysym (mutter picks the keycode)
//!   move MON X Y          absolute motion, logical pixels of monitor MON
//!   rel DX DY             relative motion
//!   down|up|click [BTN]   left (default), right, middle
//!   wheel STEPS           discrete vertical scroll (+ is down)
//!   shot MON PATH         write the monitor's current picture as a PNG
//!   find MON RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
//!                         answer "cx cy w h" of the first blob of that colour
//!                         (at least MINW wide)
//!   png PATH              answer the image size, WxH
//!   pixel PATH X Y        answer one pixel as AARRGGBB hex
//!   runs PATH X RRGGBB [TOL]  how many vertical runs of that colour
//!                         column X of the PNG has
//!   film MON              start filming the monitor (drive/film.zig)
//!   cut DIR|- [X0 Y0 X1 Y1]  stop filming; answer "frames N ghosts G
//!                         blends B worst I PERMILLE" (the box, monitor
//!                         pixels, left out); DIR gets each frame as PNG
//!   sni-watcher MS        own org.kde.StatusNotifierWatcher; answer the
//!                         first RegisterStatusNotifierItem within MS
//!   sleep MS
//!   quit

const std = @import("std");
const kit = @import("shotlet");
const dbus = kit.dbus;
const sys = kit.sys;
const pixels = @import("drive/pixels.zig");
const keys = @import("drive/keys.zig");
const film = @import("drive/film.zig");

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

    const rd_path = try createSession(gpa, &conn);
    const mons = try recordMonitors(gpa, arena, &conn, rd_path, args[1..]);
    try callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Start", "", &.{});
    try waitStreams(gpa, &conn, mons);

    var d: Driver = .{ .gpa = gpa, .conn = &conn, .rd = rd_path, .mons = mons, .runtime = runtime };
    reply("ok ready", .{});
    try serve(&d);
    callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Stop", "", &.{}) catch {};
}

/// A remote desktop session (input); its object path.
fn createSession(gpa: std.mem.Allocator, conn: *dbus.Connection) ![]u8 {
    return callPath(gpa, conn, rd_dest, "/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop", "CreateSession", "", &.{});
}

/// A screencast session tied to the remote desktop session at `rd_path`,
/// recording each monitor in `connectors`.
fn recordMonitors(gpa: std.mem.Allocator, arena: std.mem.Allocator, conn: *dbus.Connection, rd_path: []const u8, connectors: []const [:0]const u8) ![]Monitor {
    const session_id = try getStringProp(gpa, conn, rd_dest, rd_path, rd_session_iface, "SessionId");
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    {
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("remote-desktop-session-id");
        try m.putVariantString(session_id);
        m.endArray(arr);
    }
    const sc_path = try callPath(gpa, conn, sc_dest, "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession", "a{sv}", m.buf.items);

    try conn.addMatch("type='signal',interface='org.gnome.Mutter.ScreenCast.Stream',member='PipeWireStreamAdded'");
    var mons: std.ArrayList(Monitor) = .empty;
    for (connectors) |connector| {
        m.buf.clearRetainingCapacity();
        try m.putString(connector);
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("cursor-mode");
        try m.putVariantU32(1); // embedded: screenshots show the pointer
        m.endArray(arr);
        const stream = try callPath(gpa, conn, sc_dest, sc_path, sc_session_iface, "RecordMonitor", "sa{sv}", m.buf.items);
        try mons.append(arena, .{ .connector = connector, .stream = stream });
    }
    return mons.items;
}

/// Every stream announces its PipeWire node once started: note each.
fn waitStreams(gpa: std.mem.Allocator, conn: *dbus.Connection, mons: []Monitor) !void {
    const deadline = sys.monoMs() + 10_000;
    var missing = mons.len;
    while (missing > 0) {
        var msg = (try conn.nextMessageDeadline(deadline)) orelse return error.NoPipeWireStream;
        defer msg.deinit(gpa);
        if (!msg.isSignal("org.gnome.Mutter.ScreenCast.Stream", "PipeWireStreamAdded")) continue;
        var r = msg.reader();
        const node = try r.readU32();
        for (mons) |*mon| {
            if (mon.node == 0 and std.mem.eql(u8, mon.stream, msg.path orelse "")) {
                mon.node = node;
                missing -= 1;
            }
        }
    }
}

/// Answer one command per line on stdin until `quit` or its end.
fn serve(d: *Driver) !void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const quit = d.answer(std.mem.trim(u8, buf[0..nl], " \t\r"));
            std.mem.copyForwards(u8, buf[0..], buf[nl + 1 .. len]);
            len -= nl + 1;
            if (quit) return;
            continue;
        }
        if (len == buf.len) return error.LineTooLong;
        const n = try sys.read(0, buf[len..]);
        if (n == 0) return;
        len += n;
        try d.dropPending();
    }
}

fn reply(comptime fmt: []const u8, args: anytype) void {
    var out: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&out, fmt ++ "\n", args) catch "err reply too long\n";
    sys.writeAll(1, s) catch {};
}

const Args = std.mem.TokenIterator(u8, .any);

/// The next argument of a command.
fn arg(it: *Args) ![]const u8 {
    return it.next() orelse error.MissingArg;
}

const Driver = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    rd: []const u8,
    mons: []Monitor,
    runtime: []const u8,
    out: [64]u8 = undefined,
    film: ?*film.Film = null,

    /// Run one line (blank and # lines are ignored) and reply to it;
    /// whether it was `quit`.
    fn answer(self: *Driver, line: []const u8) bool {
        if (line.len > 0 and line[0] != '#') {
            if (self.run(line)) |val| {
                if (val.len > 0) reply("ok {s}", .{val}) else reply("ok", .{});
            } else |err| reply("err {t}", .{err});
        }
        return std.mem.eql(u8, line, "quit");
    }

    /// Drop signals and stray replies queued meanwhile.
    fn dropPending(self: *Driver) !void {
        while (self.conn.hasPending()) {
            var msg = (try self.conn.nextMessageDeadline(0)) orelse break;
            msg.deinit(self.gpa);
        }
    }

    fn run(self: *Driver, line: []const u8) ![]const u8 {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse return "";
        if (eql(cmd, "key")) return self.cmdKey(&it);
        if (eql(cmd, "hold")) return self.cmdHold(&it);
        if (eql(cmd, "keysym")) return self.cmdKeysym(&it);
        if (eql(cmd, "move")) return self.cmdMove(&it);
        if (eql(cmd, "rel")) return self.cmdRel(&it);
        if (eql(cmd, "down") or eql(cmd, "up") or eql(cmd, "click")) return self.cmdButton(cmd, &it);
        if (eql(cmd, "wheel")) return self.cmdWheel(&it);
        if (eql(cmd, "shot")) return self.shot(try self.monitor(try arg(&it)), try arg(&it));
        if (eql(cmd, "find")) return self.cmdFind(&it);
        if (eql(cmd, "runs")) return self.cmdRuns(&it);
        if (eql(cmd, "png") or eql(cmd, "pixel")) return self.cmdImage(cmd, &it);
        if (eql(cmd, "film")) return self.cmdFilm(&it);
        if (eql(cmd, "cut")) return self.cmdCut(&it);
        if (eql(cmd, "sni-watcher")) return self.cmdSniWatcher(&it);
        if (eql(cmd, "sleep")) {
            sleepMs(try std.fmt.parseInt(u32, try arg(&it), 10));
            return "";
        }
        if (eql(cmd, "monitors")) return self.cmdMonitors();
        if (eql(cmd, "quit")) return "";
        return error.UnknownCommand;
    }

    /// key COMBO [down|up]
    fn cmdKey(self: *Driver, it: *Args) ![]const u8 {
        const combo = try arg(it);
        const mode = it.next() orelse "tap";
        var codes: [8]u32 = undefined;
        const n = try keys.parseCombo(combo, &codes);
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

    /// hold NAME MS
    fn cmdHold(self: *Driver, it: *Args) ![]const u8 {
        const code = keys.keyCode(try arg(it)) orelse return error.UnknownKey;
        const ms = try std.fmt.parseInt(u32, try arg(it), 10);
        try self.keycode(code, true);
        sleepMs(ms);
        try self.keycode(code, false);
        return "";
    }

    /// keysym HEX
    fn cmdKeysym(self: *Driver, it: *Args) ![]const u8 {
        const sym = try std.fmt.parseInt(u32, trimHex(try arg(it)), 16);
        for ([_]bool{ true, false }) |state| {
            var m = dbus.Marshal.init(self.gpa);
            defer m.deinit();
            try m.putU32(sym);
            try m.putBool(state);
            try self.notify("NotifyKeyboardKeysym", "ub", &m);
        }
        return "";
    }

    /// move MON X Y
    fn cmdMove(self: *Driver, it: *Args) ![]const u8 {
        const mon = try self.monitor(try arg(it));
        const x = try std.fmt.parseFloat(f64, try arg(it));
        const y = try std.fmt.parseFloat(f64, try arg(it));
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(mon.stream);
        try putDouble(&m, x);
        try putDouble(&m, y);
        try self.notify("NotifyPointerMotionAbsolute", "sdd", &m);
        // let the client see enter/motion before a following click
        sleepMs(40);
        return "";
    }

    /// rel DX DY
    fn cmdRel(self: *Driver, it: *Args) ![]const u8 {
        const dx = try std.fmt.parseFloat(f64, try arg(it));
        const dy = try std.fmt.parseFloat(f64, try arg(it));
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try putDouble(&m, dx);
        try putDouble(&m, dy);
        try self.notify("NotifyPointerMotionRelative", "dd", &m);
        return "";
    }

    /// down|up|click [BTN]
    fn cmdButton(self: *Driver, cmd: []const u8, it: *Args) ![]const u8 {
        const name = it.next() orelse "left";
        const btn: i32 = if (eql(name, "left")) 0x110 else if (eql(name, "right")) 0x111 else if (eql(name, "middle")) 0x112 else return error.UnknownButton;
        if (!eql(cmd, "up")) try self.button(btn, true);
        if (!eql(cmd, "down")) try self.button(btn, false);
        return "";
    }

    /// wheel STEPS
    fn cmdWheel(self: *Driver, it: *Args) ![]const u8 {
        const steps = try std.fmt.parseInt(i32, try arg(it), 10);
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putU32(0); // vertical
        try m.putI32(steps);
        try self.notify("NotifyPointerAxisDiscrete", "ui", &m);
        return "";
    }

    /// find MON RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
    fn cmdFind(self: *Driver, it: *Args) ![]const u8 {
        const mon = try self.monitor(try arg(it));
        const rgb = try std.fmt.parseInt(u32, trimHex(try arg(it)), 16);
        const tol = try std.fmt.parseInt(u32, it.next() orelse "24", 10);
        const min_w = try std.fmt.parseInt(u32, it.next() orelse "1", 10);
        var frame = try self.grab(mon);
        defer frame.deinit();
        // optional region X0 Y0 X1 Y1: pixels outside it never match
        if (it.next()) |first| {
            var region: [4]u32 = undefined;
            region[0] = try std.fmt.parseInt(u32, first, 10);
            for (region[1..]) |*v| v.* = try std.fmt.parseInt(u32, try arg(it), 10);
            pixels.maskOutside(frame.pixels, frame.width, region, rgb);
        }
        const box = try pixels.findBlob(self.gpa, frame.pixels, frame.width, frame.height, rgb, tol, min_w);
        return std.fmt.bufPrint(&self.out, "{d} {d} {d} {d}", .{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, box[2] - box[0] + 1, box[3] - box[1] + 1 });
    }

    /// runs PATH X RRGGBB [TOL]: vertical runs of that colour in column X
    fn cmdRuns(self: *Driver, it: *Args) ![]const u8 {
        var img = try self.loadPng(try arg(it));
        defer img.deinit(self.gpa);
        const x = try std.fmt.parseInt(u32, try arg(it), 10);
        const want = try std.fmt.parseInt(u32, try arg(it), 16);
        const tol = try std.fmt.parseInt(u32, it.next() orelse "8", 10);
        if (x >= img.width) return error.OutOfImage;
        return std.fmt.bufPrint(&self.out, "{d}", .{pixels.columnRuns(img.pixels, img.width, img.height, x, want, tol)});
    }

    /// png PATH | pixel PATH X Y
    fn cmdImage(self: *Driver, cmd: []const u8, it: *Args) ![]const u8 {
        var img = try self.loadPng(try arg(it));
        defer img.deinit(self.gpa);
        if (eql(cmd, "png")) return std.fmt.bufPrint(&self.out, "{d}x{d}", .{ img.width, img.height });
        const x = try std.fmt.parseInt(u32, try arg(it), 10);
        const y = try std.fmt.parseInt(u32, try arg(it), 10);
        if (x >= img.width or y >= img.height) return error.OutOfImage;
        return std.fmt.bufPrint(&self.out, "{x:0>8}", .{img.pixels[@as(usize, y) * img.width + x]});
    }

    /// film MON: film until `cut`, from the first frame on
    fn cmdFilm(self: *Driver, it: *Args) ![]const u8 {
        if (self.film != null) return error.Filming;
        const mon = try self.monitor(try arg(it));
        var probe = try self.grab(mon);
        const w = probe.width;
        const h = probe.height;
        probe.deinit();
        const f = try film.Film.start(self.gpa, mon.node, w, h);
        self.film = f;
        const deadline = sys.monoMs() + 5000;
        while (f.count() == 0) {
            if (sys.monoMs() > deadline) return error.NoFrames;
            sleepMs(5);
        }
        return "";
    }

    /// cut DIR|- [X0 Y0 X1 Y1]
    fn cmdCut(self: *Driver, it: *Args) ![]const u8 {
        const f = self.film orelse return error.NotFilming;
        self.film = null;
        f.stop();
        defer f.deinit();
        const n = f.count();
        const dir = try arg(it);
        var mask: ?film.Mask = null;
        if (it.next()) |first| {
            var m: film.Mask = undefined;
            m[0] = try std.fmt.parseInt(u32, first, 10) / film.shrink;
            for (m[1..]) |*v| v.* = try std.fmt.parseInt(u32, try arg(it), 10) / film.shrink;
            mask = m;
        }
        if (!eql(dir, "-")) for (0..n) |i| {
            var name: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&name, "{s}/f{d:0>4}.png", .{ dir, i });
            const data = try kit.png.encode(self.gpa, f.frame(@intCast(i)), f.fw, f.fh);
            defer self.gpa.free(data);
            try sys.writeFile(path, data);
        };
        const v = film.judge(f, n, mask);
        return std.fmt.bufPrint(&self.out, "frames {d} ghosts {d} blends {d} worst {d} {d}{s}", .{ v.frames, v.ghosts, v.blends, v.worst, v.worst_permille, if (f.full) " full" else "" });
    }

    /// sni-watcher MS: play org.kde.StatusNotifierWatcher until an item
    /// registers
    fn cmdSniWatcher(self: *Driver, it: *Args) ![]const u8 {
        const ms = try std.fmt.parseInt(u32, it.next() orelse "5000", 10);
        if (!try self.conn.requestName("org.kde.StatusNotifierWatcher")) return error.NameTaken;
        const deadline = sys.monoMs() + ms;
        while (try self.conn.nextMessageDeadline(deadline)) |msg_| {
            var msg = msg_;
            defer msg.deinit(self.gpa);
            if (!msg.isCall("org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem")) continue;
            try self.conn.replyTo(&msg, "", &.{});
            var r = msg.reader();
            const item = try r.readString();
            return std.fmt.bufPrint(&self.out, "{s} {s}", .{ msg.sender orelse "?", item }) catch "?";
        }
        return error.NoRegistration;
    }

    /// monitors: the connectors, in command line order
    fn cmdMonitors(self: *Driver) []const u8 {
        var w: usize = 0;
        for (self.mons) |mon| {
            const s = std.fmt.bufPrint(self.out[w..], "{s}{s}", .{ if (w > 0) " " else "", mon.connector }) catch break;
            w += s.len;
        }
        return self.out[0..w];
    }

    fn loadPng(self: *Driver, path: []const u8) !kit.png.Image {
        const data = try sys.readFileAlloc(self.gpa, path, 256 * 1024 * 1024);
        defer self.gpa.free(data);
        return kit.png.decode(self.gpa, data);
    }

    fn monitor(self: *Driver, name: []const u8) !*Monitor {
        for (self.mons) |*mon| if (eql(mon.connector, name)) return mon;
        const i = std.fmt.parseInt(usize, name, 10) catch return error.UnknownMonitor;
        if (i >= self.mons.len) return error.UnknownMonitor;
        return &self.mons[i];
    }

    /// Call a method of the remote desktop session.
    fn notify(self: *Driver, member: []const u8, sig: []const u8, m: *const dbus.Marshal) !void {
        try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, member, sig, m.buf.items);
    }

    fn keycode(self: *Driver, code: u32, state: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putU32(code);
        try m.putBool(state);
        try self.notify("NotifyKeyboardKeycode", "ub", &m);
        // give the compositor a beat so clients see distinct events
        sleepMs(15);
    }

    fn button(self: *Driver, btn: i32, state: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putI32(btn);
        try m.putBool(state);
        try self.notify("NotifyPointerButton", "ib", &m);
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

test {
    _ = film;
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
