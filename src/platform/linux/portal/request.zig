//! Request-style portal calls: the method call, its Request object and
//! the Response signal that may take as long as a person looking at a
//! dialog. Every wait has a deadline, watches the portal's bus name so a
//! crashed portal fails fast, and reports an explicit Outcome.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const screencast = @import("screencast.zig"); // test fixtures

pub const Outcome = enum {
    /// the request succeeded (response 0)
    granted,
    /// the person dismissed the dialog (response 1)
    cancelled,
    /// refused by the portal or a stored permission (response 2, NotAllowed)
    denied,
    /// no portal, no such interface, or the portal went away mid-request
    unavailable,
    /// no answer before the deadline; the request was closed
    timeout,
};

/// Either the granted value or why there is none.
pub fn Result(comptime T: type) type {
    return union(Outcome) {
        granted: T,
        cancelled,
        denied,
        unavailable,
        timeout,
    };
}

/// Carry a not-granted outcome over to another Result type.
pub fn notGranted(comptime T: type, o: Outcome) Result(T) {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}

/// A consent dialog may be on screen: a person may take a long time to
/// decide (or step away), so only give up after this long. A portal that
/// never accepts the call, or exits, still fails fast (see Request.wait).
pub const timeout_dialog_ms: i64 = 10 * 60_000;
/// A windowless Screenshot request: GNOME only shows its consent dialog to
/// the focused app, so with permission the answer is quick and without it
/// no dialog can come (GNOME 48 then never answers at all when no app has
/// focus, leaving the call to dbus' 25 s timeout).
pub const timeout_unfocused_screenshot_ms: i64 = 5_000;
/// Calls that never show UI. Long enough to cover the portal being
/// started by bus activation, which dbus itself bounds at 25 s.
pub const timeout_quick_ms: i64 = 30_000;
/// Picking a file name and folder can reasonably take a while.
pub const timeout_file_chooser_ms: i64 = 15 * 60_000;

pub const bus_name = "org.freedesktop.portal.Desktop";
pub const object_path = "/org/freedesktop/portal/desktop";

