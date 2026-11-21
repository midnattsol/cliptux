//! A bus connection: connect and authenticate, send calls, signals and
//! replies, wait for replies, and the org.freedesktop.DBus helpers.

const std = @import("std");
const sys = @import("../sys.zig");
const Marshal = @import("marshal.zig").Marshal;
const message = @import("message.zig");
const Message = message.Message;
const address = @import("address.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");

const default_reply_timeout_ms = transport.default_reply_timeout_ms;

pub const Connection = struct {
    fd: sys.fd_t,
    alloc: std.mem.Allocator,
    serial: u32 = 1,
    unique_name: []u8 = &.{},
    /// messages received while waiting for a specific reply
    pending: std.ArrayList(Message) = .empty,
    /// fds received via SCM_RIGHTS (consumed in arrival order)
    in_fds: std.ArrayList(sys.fd_t) = .empty,
    unix_fd_ok: bool = false,
    /// hashes of match rules already added, so helpers can call addMatchOnce
    matches: [16]u64 = @splat(0),
    n_matches: usize = 0,

    /// `addr_env` is the value of DBUS_SESSION_BUS_ADDRESS: a `;`-separated
    /// list tried in order. Supports unix:path= and unix:abstract=, with
    /// percent-escaped values.
    pub fn connectSession(alloc: std.mem.Allocator, addr_env: []const u8) !Connection {
        var buf: [2048]u8 = undefined;
        var list: [8]address.Address = undefined;
        const addrs = try address.parseAddresses(addr_env, &buf, &list);
        if (addrs.len == 0) return error.UnsupportedBusAddress;
        var last_err: anyerror = error.UnsupportedBusAddress;
        for (addrs) |addr| {
            const fd = try sys.socketUnixStream();
            connectAddress(fd, addr) catch |err| {
                sys.close(fd);
                last_err = err;
                continue;
            };
            return fromFd(alloc, fd);
        }
        return last_err;
    }

    fn connectAddress(fd: sys.fd_t, addr: address.Address) !void {
        return switch (addr) {
            .path => |p| sys.connectUnix(fd, p),
            .abstract => |name| sys.connectUnixAbstract(fd, name),
        };
    }

    /// Authenticate and say Hello over an already connected socket. Takes
    /// ownership of fd (closed on error).
    pub fn fromFd(alloc: std.mem.Allocator, fd: sys.fd_t) !Connection {
        var self = Connection{ .fd = fd, .alloc = alloc };
        errdefer self.deinit();
        self.unix_fd_ok = try auth.authenticate(fd, default_reply_timeout_ms);
        try self.hello();
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (self.pending.items) |*m| m.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        for (self.in_fds.items) |fd| sys.close(fd);
        self.in_fds.deinit(self.alloc);
        sys.close(self.fd);
        self.alloc.free(self.unique_name);
    }

    fn hello(self: *Connection) !void {
        const serial = try self.callBus("Hello", "", &.{});
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        const name = try r.readString();
        self.unique_name = try self.alloc.dupe(u8, name);
    }

    pub fn nextSerial(self: *Connection) u32 {
        defer self.serial += 1;
        return self.serial;
    }

    /// Send a method call; returns the serial for matching the reply.
    pub fn callMethod(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !u32 {
        return self.callMethodFds(destination, path, interface, member, signature, body, &.{});
    }

    /// callMethod attaching file descriptors ('h' args are indexes into
    /// fds); the bus must have agreed to pass them (AGREE_UNIX_FD).
    pub fn callMethodFds(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
        fds: []const sys.fd_t,
    ) !u32 {
        if (fds.len > 0 and !self.unix_fd_ok) return error.NoFdPassing;
        const serial = self.nextSerial();
        try transport.sendMessageFds(self, .method_call, serial, .{
            .path = path,
            .interface = interface,
            .member = member,
            .destination = destination,
            .signature = signature,
        }, body, null, fds);
        return serial;
    }

    pub fn emitSignal(
        self: *Connection,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !void {
        try transport.sendMessage(self, .signal, self.nextSerial(), .{
            .path = path,
            .interface = interface,
            .member = member,
            .signature = signature,
        }, body, null);
    }

    pub fn replyTo(self: *Connection, call: *const Message, signature: []const u8, body: []const u8) !void {
        try self.replyToWithFds(call, signature, body, &.{});
    }

    /// Reply attaching file descriptors ('h' args are indexes into fds).
    pub fn replyToWithFds(self: *Connection, call: *const Message, signature: []const u8, body: []const u8, fds: []const sys.fd_t) !void {
        try transport.sendMessageFds(self, .method_return, self.nextSerial(), .{
            .destination = call.sender,
            .signature = signature,
        }, body, call.serial, fds);
    }

    pub fn replyError(self: *Connection, call: *const Message, error_name: []const u8, text: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(text);
        try transport.sendMessage(self, .@"error", self.nextSerial(), .{
            .destination = call.sender,
            .error_name = error_name,
            .signature = "s",
        }, m.buf.items, call.serial);
    }

    /// Blocking read of the next complete message.
    pub fn readMessage(self: *Connection) !Message {
        return (try self.readMessageDeadline(null)) orelse unreachable;
    }

    /// Read the next complete message, or null if none starts arriving
    /// before `deadline_ms` (monotonic). Malformed messages are consumed
    /// whole and reported as a non-fatal error (see isFatal).
    pub fn readMessageDeadline(self: *Connection, deadline_ms: ?i64) !?Message {
        return transport.readMessageDeadline(self, deadline_ms);
    }

    /// Wait for the reply to `serial`, up to default_reply_timeout_ms.
    /// Unrelated messages (e.g. incoming method calls while we block) are
    /// queued for nextMessage, not dropped.
    pub fn waitReply(self: *Connection, serial: u32) !Message {
        return self.waitReplyTimeout(serial, default_reply_timeout_ms);
    }

    /// Like waitReplyTimeout, but an error reply is returned as is (type
    /// .@"error", error_name set) for callers that tell errors apart.
    pub fn waitReplyOrError(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        return self.awaitReply(serial, timeout_ms, false);
    }

    pub fn waitReplyTimeout(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        var msg = try self.awaitReply(serial, timeout_ms, true);
        if (msg.type == .@"error") {
            const name = msg.error_name orelse "unknown";
            std.log.warn("dbus error reply: {s}", .{name});
            msg.deinit(self.alloc);
            return error.DBusError;
        }
        return msg;
    }

    /// Read until the message replying to `serial` arrives (whatever its
    /// type), queueing everything else; malformed messages are skipped.
    fn awaitReply(self: *Connection, serial: u32, timeout_ms: i64, warn_dropped: bool) !Message {
        const deadline = sys.monoMs() + timeout_ms;
        while (true) {
            var msg = (self.readMessageDeadline(deadline) catch |err| {
                if (transport.isFatal(err)) return err;
                if (warn_dropped) std.log.warn("dropped malformed bus message: {t}", .{err});
                continue;
            }) orelse return error.Timeout;
            if (msg.reply_serial == serial) return msg;
            self.pending.append(self.alloc, msg) catch {
                msg.deinit(self.alloc);
            };
        }
    }

    /// Next message: drains the pending queue before reading the socket.
    pub fn nextMessage(self: *Connection) !Message {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return self.readMessage();
    }

    /// Like nextMessage, but returns null when nothing arrives before
    /// `deadline_ms` (monotonic).
    pub fn nextMessageDeadline(self: *Connection, deadline_ms: ?i64) !?Message {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return self.readMessageDeadline(deadline_ms);
    }

    /// True if a queued or buffered message may be available without blocking.
    pub fn hasPending(self: *const Connection) bool {
        return self.pending.items.len > 0;
    }

    /// Call a method of the bus itself (org.freedesktop.DBus).
    fn callBus(self: *Connection, member: []const u8, signature: []const u8, body: []const u8) !u32 {
        return self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", member, signature, body);
    }

    /// addMatch, skipped when this connection already added the same rule.
    pub fn addMatchOnce(self: *Connection, rule: []const u8) !void {
        const h = std.hash.Wyhash.hash(0, rule);
        for (self.matches[0..self.n_matches]) |m| if (m == h) return;
        try self.addMatch(rule);
        if (self.n_matches < self.matches.len) {
            self.matches[self.n_matches] = h;
            self.n_matches += 1;
        }
    }

    pub fn addMatch(self: *Connection, rule: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(rule);
        const serial = try self.callBus("AddMatch", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        reply.deinit(self.alloc);
    }

    pub fn nameHasOwner(self: *Connection, name: []const u8) !bool {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(name);
        const serial = try self.callBus("NameHasOwner", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        return (try r.readU32()) != 0;
    }

    /// Request a well-known name (DO_NOT_QUEUE). Returns true if we are
    /// the primary owner; false means another instance already holds it.
    pub fn requestName(self: *Connection, name: []const u8) !bool {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(name);
        try m.putU32(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
        const serial = try self.callBus("RequestName", "su", m.buf.items);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        const code = try r.readU32();
        return code == 1; // PRIMARY_OWNER
    }
};
