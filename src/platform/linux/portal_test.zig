//! Integration test: a private dbus-daemon with a tiny mock
//! org.freedesktop.portal.Desktop written against our own DBus client.
//! Exercises the real request/Response round trip, deadlines and the
//! portal-vanished path. Skipped when dbus-daemon is not installed.

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;

const Mode = enum(u8) { normal, cancel, silent, vanish, mute };

const Mock = struct {
    conn: dbus.Connection,
    mode: std.atomic.Value(u8) = .init(@backingInt(Mode.normal)),
    stop: std.atomic.Value(bool) = .init(false),
    closed_requests: std.atomic.Value(u32) = .init(0),
    /// what the last SaveFile asked for (written by the mock thread,
    /// read by the test after the call returned)
    save_name: [128]u8 = undefined,
    save_name_len: usize = 0,
    save_folder: [256]u8 = undefined,
    save_folder_len: usize = 0,

    fn loop(self: *Mock) void {
        while (!self.stop.load(.acquire)) {
            var msg = (self.conn.nextMessageDeadline(sys.monoMs() + 50) catch return) orelse continue;
            defer msg.deinit(self.conn.alloc);
            self.handle(&msg) catch |err| std.debug.print("mock portal: {t}\n", .{err});
        }
    }

    fn handle(self: *Mock, msg: *const dbus.Message) !void {
        if (msg.type != .method_call) return;
        if (try self.handlePlainCall(msg)) return;

        // request-style calls: find the options dict and its handle_token
        const member = msg.member orelse return;
        const token = try self.readOptions(msg);
        var path_buf: [256]u8 = undefined;
        const path = try requestPath(&path_buf, msg.sender orelse return, token);
        // a hung portal: not even the method reply
        if (self.mode.load(.acquire) == @backingInt(Mode.mute)) return;
        try self.replyRequestPath(msg, path);

        const mode: Mode = @fromBackingInt(@intCast(self.mode.load(.acquire)));
        switch (mode) {
            .silent, .mute => return,
            .vanish => return self.releasePortalName(),
            else => {},
        }
        try self.emitResponse(path, member, mode);
    }

    /// Calls answered directly, without a Request; true when handled.
    fn handlePlainCall(self: *Mock, msg: *const dbus.Message) !bool {
        if (msg.isCall("org.freedesktop.portal.Request", "Close")) {
            _ = self.closed_requests.fetchAdd(1, .release);
            try self.conn.replyTo(msg, "", &.{});
            return true;
        }
        if (msg.isCall("org.freedesktop.portal.Session", "Close")) {
            try self.conn.replyTo(msg, "", &.{});
            return true;
        }
        if (msg.isCall("org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote")) {
            try self.conn.replyError(msg, "org.freedesktop.portal.Error.Failed", "no pipewire here");
            return true;
        }
        return false;
    }

    /// Walk the trailing a{sv} options: return the handle_token and
    /// record SaveFile's current_name and current_folder.
    fn readOptions(self: *Mock, msg: *const dbus.Message) ![]const u8 {
        const sig = msg.signature orelse "";
        var r = msg.reader();
        var idx: usize = 0;
        // skip the arguments before the trailing a{sv}
        while (idx < sig.len and !std.mem.eql(u8, sig[idx..], "a{sv}")) try r.skipType(sig, &idx);
        var token: []const u8 = "t";
        var it = try r.readDictRaw();
        while (try it.next()) |e| {
            if (std.mem.eql(u8, e.key, "handle_token") and std.mem.eql(u8, e.sig, "s")) {
                token = try r.readString();
            } else if (std.mem.eql(u8, e.key, "current_name") and std.mem.eql(u8, e.sig, "s")) {
                const v = try r.readString();
                self.save_name_len = @min(v.len, self.save_name.len);
                @memcpy(self.save_name[0..self.save_name_len], v[0..self.save_name_len]);
            } else if (std.mem.eql(u8, e.key, "current_folder") and std.mem.eql(u8, e.sig, "ay")) {
                const len = try r.readU32();
                const bytes = r.data[r.pos..][0..len];
                r.pos += len;
                self.save_folder_len = @min(bytes.len, self.save_folder.len);
                @memcpy(self.save_folder[0..self.save_folder_len], bytes[0..self.save_folder_len]);
            } else {
                try r.skipValue(e.sig);
            }
        }
        return token;
    }

    /// The Request object path the portal spec predicts for sender + token.
    fn requestPath(buf: []u8, sender: []const u8, token: []const u8) ![]u8 {
        var sender_buf: [64]u8 = undefined;
        var n: usize = 0;
        for (sender) |c| {
            if (c == ':') continue;
            sender_buf[n] = if (c == '.') '_' else c;
            n += 1;
        }
        return std.fmt.bufPrint(buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender_buf[0..n], token });
    }

    fn replyRequestPath(self: *Mock, msg: *const dbus.Message, path: []const u8) !void {
        var m = dbus.Marshal.init(self.conn.alloc);
        defer m.deinit();
        try m.putObjectPath(path);
        try self.conn.replyTo(msg, "o", m.buf.items);
    }

    /// Give up the portal's bus name, as a crashing portal would.
    fn releasePortalName(self: *Mock) !void {
        const a = self.conn.alloc;
        var m = dbus.Marshal.init(a);
        defer m.deinit();
        try m.putString(portal.bus_name);
        const serial = try self.conn.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName", "s", m.buf.items);
        var reply = try self.conn.waitReply(serial);
        reply.deinit(a);
    }

    /// The Response signal: cancelled in cancel mode, else granted with
    /// the results `member` returns.
    fn emitResponse(self: *Mock, path: []const u8, member: []const u8, mode: Mode) !void {
        var m = dbus.Marshal.init(self.conn.alloc);
        defer m.deinit();
        try m.putU32(if (mode == .cancel) 1 else 0);
        const dict = try m.beginArray(8);
        if (std.mem.eql(u8, member, "CreateSession")) {
            try m.beginStruct();
            try m.putString("session_handle");
            try m.putVariantString("/org/freedesktop/portal/desktop/session/1/s");
        } else if (std.mem.eql(u8, member, "Start")) {
            try putStartResults(&m);
        } else if (std.mem.eql(u8, member, "OpenFile")) {
            try putUris(&m, "file:///home/u/Im%C3%A1genes/Shots");
        } else if (std.mem.eql(u8, member, "SaveFile")) {
            try putUris(&m, "file:///tmp/Im%C3%A1genes/my%20shot.png");
        }
        m.endArray(dict);
        try self.conn.emitSignal(path, "org.freedesktop.portal.Request", "Response", "ua{sv}", m.buf.items);
    }

    /// Start's results: two 1280x720 monitors side by side and a token.
    fn putStartResults(m: *dbus.Marshal) !void {
        try m.beginStruct();
        try m.putString("streams");
        try m.putSignature("a(ua{sv})");
        const streams = try m.beginArray(8);
        for ([_][3]i32{ .{ 50, 0, 0 }, .{ 51, 1280, 0 } }) |st| try putStream(m, st);
        m.endArray(streams);
        try m.beginStruct();
        try m.putString("restore_token");
        try m.putVariantString("mock-token");
    }

    /// One stream: node id, then position (x, y) and size 1280x720.
    fn putStream(m: *dbus.Marshal, st: [3]i32) !void {
        try m.beginStruct();
        try m.putU32(@intCast(st[0]));
        const props = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("position");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(st[1]);
        try m.putI32(st[2]);
        try m.beginStruct();
        try m.putString("size");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(1280);
        try m.putI32(720);
        m.endArray(props);
    }

    /// A FileChooser result: "uris" holding one URI.
    fn putUris(m: *dbus.Marshal, uri: []const u8) !void {
        try m.beginStruct();
        try m.putString("uris");
        try m.putSignature("as");
        const uris = try m.beginArray(4);
        try m.putString(uri);
        m.endArray(uris);
    }
};