/// Subscribe to Response signals and to the portal's bus name changing
/// owner (once per connection).
pub fn watch(conn: *dbus.Connection) !void {
    try conn.addMatchOnce("type='signal',interface='org.freedesktop.portal.Request',member='Response'");
    try conn.addMatchOnce("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ bus_name ++ "'");
}

fn isDenialError(name: []const u8) bool {
    return std.mem.eql(u8, name, "org.freedesktop.portal.Error.NotAllowed") or
        std.mem.eql(u8, name, "org.freedesktop.DBus.Error.AccessDenied");
}

/// One in-flight request-style portal call. Feed it bus messages with
/// handle(), or block in wait().
pub const Request = struct {
    serial: u32,
    /// object path of the Request; Response signals arrive on it
    path: []u8,
    /// method name, for log lines (static string)
    what: []const u8,
    got_reply: bool = false,
    outcome: ?Outcome = null,
    /// the Response signal when granted; its body is "ua{sv}"
    response: ?dbus.Message = null,

    pub fn start(
        alloc: std.mem.Allocator,
        conn: *dbus.Connection,
        iface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
        handle_token: []const u8,
    ) !Request {
        try watch(conn);
        var path_buf: [256]u8 = undefined;
        const path = try alloc.dupe(u8, try senderPath(conn, &path_buf, "request", handle_token));
        errdefer alloc.free(path);
        const serial = try conn.callMethod(bus_name, object_path, iface, member, signature, body);
        return .{ .serial = serial, .path = path, .what = member };
    }

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        if (self.response) |*m| m.deinit(alloc);
        self.* = undefined;
    }

    pub fn done(self: *const Request) bool {
        return self.outcome != null;
    }

    /// Look at one message. Returns true when it kept the message (it was
    /// the granted Response; ownership moved into self.response), false
    /// when the caller still owns it.
    pub fn handle(self: *Request, alloc: std.mem.Allocator, msg: *const dbus.Message) !bool {
        if (self.outcome != null) return false;
        if (!self.got_reply and msg.reply_serial == self.serial and
            (msg.type == .method_return or msg.type == .@"error"))
        {
            try self.handleMethodReply(alloc, msg);
            return false;
        }
        if (msg.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) {
            self.handleNameOwnerChanged(msg);
            return false;
        }
        if (msg.isSignal("org.freedesktop.portal.Request", "Response")) return self.handleResponse(msg);
        return false;
    }

    /// The method call's reply: an error ends the request, a return
    /// carries the Request object path.
    fn handleMethodReply(self: *Request, alloc: std.mem.Allocator, msg: *const dbus.Message) !void {
        if (msg.type == .@"error") {
            const name = msg.error_name orelse "?";
            std.log.warn("portal {s} failed: {s}", .{ self.what, name });
            self.outcome = if (isDenialError(name)) .denied else .unavailable;
            return;
        }
        var r = msg.reader();
        const handle_path = r.readString() catch {
            self.outcome = .unavailable;
            return;
        };
        // portals older than 0.9 do not use the predicted path
        if (!std.mem.eql(u8, handle_path, self.path)) {
            const copy = try alloc.dupe(u8, handle_path);
            alloc.free(self.path);
            self.path = copy;
        }
        self.got_reply = true;
    }

    /// The portal losing its bus name ends the request as unavailable.
    fn handleNameOwnerChanged(self: *Request, msg: *const dbus.Message) void {
        var r = msg.reader();
        const name = r.readString() catch return;
        if (!std.mem.eql(u8, name, bus_name)) return;
        _ = r.readString() catch return; // old owner
        const new_owner = r.readString() catch return;
        if (new_owner.len == 0) {
            std.log.warn("the desktop portal exited during {s}", .{self.what});
            self.outcome = .unavailable;
        }
    }

    /// A Response signal on our path sets the outcome; a granted one is
    /// kept (returns true).
    fn handleResponse(self: *Request, msg: *const dbus.Message) bool {
        const path = msg.path orelse return false;
        if (!std.mem.eql(u8, path, self.path)) return false;
        if (msg.signature == null or !std.mem.eql(u8, msg.signature.?, "ua{sv}")) {
            std.log.warn("portal {s}: malformed Response", .{self.what});
            self.outcome = .unavailable;
            return false;
        }
        var r = msg.reader();
        const code = r.readU32() catch {
            self.outcome = .unavailable;
            return false;
        };
        self.outcome = switch (code) {
            0 => .granted,
            1 => .cancelled,
            else => .denied,
        };
        if (code != 0) return false;
        self.response = msg.*;
        return true;
    }

    /// Pump the connection until the request finishes or `timeout_ms`
    /// passes. The portal must accept the call (reply with the Request
    /// handle) within timeout_quick_ms, else it is treated as unavailable:
    /// only then can a dialog be on screen, and only then is the long wait
    /// worth it. Unrelated messages are dropped.
    pub fn wait(self: *Request, alloc: std.mem.Allocator, conn: *dbus.Connection, timeout_ms: i64) !void {
        const start_ms = sys.monoMs();
        const deadline = start_ms + timeout_ms;
        const reply_deadline = start_ms + @min(timeout_ms, timeout_quick_ms);
        while (self.outcome == null) {
            const until = if (self.got_reply) deadline else reply_deadline;
            var msg = (conn.nextMessageDeadline(until) catch |err| {
                if (dbus.isFatal(err)) return err;
                std.log.warn("dropped malformed bus message: {t}", .{err});
                continue;
            }) orelse {
                if (!self.got_reply) {
                    std.log.warn("portal {s}: no reply from the portal; giving up", .{self.what});
                    self.outcome = .unavailable;
                    break;
                }
                std.log.warn("portal {s}: no answer after {d} min; giving up", .{ self.what, @divTrunc(timeout_ms, 60_000) });
                self.close(conn);
                self.outcome = .timeout;
                break;
            };
            const kept = self.handle(alloc, &msg) catch false;
            if (!kept) msg.deinit(alloc);
        }
    }

    /// Dismiss whatever dialog belongs to this request. Fire-and-forget.
    pub fn close(self: *const Request, conn: *dbus.Connection) void {
        _ = conn.callMethod(bus_name, self.path, "org.freedesktop.portal.Request", "Close", "", &.{}) catch {};
    }

    /// Reader over the granted Response's results dict (after the code).
    pub fn results(self: *const Request) !dbus.Reader {
        const msg = &(self.response orelse return error.NoResponse);
        var r = msg.reader();
        _ = try r.readU32();
        return r;
    }
};

/// start() + wait(): the finished request (caller deinits).
pub fn call(
    alloc: std.mem.Allocator,
    conn: *dbus.Connection,
    iface: []const u8,
    member: []const u8,
    signature: []const u8,
    body: []const u8,
    handle_token: []const u8,
    timeout_ms: i64,
) !Request {
    var req = try Request.start(alloc, conn, iface, member, signature, body, handle_token);
    errdefer req.deinit(alloc);
    try req.wait(alloc, conn, timeout_ms);
    return req;
}

/// A handle token: unique per request, only [A-Za-z0-9_] as the spec asks.
pub fn makeToken(buf: []u8, prefix: []const u8) ![]u8 {
    var rnd: [8]u8 = undefined;
    sys.getRandom(&rnd);
    return std.fmt.bufPrint(buf, "{s}{d}_{x}", .{ prefix, std.os.linux.getpid(), std.mem.readInt(u64, &rnd, .little) });
}