fn findDbusDaemon() ?[:0]const u8 {
    for ([_][:0]const u8{ "/usr/bin/dbus-daemon", "/bin/dbus-daemon", "/usr/local/bin/dbus-daemon" }) |p| {
        if (sys.fileSize(p)) |_| return p else |_| {}
    }
    return null;
}

const Bus = struct {
    dir: []u8,
    pid: linux.pid_t,
    addr: []u8,

    fn start(alloc: std.mem.Allocator) !Bus {
        const daemon = findDbusDaemon() orelse return error.SkipZigTest;
        const dir = try sys.makeTempDir(alloc, "/tmp", "shotlet-bus");
        errdefer {
            sys.removeTree(dir);
            alloc.free(dir);
        }
        const conf_path = try writeConfig(alloc, dir);
        defer alloc.free(conf_path);
        const arg = try std.fmt.allocPrintSentinel(alloc, "--config-file={s}", .{conf_path}, 0);
        defer alloc.free(arg);

        const pid = try spawnDaemon(daemon, arg);
        errdefer stopPid(pid);
        try waitForSocket(alloc, dir);
        return .{ .dir = dir, .pid = pid, .addr = try std.fmt.allocPrint(alloc, "unix:path={s}/bus", .{dir}) };
    }

    /// Write a permissive session bus config listening in `dir`; returns
    /// its path (owned).
    fn writeConfig(alloc: std.mem.Allocator, dir: []const u8) ![:0]u8 {
        const conf_path = try std.fmt.allocPrintSentinel(alloc, "{s}/bus.conf", .{dir}, 0);
        errdefer alloc.free(conf_path);
        const conf = try std.fmt.allocPrint(alloc,
            \\<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
            \\ "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            \\<busconfig>
            \\  <type>session</type>
            \\  <listen>unix:path={s}/bus</listen>
            \\  <auth>EXTERNAL</auth>
            \\  <policy context="default">
            \\    <allow send_destination="*" eavesdrop="true"/>
            \\    <allow eavesdrop="true"/>
            \\    <allow own="*"/>
            \\  </policy>
            \\</busconfig>
            \\
        , .{dir});
        defer alloc.free(conf);
        try sys.writeFile(conf_path, conf);
        return conf_path;
    }

    /// Fork and exec dbus-daemon in the foreground, its output silenced.
    fn spawnDaemon(daemon: [:0]const u8, config_arg: [:0]const u8) !linux.pid_t {
        const argv = [_:null]?[*:0]const u8{ daemon.ptr, config_arg.ptr, "--nofork", "--nopidfile" };
        const envp = [_:null]?[*:0]const u8{};
        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        if (rc == 0) {
            const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
            if (linux.errno(devnull) == .SUCCESS) {
                _ = linux.dup2(@intCast(devnull), 1);
                _ = linux.dup2(@intCast(devnull), 2);
            }
            _ = linux.execve(daemon.ptr, &argv, &envp);
            linux.exit(127);
        }
        return @intCast(rc);
    }

    /// Wait up to 5 s for the bus socket to appear (else skip the test).
    fn waitForSocket(alloc: std.mem.Allocator, dir: []const u8) !void {
        const sock = try std.fmt.allocPrint(alloc, "{s}/bus", .{dir});
        defer alloc.free(sock);
        const deadline = sys.monoMs() + 5000;
        while (true) {
            if (sys.fileSize(sock)) |_| break else |_| {}
            if (sys.monoMs() > deadline) return error.SkipZigTest;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
    }

    fn stop(self: *Bus, alloc: std.mem.Allocator) void {
        stopPid(self.pid);
        sys.removeTree(self.dir);
        alloc.free(self.dir);
        alloc.free(self.addr);
    }

    fn stopPid(pid: linux.pid_t) void {
        _ = linux.kill(pid, .TERM);
        var status: i32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
    }
};

test "portal round trips against a private bus and a mock portal" {
    const alloc = std.testing.allocator;
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err; // timeouts and a vanishing portal warn
    defer std.testing.log_level = saved_level;

    var bus = try Bus.start(alloc);
    defer bus.stop(alloc);

    var mock = Mock{ .conn = try dbus.Connection.connectSession(std.heap.smp_allocator, bus.addr) };
    try std.testing.expect(try mock.conn.requestName(portal.bus_name));
    const thread = try std.Thread.spawn(.{}, Mock.loop, .{&mock});
    defer {
        mock.stop.store(true, .release);
        thread.join();
        mock.conn.deinit();
    }

    var conn = try dbus.Connection.connectSession(alloc, bus.addr);
    defer conn.deinit();

    try checkScreenCast(alloc, &conn);
    try checkSaveFile(alloc, &conn, &mock);
    try checkChooseFolder(alloc, &conn);

    // the person cancels the dialog
    mock.mode.store(@backingInt(Mode.cancel), .release);
    switch (try portal.screenshot(alloc, &conn, false, portal.timeout_dialog_ms)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }

    try checkSilentPortal(alloc, &conn, &mock);
    try checkMutePortal(alloc, &conn, &mock);
    try checkVanishingPortal(alloc, &conn, &mock);
}

/// ScreenCast: create, select + start with two monitors and a token.
fn checkScreenCast(alloc: std.mem.Allocator, conn: *dbus.Connection) !void {
    const session = switch (try portal.scCreateSession(alloc, conn)) {
        .granted => |s| s,
        else => |o| {
            std.debug.print("CreateSession: {t}\n", .{o});
            return error.TestUnexpectedResult;
        },
    };
    defer alloc.free(session);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/session/1/s", session);
    var started = switch (try portal.scSelectAndStart(alloc, conn, session, "old-token")) {
        .granted => |s| s,
        else => return error.TestUnexpectedResult,
    };
    defer started.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), started.streams.len);
    try std.testing.expectEqual(@as(u32, 51), started.streams[1].node_id);
    try std.testing.expectEqual([2]i32{ 1280, 0 }, started.streams[1].position.?);
    try std.testing.expectEqualStrings("mock-token", started.restore_token.?);
    // a method error is reported as an error, not a hang
    try std.testing.expectError(error.DBusError, portal.scOpenRemote(alloc, conn, session));
}

/// FileChooser: the chosen URI comes back as a decoded path.
fn checkSaveFile(alloc: std.mem.Allocator, conn: *dbus.Connection, mock: *const Mock) !void {
    switch (try portal.saveFile(alloc, conn, .{ .current_name = "shotlet-x.png", .current_folder = "/home/u/Pictures" })) {
        .granted => |p| {
            defer alloc.free(p);
            try std.testing.expectEqualStrings("/tmp/Imágenes/my shot.png", p);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("shotlet-x.png", mock.save_name[0..mock.save_name_len]);
    // current_folder travels as NUL-terminated bytes
    try std.testing.expectEqualStrings("/home/u/Pictures\x00", mock.save_folder[0..mock.save_folder_len]);
}

/// A folder, asked for without blocking (the Settings window).
fn checkChooseFolder(alloc: std.mem.Allocator, conn: *dbus.Connection) !void {
    var req = try portal.beginChooseFolder(alloc, conn, .{ .current_folder = "/home/u" });
    defer req.deinit(alloc);
    const deadline = sys.monoMs() + 5000;
    while (!req.done() and sys.monoMs() < deadline) {
        var msg = (try conn.nextMessageDeadline(sys.monoMs() + 50)) orelse continue;
        if (!(try req.handle(alloc, &msg))) msg.deinit(alloc);
    }
    try std.testing.expectEqual(portal.Outcome.granted, req.outcome.?);
    const p = try portal.chosenPath(alloc, &req);
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/home/u/Imágenes/Shots", p);
}

/// A Screenshot call body: no parent window, just the handle_token.
fn screenshotBody(m: *dbus.Marshal, token: []const u8) !void {
    try m.putString("");
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(token);
    m.endArray(arr);
}

/// Nobody answers: the deadline ends the wait and closes the request.
fn checkSilentPortal(alloc: std.mem.Allocator, conn: *dbus.Connection, mock: *Mock) !void {
    mock.mode.store(@backingInt(Mode.silent), .release);
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try screenshotBody(&m, "silent1");
    const t0 = sys.monoMs();
    var req = try portal.call(alloc, conn, "org.freedesktop.portal.Screenshot", "Screenshot", "sa{sv}", m.buf.items, "silent1", 300);
    defer req.deinit(alloc);
    try std.testing.expectEqual(portal.Outcome.timeout, req.outcome.?);
    try std.testing.expect(sys.monoMs() - t0 < 3000);
    const close_deadline = sys.monoMs() + 2000;
    while (mock.closed_requests.load(.acquire) == 0 and sys.monoMs() < close_deadline) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    try std.testing.expectEqual(@as(u32, 1), mock.closed_requests.load(.acquire));
}

/// The portal never even accepts the call: no dialog can be up, so it
/// counts as unavailable (the caller can fall back) and fails fast.
fn checkMutePortal(alloc: std.mem.Allocator, conn: *dbus.Connection, mock: *Mock) !void {
    mock.mode.store(@backingInt(Mode.mute), .release);
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try screenshotBody(&m, "mute1");
    var req = try portal.call(alloc, conn, "org.freedesktop.portal.Screenshot", "Screenshot", "sa{sv}", m.buf.items, "mute1", 300);
    defer req.deinit(alloc);
    try std.testing.expectEqual(portal.Outcome.unavailable, req.outcome.?);
}

/// The portal goes away mid-request: unavailable at once, not at the
/// dialog deadline.
fn checkVanishingPortal(alloc: std.mem.Allocator, conn: *dbus.Connection, mock: *Mock) !void {
    mock.mode.store(@backingInt(Mode.vanish), .release);
    const t0 = sys.monoMs();
    switch (try portal.screenshot(alloc, conn, false, portal.timeout_dialog_ms)) {
        .unavailable => {},
        else => |o| {
            std.debug.print("vanish: {t}\n", .{o});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expect(sys.monoMs() - t0 < 5000);
}