fn senderPath(conn: *const dbus.Connection, buf: []u8, kind: []const u8, token: []const u8) ![]u8 {
    var sender_buf: [64]u8 = undefined;
    var n: usize = 0;
    for (conn.unique_name) |c| {
        if (c == ':') continue;
        if (n == sender_buf.len) return error.NameTooLong;
        sender_buf[n] = if (c == '.') '_' else c;
        n += 1;
    }
    return std.fmt.bufPrint(buf, "/org/freedesktop/portal/desktop/{s}/{s}/{s}", .{ kind, sender_buf[0..n], token });
}

fn fakeSignal(body: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8) dbus.Message {
    return .{ .type = .signal, .serial = 99, .path = path, .interface = iface, .member = member, .signature = sig, .body = body };
}

test "Request outcomes from Response codes, errors and a vanished portal" {
    const alloc = std.testing.allocator;
    // the failures below are expected; keep their warnings out of the output
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    const path = "/org/freedesktop/portal/desktop/request/1_5/tok";

    const Case = struct { code: u32, want: Outcome };
    for ([_]Case{
        .{ .code = 0, .want = .granted },
        .{ .code = 1, .want = .cancelled },
        .{ .code = 2, .want = .denied },
    }) |c| {
        var req = Request{ .serial = 7, .path = try alloc.dupe(u8, path), .what = "Start" };
        defer req.deinit(alloc);
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try screencast.startResponseBody(&m, c.code, "s");

        // a Response for someone else's request changes nothing
        var other = fakeSignal(m.buf.items, "/elsewhere", "org.freedesktop.portal.Request", "Response", "ua{sv}");
        try std.testing.expect(!try req.handle(alloc, &other));
        try std.testing.expect(req.outcome == null);

        const raw = try alloc.dupe(u8, m.buf.items);
        var sig = fakeSignal(raw, path, "org.freedesktop.portal.Request", "Response", "ua{sv}");
        sig.raw = raw;
        const kept = try req.handle(alloc, &sig);
        if (!kept) sig.deinit(alloc);
        try std.testing.expectEqual(c.want, req.outcome.?);
        try std.testing.expectEqual(c.code == 0, kept);
        if (c.code == 0) {
            var r = try req.results();
            var st = try screencast.parseStartResults(alloc, &r);
            st.deinit(alloc);
        }
    }

    // malformed Response signature: unavailable, not misread
    {
        var req = Request{ .serial = 7, .path = try alloc.dupe(u8, path), .what = "Start" };
        defer req.deinit(alloc);
        var bad = fakeSignal(&.{ 0, 0, 0, 0 }, path, "org.freedesktop.portal.Request", "Response", "u");
        try std.testing.expect(!try req.handle(alloc, &bad));
        try std.testing.expectEqual(Outcome.unavailable, req.outcome.?);
    }

    // the portal loses its bus name mid-request
    {
        var req = Request{ .serial = 7, .path = try alloc.dupe(u8, path), .what = "Start" };
        defer req.deinit(alloc);
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putString(bus_name);
        try m.putString(":1.5");
        try m.putString("");
        var noc = fakeSignal(m.buf.items, "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", "sss");
        _ = try req.handle(alloc, &noc);
        try std.testing.expectEqual(Outcome.unavailable, req.outcome.?);
    }

    // an error reply: NotAllowed is a denial, anything else unavailable
    for ([_]struct { name: []const u8, want: Outcome }{
        .{ .name = "org.freedesktop.portal.Error.NotAllowed", .want = .denied },
        .{ .name = "org.freedesktop.DBus.Error.UnknownMethod", .want = .unavailable },
    }) |c| {
        var req = Request{ .serial = 7, .path = try alloc.dupe(u8, path), .what = "Start" };
        defer req.deinit(alloc);
        var e = dbus.Message{ .type = .@"error", .serial = 3, .reply_serial = 7, .error_name = c.name };
        _ = try req.handle(alloc, &e);
        try std.testing.expectEqual(c.want, req.outcome.?);
    }

    // the method reply may name a different request path (old portals)
    {
        var req = Request{ .serial = 7, .path = try alloc.dupe(u8, path), .what = "Start" };
        defer req.deinit(alloc);
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putObjectPath("/other/request");
        var reply = dbus.Message{ .type = .method_return, .serial = 3, .reply_serial = 7, .signature = "o", .body = m.buf.items };
        _ = try req.handle(alloc, &reply);
        try std.testing.expectEqualStrings("/other/request", req.path);
        try std.testing.expect(req.outcome == null);
    }
}
