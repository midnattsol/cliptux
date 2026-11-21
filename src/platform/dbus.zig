//! Native DBus client: speaks the wire protocol directly over the session bus
//! unix socket. No libdbus. Little-endian only (x86_64/aarch64 linux).

const std = @import("std");
const sys = @import("sys.zig");

pub const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

const FieldCode = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

pub const Message = struct {
    type: MessageType,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    body: []const u8 = &.{},
    // backing storage for all slices above; free with allocator
    raw: []u8 = &.{},
    /// fds delivered with this message (per the UNIX_FDS header field)
    fds: [4]sys.fd_t = @splat(-1),
    n_fds: u8 = 0,

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        for (self.fds[0..self.n_fds]) |fd| {
            if (fd >= 0) sys.close(fd);
        }
        alloc.free(self.raw);
        self.* = undefined;
    }

    /// Take ownership of the next fd attached to this message.
    pub fn takeFd(self: *Message) ?sys.fd_t {
        for (self.fds[0..self.n_fds]) |*fd| {
            if (fd.* >= 0) {
                const out = fd.*;
                fd.* = -1;
                return out;
            }
        }
        return null;
    }

    pub fn isSignal(self: *const Message, iface: []const u8, member: []const u8) bool {
        return self.type == .signal and
            self.interface != null and std.mem.eql(u8, self.interface.?, iface) and
            self.member != null and std.mem.eql(u8, self.member.?, member);
    }

    pub fn isCall(self: *const Message, iface: []const u8, member: []const u8) bool {
        return self.type == .method_call and
            self.interface != null and std.mem.eql(u8, self.interface.?, iface) and
            self.member != null and std.mem.eql(u8, self.member.?, member);
    }

    pub fn reader(self: *const Message) Reader {
        return .{ .data = self.body, .pos = 0 };
    }
};

/// Body builder. All append methods handle alignment.
pub const Marshal = struct {
    buf: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Marshal {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Marshal) void {
        self.buf.deinit(self.alloc);
    }

    pub fn pad(self: *Marshal, alignment: usize) !void {
        while (self.buf.items.len % alignment != 0)
            try self.buf.append(self.alloc, 0);
    }
    pub fn putByte(self: *Marshal, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }
    pub fn putU16(self: *Marshal, v: u16) !void {
        try self.pad(2);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putU32(self: *Marshal, v: u32) !void {
        try self.pad(4);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putI32(self: *Marshal, v: i32) !void {
        try self.putU32(@bitCast(v));
    }
    pub fn putU64(self: *Marshal, v: u64) !void {
        try self.pad(8);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putBool(self: *Marshal, v: bool) !void {
        try self.putU32(if (v) 1 else 0);
    }
    pub fn putString(self: *Marshal, s: []const u8) !void {
        try self.putU32(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    pub fn putObjectPath(self: *Marshal, s: []const u8) !void {
        try self.putString(s);
    }
    pub fn putSignature(self: *Marshal, s: []const u8) !void {
        try self.buf.append(self.alloc, @intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    /// variant with a simple inner value
    pub fn putVariantString(self: *Marshal, s: []const u8) !void {
        try self.putSignature("s");
        try self.putString(s);
    }
    pub fn putVariantBool(self: *Marshal, v: bool) !void {
        try self.putSignature("b");
        try self.putBool(v);
    }
    pub fn putVariantU32(self: *Marshal, v: u32) !void {
        try self.putSignature("u");
        try self.putU32(v);
    }
    pub fn putVariantI32(self: *Marshal, v: i32) !void {
        try self.putSignature("i");
        try self.putI32(v);
    }

    /// Begin an array: returns position of the length field. Call endArray
    /// after writing elements. elem_alignment is the alignment of one element.
    pub fn beginArray(self: *Marshal, elem_alignment: usize) !ArrayMark {
        try self.pad(4);
        const len_pos = self.buf.items.len;
        try self.buf.appendSlice(self.alloc, &.{ 0, 0, 0, 0 });
        try self.pad(elem_alignment);
        return .{ .len_pos = len_pos, .start = self.buf.items.len };
    }
    pub fn endArray(self: *Marshal, mark: ArrayMark) void {
        const len: u32 = @intCast(self.buf.items.len - mark.start);
        @memcpy(self.buf.items[mark.len_pos..][0..4], std.mem.asBytes(&len));
    }
    pub const ArrayMark = struct { len_pos: usize, start: usize };

    /// dict entries and structs are 8-aligned
    pub fn beginStruct(self: *Marshal) !void {
        try self.pad(8);
    }
};

pub const Value = union(enum) {
    string: []const u8,
    object_path: []const u8,
    boolean: bool,
    u32_: u32,
    i32_: i32,
    u64_: u64,
    f64_: f64,
    other: void, // present but uninterpreted (skipped)
};

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn pad(self: *Reader, alignment: usize) void {
        while (self.pos % alignment != 0) self.pos += 1;
    }
    pub fn readByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.ShortRead;
        defer self.pos += 1;
        return self.data[self.pos];
    }
    pub fn readU16(self: *Reader) !u16 {
        self.pad(2);
        if (self.pos + 2 > self.data.len) return error.ShortRead;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
    }
    pub fn readU32(self: *Reader) !u32 {
        self.pad(4);
        if (self.pos + 4 > self.data.len) return error.ShortRead;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
    }
    pub fn readU64(self: *Reader) !u64 {
        self.pad(8);
        if (self.pos + 8 > self.data.len) return error.ShortRead;
        defer self.pos += 8;
        return std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
    }
    pub fn readString(self: *Reader) ![]const u8 {
        const len: usize = try self.readU32();
        if (self.pos + len + 1 > self.data.len) return error.ShortRead;
        defer self.pos += len + 1;
        return self.data[self.pos..][0..len];
    }
    pub fn readSignature(self: *Reader) ![]const u8 {
        const len: usize = try self.readByte();
        if (self.pos + len + 1 > self.data.len) return error.ShortRead;
        defer self.pos += len + 1;
        return self.data[self.pos..][0..len];
    }

    /// Read a variant, interpreting common simple types.
    pub fn readVariant(self: *Reader) !Value {
        const sig = try self.readSignature();
        return self.readValue(sig);
    }

    fn readValue(self: *Reader, sig: []const u8) anyerror!Value {
        if (sig.len == 0) return error.BadSignature;
        if (sig.len == 1) switch (sig[0]) {
            's' => return .{ .string = try self.readString() },
            'o' => return .{ .object_path = try self.readString() },
            'b' => return .{ .boolean = (try self.readU32()) != 0 },
            'u' => return .{ .u32_ = try self.readU32() },
            'i' => return .{ .i32_ = @bitCast(try self.readU32()) },
            'x', 't' => return .{ .u64_ = try self.readU64() },
            'd' => return .{ .f64_ = @bitCast(try self.readU64()) },
            else => {},
        };
        var idx: usize = 0;
        try self.skipType(sig, &idx);
        // a variant holds exactly one complete type
        if (idx != sig.len) return error.BadSignature;
        return .other;
    }

    /// The spec allows 32 levels of array and 32 of struct nesting; variants
    /// nest without a signature-imposed bound, so cap the total explicitly.
    pub const max_depth = 64;

    /// Skip one complete type starting at sig[idx.*]; advances idx past it.
    /// Never reads outside `data` or `sig`: malformed input is an error.
    pub fn skipType(self: *Reader, sig: []const u8, idx: *usize) anyerror!void {
        return self.skipTypeDepth(sig, idx, 0);
    }

    fn skipTypeDepth(self: *Reader, sig: []const u8, idx: *usize, depth: u32) anyerror!void {
        if (depth > max_depth) return error.TooDeep;
        if (idx.* >= sig.len) return error.BadSignature;
        const c = sig[idx.*];
        idx.* += 1;
        switch (c) {
            'y' => _ = try self.readByte(),
            'n', 'q' => _ = try self.readU16(),
            'b', 'u', 'i', 'h' => _ = try self.readU32(),
            'x', 't', 'd' => _ = try self.readU64(),
            's', 'o' => _ = try self.readString(),
            'g' => _ = try self.readSignature(),
            'v' => {
                const inner = try self.readSignature();
                var i: usize = 0;
                try self.skipTypeDepth(inner, &i, depth + 1);
                if (i != inner.len) return error.BadSignature;
            },
            'a' => {
                const len = try self.readU32();
                if (len > 64 * 1024 * 1024) return error.BadArrayLength;
                if (idx.* >= sig.len) return error.BadSignature;
                const elem_align = typeAlignment(sig[idx.*]) orelse return error.BadSignature;
                self.pad(elem_align);
                if (self.pos > self.data.len or len > self.data.len - self.pos) return error.ShortRead;
                self.pos += len;
                // the element type is skipped in the signature only
                try skipSignature(sig, idx, depth + 1);
            },
            '(', '{' => {
                const close: u8 = if (c == '(') ')' else '}';
                self.pad(8);
                while (true) {
                    if (idx.* >= sig.len) return error.BadSignature;
                    if (sig[idx.*] == close) break;
                    try self.skipTypeDepth(sig, idx, depth + 1);
                }
                idx.* += 1; // closing paren
            },
            else => return error.BadSignature,
        }
    }

    /// Iterate over a{sv}: call this after positioning at the array.
    pub fn readDictSV(self: *Reader) !DictSVIterator {
        const len = try self.readU32();
        self.pad(8);
        if (self.pos > self.data.len or len > self.data.len - self.pos) return error.ShortRead;
        return .{ .reader = self, .end = self.pos + len };
    }
    pub const DictSVIterator = struct {
        reader: *Reader,
        end: usize,
        pub fn next(self: *DictSVIterator) !?struct { key: []const u8, value: Value } {
            if (self.reader.pos >= self.end) return null;
            self.reader.pad(8);
            if (self.reader.pos >= self.end) return null;
            const key = try self.reader.readString();
            const value = try self.reader.readVariant();
            if (self.reader.pos > self.end) return error.BadArrayLength;
            return .{ .key = key, .value = value };
        }
    };

    /// Like DictSVIterator, but leaves each value unread: the caller gets
    /// the variant's signature and must consume exactly one value of it
    /// (or call skipValue).
    pub fn readDictRaw(self: *Reader) !DictRawIterator {
        const len = try self.readU32();
        self.pad(8);
        if (self.pos > self.data.len or len > self.data.len - self.pos) return error.ShortRead;
        return .{ .reader = self, .end = self.pos + len };
    }
    pub const DictRawIterator = struct {
        reader: *Reader,
        end: usize,
        pub fn next(self: *DictRawIterator) !?struct { key: []const u8, sig: []const u8 } {
            if (self.reader.pos > self.end) return error.BadArrayLength;
            if (self.reader.pos >= self.end) return null;
            self.reader.pad(8);
            if (self.reader.pos >= self.end) return null;
            const key = try self.reader.readString();
            const sig = try self.reader.readSignature();
            return .{ .key = key, .sig = sig };
        }
    };

    /// Skip a value whose full signature is `sig` (e.g. a variant's).
    pub fn skipValue(self: *Reader, sig: []const u8) !void {
        var idx: usize = 0;
        try self.skipType(sig, &idx);
        if (idx != sig.len) return error.BadSignature;
    }
};

/// Alignment of a value whose signature starts with `c`.
fn typeAlignment(c: u8) ?usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'u', 'i', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => null,
    };
}

/// Advance idx past one complete type in a signature, validating nesting.
fn skipSignature(sig: []const u8, idx: *usize, depth: u32) !void {
    if (depth > Reader.max_depth) return error.TooDeep;
    if (idx.* >= sig.len) return error.BadSignature;
    const c = sig[idx.*];
    idx.* += 1;
    switch (c) {
        'y', 'n', 'q', 'b', 'u', 'i', 'h', 'x', 't', 'd', 's', 'o', 'g', 'v' => {},
        'a' => try skipSignature(sig, idx, depth + 1),
        '(', '{' => {
            const close: u8 = if (c == '(') ')' else '}';
            while (true) {
                if (idx.* >= sig.len) return error.BadSignature;
                if (sig[idx.*] == close) {
                    idx.* += 1;
                    return;
                }
                try skipSignature(sig, idx, depth + 1);
            }
        },
        else => return error.BadSignature,
    }
}

/// One transport from a DBus address list.
pub const Address = union(enum) {
    path: []const u8,
    abstract: []const u8,
};

/// Parse a DBus server address list ("unix:path=/run/user/1000/bus;
/// unix:abstract=/tmp/dbus-x,guid=..."), percent-decoding values into
/// `buf`. Returns the unix transports in order; other transports (tcp,
/// launchd, ...) are skipped.
pub fn parseAddresses(addr: []const u8, buf: []u8, out: []Address) ![]Address {
    var n: usize = 0;
    var used: usize = 0;
    var entries = std.mem.splitScalar(u8, addr, ';');
    while (entries.next()) |entry| {
        if (n == out.len) break;
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
        if (!std.mem.eql(u8, entry[0..colon], "unix")) continue;
        var kvs = std.mem.splitScalar(u8, entry[colon + 1 ..], ',');
        while (kvs.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const key = kv[0..eq];
            const is_path = std.mem.eql(u8, key, "path");
            const is_abstract = std.mem.eql(u8, key, "abstract");
            if (!is_path and !is_abstract) continue;
            const value = unescapeAddressValue(kv[eq + 1 ..], buf[used..]) catch continue;
            used += value.len;
            if (value.len == 0) continue;
            out[n] = if (is_path) .{ .path = value } else .{ .abstract = value };
            n += 1;
            break;
        }
    }
    return out[0..n];
}

fn unescapeAddressValue(v: []const u8, out: []u8) ![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (n == out.len) return error.AddressTooLong;
        if (v[i] == '%') {
            if (i + 2 >= v.len) return error.BadAddress;
            const hi = std.fmt.charToDigit(v[i + 1], 16) catch return error.BadAddress;
            const lo = std.fmt.charToDigit(v[i + 2], 16) catch return error.BadAddress;
            out[n] = hi * 16 + lo;
            i += 2;
        } else {
            out[n] = v[i];
        }
        n += 1;
    }
    return out[0..n];
}

/// Errors after which the byte stream can no longer be trusted (or is gone).
/// Anything else from readMessage means one malformed message was consumed
/// and dropped; the connection stays usable.
pub fn isFatal(err: anyerror) bool {
    return switch (err) {
        error.Disconnected,
        error.ConnectionReset,
        error.BrokenPipe,
        error.SyscallFailed,
        error.OutOfMemory,
        error.BadMessageFraming,
        => true,
        else => false,
    };
}

/// Default bound for method replies (the reference implementation uses 25 s).
pub const default_reply_timeout_ms: i64 = 25_000;

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
        var list: [8]Address = undefined;
        const addrs = try parseAddresses(addr_env, &buf, &list);
        if (addrs.len == 0) return error.UnsupportedBusAddress;
        var last_err: anyerror = error.UnsupportedBusAddress;
        for (addrs) |addr| {
            const fd = try sys.socketUnixStream();
            const res = switch (addr) {
                .path => |p| sys.connectUnix(fd, p),
                .abstract => |name| sys.connectUnixAbstract(fd, name),
            };
            res catch |err| {
                sys.close(fd);
                last_err = err;
                continue;
            };
            return fromFd(alloc, fd);
        }
        return last_err;
    }

    /// Authenticate and say Hello over an already connected socket. Takes
    /// ownership of fd (closed on error).
    pub fn fromFd(alloc: std.mem.Allocator, fd: sys.fd_t) !Connection {
        var self = Connection{ .fd = fd, .alloc = alloc };
        errdefer self.deinit();
        try self.auth();
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

    fn writeAll(self: *Connection, data: []const u8) !void {
        try sys.writeAll(self.fd, data);
    }

    fn auth(self: *Connection) !void {
        const uid = sys.getuid();
        var uidbuf: [16]u8 = undefined;
        const uidstr = try std.fmt.bufPrint(&uidbuf, "{d}", .{uid});
        var hexbuf: [32]u8 = undefined;
        var hexlen: usize = 0;
        for (uidstr) |c| {
            _ = try std.fmt.bufPrint(hexbuf[hexlen..], "{x:0>2}", .{c});
            hexlen += 2;
        }
        var msg: [64]u8 = undefined;
        const auth_msg = try std.fmt.bufPrint(&msg, "\x00AUTH EXTERNAL {s}\r\n", .{hexbuf[0..hexlen]});
        try self.writeAll(auth_msg);

        // read one line: "OK <guid>\r\n"
        const deadline = sys.monoMs() + default_reply_timeout_ms;
        var line: [512]u8 = undefined;
        var n: usize = 0;
        while (true) {
            if (!try sys.waitReadable(self.fd, deadline)) return error.Timeout;
            const r = try sys.read(self.fd, line[n .. n + 1]);
            if (r == 0) return error.AuthFailed;
            n += 1;
            if (n >= 2 and line[n - 2] == '\r' and line[n - 1] == '\n') break;
            if (n >= line.len) return error.AuthFailed;
        }
        if (!std.mem.startsWith(u8, line[0..n], "OK ")) return error.AuthFailed;

        // negotiate fd passing (needed for portal OpenPipeWireRemote)
        try self.writeAll("NEGOTIATE_UNIX_FD\r\n");
        n = 0;
        while (true) {
            if (!try sys.waitReadable(self.fd, deadline)) return error.Timeout;
            const r = try sys.read(self.fd, line[n .. n + 1]);
            if (r == 0) return error.AuthFailed;
            n += 1;
            if (n >= 2 and line[n - 2] == '\r' and line[n - 1] == '\n') break;
            if (n >= line.len) return error.AuthFailed;
        }
        self.unix_fd_ok = std.mem.startsWith(u8, line[0..n], "AGREE_UNIX_FD");
        try self.writeAll("BEGIN\r\n");
    }

    fn hello(self: *Connection) !void {
        const serial = try self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", &.{});
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
        const serial = self.nextSerial();
        try self.sendMessage(.method_call, serial, .{
            .path = path,
            .interface = interface,
            .member = member,
            .destination = destination,
            .signature = signature,
        }, body, null);
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
        try self.sendMessage(.signal, self.nextSerial(), .{
            .path = path,
            .interface = interface,
            .member = member,
            .signature = signature,
        }, body, null);
    }

    pub fn replyTo(self: *Connection, call: *const Message, signature: []const u8, body: []const u8) !void {
        try self.sendMessageFds(.method_return, self.nextSerial(), .{
            .destination = call.sender,
            .signature = signature,
        }, body, call.serial, &.{});
    }

    /// Reply attaching file descriptors ('h' args are indexes into fds).
    pub fn replyToWithFds(self: *Connection, call: *const Message, signature: []const u8, body: []const u8, fds: []const sys.fd_t) !void {
        try self.sendMessageFds(.method_return, self.nextSerial(), .{
            .destination = call.sender,
            .signature = signature,
        }, body, call.serial, fds);
    }

    pub fn replyError(self: *Connection, call: *const Message, error_name: []const u8, text: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(text);
        try self.sendMessage(.@"error", self.nextSerial(), .{
            .destination = call.sender,
            .error_name = error_name,
            .signature = "s",
        }, m.buf.items, call.serial);
    }

    const HeaderFields = struct {
        path: ?[]const u8 = null,
        interface: ?[]const u8 = null,
        member: ?[]const u8 = null,
        destination: ?[]const u8 = null,
        error_name: ?[]const u8 = null,
        signature: ?[]const u8 = null,
    };

    fn sendMessage(
        self: *Connection,
        mtype: MessageType,
        serial: u32,
        fields: HeaderFields,
        body: []const u8,
        reply_serial: ?u32,
    ) !void {
        try self.sendMessageFds(mtype, serial, fields, body, reply_serial, &.{});
    }

    fn sendMessageFds(
        self: *Connection,
        mtype: MessageType,
        serial: u32,
        fields: HeaderFields,
        body: []const u8,
        reply_serial: ?u32,
        fds: []const sys.fd_t,
    ) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putByte('l'); // little-endian
        try m.putByte(@backingInt(mtype));
        try m.putByte(if (mtype == .method_call) 0 else 1); // NO_REPLY_EXPECTED on non-calls
        try m.putByte(1); // protocol version
        try m.putU32(@intCast(body.len));
        try m.putU32(serial);

        const mark = try m.beginArray(8);
        if (fields.path) |v| try putHeaderField(&m, .path, 'o', v);
        if (fields.interface) |v| try putHeaderField(&m, .interface, 's', v);
        if (fields.member) |v| try putHeaderField(&m, .member, 's', v);
        if (fields.error_name) |v| try putHeaderField(&m, .error_name, 's', v);
        if (fields.destination) |v| try putHeaderField(&m, .destination, 's', v);
        if (reply_serial) |rs| {
            try m.beginStruct();
            try m.putByte(@backingInt(FieldCode.reply_serial));
            try m.putSignature("u");
            try m.putU32(rs);
        }
        if (fields.signature) |v| {
            if (v.len > 0) {
                try m.beginStruct();
                try m.putByte(@backingInt(FieldCode.signature));
                try m.putSignature("g");
                try m.putSignature(v);
            }
        }
        if (fds.len > 0) {
            try m.beginStruct();
            try m.putByte(@backingInt(FieldCode.unix_fds));
            try m.putSignature("u");
            try m.putU32(@intCast(fds.len));
        }
        m.endArray(mark);
        try m.pad(8); // header padded to 8 before body

        if (fds.len > 0) {
            // fds must travel with the message bytes
            var sent: usize = 0;
            var fds_sent = false;
            while (sent < m.buf.items.len) {
                const f: []const sys.fd_t = if (!fds_sent) fds else &.{};
                sent += try sys.sendWithFds(self.fd, m.buf.items[sent..], f);
                fds_sent = true;
            }
            try self.writeAll(body);
        } else {
            try self.writeAll(m.buf.items);
            try self.writeAll(body);
        }
    }

    fn putHeaderField(m: *Marshal, code: FieldCode, type_char: u8, value: []const u8) !void {
        try m.beginStruct();
        try m.putByte(@backingInt(code));
        try m.putSignature(&.{type_char});
        try m.putString(value);
    }

    fn readExact(self: *Connection, buf: []u8, deadline_ms: ?i64) !void {
        var off: usize = 0;
        while (off < buf.len) {
            if (deadline_ms != null and !try sys.waitReadable(self.fd, deadline_ms)) {
                // a message started arriving but stalled: the stream position
                // is now unknown, so the connection cannot be reused
                if (off > 0) return error.BadMessageFraming;
                return error.Timeout;
            }
            const n = try sys.recvWithFds(self.fd, buf[off..], &self.in_fds, self.alloc);
            if (n == 0) return error.Disconnected;
            off += n;
        }
    }

    /// Read and throw away `len` bytes (keeps the stream in sync after a
    /// message we refuse to keep).
    fn discard(self: *Connection, len: usize, deadline_ms: ?i64) !void {
        var scratch: [4096]u8 = undefined;
        var left = len;
        while (left > 0) {
            const n = @min(left, scratch.len);
            self.readExact(scratch[0..n], deadline_ms) catch |err| switch (err) {
                error.Timeout => return error.BadMessageFraming,
                else => return err,
            };
            left -= n;
        }
    }

    /// Blocking read of the next complete message.
    pub fn readMessage(self: *Connection) !Message {
        return (try self.readMessageDeadline(null)) orelse unreachable;
    }

    /// Read the next complete message, or null if none starts arriving
    /// before `deadline_ms` (monotonic). Malformed messages are consumed
    /// whole and reported as a non-fatal error (see isFatal).
    pub fn readMessageDeadline(self: *Connection, deadline_ms: ?i64) !?Message {
        var fixed: [16]u8 = undefined;
        self.readExact(&fixed, deadline_ms) catch |err| switch (err) {
            error.Timeout => return null,
            else => return err,
        };
        // once a message has begun, finish reading it within a fixed bound
        const body_deadline = sys.monoMs() + default_reply_timeout_ms;
        const endian: std.builtin.Endian = switch (fixed[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadMessageFraming,
        };
        const body_len = std.mem.readInt(u32, fixed[4..8], endian);
        const serial = std.mem.readInt(u32, fixed[8..12], endian);
        const fields_len = std.mem.readInt(u32, fixed[12..16], endian);
        const fields_padded = std.mem.alignForward(usize, fields_len, 8);
        const total = fields_padded + @as(usize, body_len);
        // spec maximum is 128 MiB; cap well below to bound allocations
        if (body_len > 32 * 1024 * 1024 or fields_len > 1024 * 1024) {
            if (body_len > 128 * 1024 * 1024 or fields_len > 64 * 1024 * 1024) return error.BadMessageFraming;
            try self.discard(total, body_deadline);
            self.dropFds(0);
            return error.MessageTooLarge;
        }
        if (endian == .big) {
            try self.discard(total, body_deadline);
            self.dropFds(0);
            return error.BigEndianUnsupported;
        }
        const mtype: MessageType = switch (fixed[1]) {
            1 => .method_call,
            2 => .method_return,
            3 => .@"error",
            4 => .signal,
            else => .invalid,
        };

        const raw = try self.alloc.alloc(u8, total);
        errdefer self.alloc.free(raw);
        try self.readExact(raw, body_deadline);

        var msg = Message{
            .type = mtype,
            .serial = serial,
            .body = raw[fields_padded..],
            .raw = raw,
        };
        errdefer for (msg.fds[0..msg.n_fds]) |fd| {
            if (fd >= 0) sys.close(fd);
        };
        try self.parseHeaderFields(&msg, raw[0..fields_len]);
        return msg;
    }

    /// Close `count` fds from the front of the received queue (fds that
    /// arrived with a message we drop). count 0 closes everything queued.
    fn dropFds(self: *Connection, count: usize) void {
        const n = if (count == 0) self.in_fds.items.len else @min(count, self.in_fds.items.len);
        for (self.in_fds.items[0..n]) |fd| sys.close(fd);
        std.mem.copyForwards(sys.fd_t, self.in_fds.items[0..], self.in_fds.items[n..]);
        self.in_fds.shrinkRetainingCapacity(self.in_fds.items.len - n);
    }

    fn parseHeaderFields(self: *Connection, msg: *Message, fields: []const u8) !void {
        var r = Reader{ .data = fields, .pos = 0 };
        // fds are claimed last so a malformed field cannot strand them
        var fd_count: ?u32 = null;
        var bad: ?anyerror = null;
        while (r.pos < fields.len) {
            r.pad(8);
            if (r.pos >= fields.len) break;
            const code = r.readByte() catch |e| {
                bad = e;
                break;
            };
            const sig = r.readSignature() catch |e| {
                bad = e;
                break;
            };
            const expected: ?[]const u8 = switch (code) {
                @backingInt(FieldCode.path) => "o",
                @backingInt(FieldCode.interface),
                @backingInt(FieldCode.member),
                @backingInt(FieldCode.error_name),
                @backingInt(FieldCode.destination),
                @backingInt(FieldCode.sender),
                => "s",
                @backingInt(FieldCode.reply_serial), @backingInt(FieldCode.unix_fds) => "u",
                @backingInt(FieldCode.signature) => "g",
                else => null,
            };
            if (expected) |e| {
                if (!std.mem.eql(u8, sig, e)) {
                    bad = error.BadHeaderField;
                    break;
                }
            }
            const res = switch (code) {
                @backingInt(FieldCode.path) => if (r.readString()) |v| {
                    msg.path = v;
                } else |e| e,
                @backingInt(FieldCode.interface) => if (r.readString()) |v| {
                    msg.interface = v;
                } else |e| e,
                @backingInt(FieldCode.member) => if (r.readString()) |v| {
                    msg.member = v;
                } else |e| e,
                @backingInt(FieldCode.error_name) => if (r.readString()) |v| {
                    msg.error_name = v;
                } else |e| e,
                @backingInt(FieldCode.reply_serial) => if (r.readU32()) |v| {
                    msg.reply_serial = v;
                } else |e| e,
                @backingInt(FieldCode.destination) => if (r.readString()) |v| {
                    msg.destination = v;
                } else |e| e,
                @backingInt(FieldCode.sender) => if (r.readString()) |v| {
                    msg.sender = v;
                } else |e| e,
                @backingInt(FieldCode.signature) => if (r.readSignature()) |v| {
                    msg.signature = v;
                } else |e| e,
                @backingInt(FieldCode.unix_fds) => if (r.readU32()) |v| {
                    fd_count = v;
                } else |e| e,
                else => r.skipValue(sig),
            };
            res catch |e| {
                bad = e;
                break;
            };
        }

        if (fd_count) |count| {
            // fds attached to this message have been collected by the recv
            // calls that consumed its bytes; they belong to it whatever
            // happens next, so surplus or orphaned ones are closed here
            if (count > msg.fds.len) {
                self.dropFds(count);
                return error.TooManyFds;
            }
            if (self.in_fds.items.len < count) {
                self.dropFds(0);
                return error.MissingFds;
            }
            for (0..count) |i| msg.fds[i] = self.in_fds.items[i];
            msg.n_fds = @intCast(count);
            std.mem.copyForwards(sys.fd_t, self.in_fds.items[0..], self.in_fds.items[count..]);
            self.in_fds.shrinkRetainingCapacity(self.in_fds.items.len - count);
        }
        if (bad) |e| return e;
        if (msg.type == .invalid) return error.BadMessageType;
    }

    /// Wait for the reply to `serial`, up to default_reply_timeout_ms.
    /// Unrelated messages (e.g. incoming method calls while we block) are
    /// queued for nextMessage, not dropped.
    pub fn waitReply(self: *Connection, serial: u32) !Message {
        return self.waitReplyTimeout(serial, default_reply_timeout_ms);
    }

    pub fn waitReplyTimeout(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        const deadline = sys.monoMs() + timeout_ms;
        while (true) {
            var msg = (self.readMessageDeadline(deadline) catch |err| {
                if (isFatal(err)) return err;
                std.log.warn("dropped malformed bus message: {t}", .{err});
                continue;
            }) orelse return error.Timeout;
            if (msg.reply_serial == serial) {
                if (msg.type == .@"error") {
                    const name = msg.error_name orelse "unknown";
                    std.log.warn("dbus error reply: {s}", .{name});
                    msg.deinit(self.alloc);
                    return error.DBusError;
                }
                return msg;
            }
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
        const serial = try self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        reply.deinit(self.alloc);
    }

    pub fn nameHasOwner(self: *Connection, name: []const u8) !bool {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(name);
        const serial = try self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", m.buf.items);
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
        const serial = try self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", m.buf.items);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        const code = try r.readU32();
        return code == 1; // PRIMARY_OWNER
    }
};

test "dict marshal/read roundtrip" {
    const alloc = std.testing.allocator;
    var m = Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("uri");
    try m.putVariantString("file:///tmp/x.png");
    try m.beginStruct();
    try m.putString("count");
    try m.putVariantU32(7);
    m.endArray(arr);

    var r = Reader{ .data = m.buf.items, .pos = 0 };
    var it = try r.readDictSV();
    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("uri", e1.key);
    try std.testing.expectEqualStrings("file:///tmp/x.png", e1.value.string);
    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("count", e2.key);
    try std.testing.expectEqual(@as(u32, 7), e2.value.u32_);
    try std.testing.expectEqual(@as(?@TypeOf(e1), null), try it.next());
}

test "reader skips unknown variant types" {
    const alloc = std.testing.allocator;
    var m = Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("blob");
    try m.putSignature("ay");
    const inner = try m.beginArray(1);
    try m.putByte(1);
    try m.putByte(2);
    m.endArray(inner);
    try m.beginStruct();
    try m.putString("after");
    try m.putVariantU32(42);
    m.endArray(arr);

    var r = Reader{ .data = m.buf.items, .pos = 0 };
    var it = try r.readDictSV();
    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("blob", e1.key);
    try std.testing.expect(e1.value == .other);
    const e2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 42), e2.value.u32_);
}

test "marshal alignment" {
    var m = Marshal.init(std.testing.allocator);
    defer m.deinit();
    try m.putByte(1);
    try m.putU32(0xAABBCCDD);
    try std.testing.expectEqual(@as(usize, 8), m.buf.items.len);
    try std.testing.expectEqual(@as(u8, 0xDD), m.buf.items[4]);
}

test "bus address lists, abstract sockets and escapes" {
    var buf: [512]u8 = undefined;
    var out: [8]Address = undefined;
    const got = try parseAddresses(
        "tcp:host=x,port=1;unix:abstract=/tmp/dbus-AbC,guid=12;unix:path=/run/user/1000/My%20Bus,guid=34;unix:path=/bad%2",
        &buf,
        &out,
    );
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/tmp/dbus-AbC", got[0].abstract);
    try std.testing.expectEqualStrings("/run/user/1000/My Bus", got[1].path);

    const none = try parseAddresses("tcp:host=localhost;garbage", &buf, &out);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

fn testPair(alloc: std.mem.Allocator) ![2]Connection {
    const fds = try sys.socketPair();
    return .{
        .{ .fd = fds[0], .alloc = alloc },
        .{ .fd = fds[1], .alloc = alloc },
    };
}

test "readMessage parses header fields and claims fds" {
    const alloc = std.testing.allocator;
    var pair = try testPair(alloc);
    defer pair[0].deinit();
    defer pair[1].deinit();

    var m = Marshal.init(alloc);
    defer m.deinit();
    try m.putString("hello");
    try m.putU32(7);

    var pipe: [2]sys.fd_t = undefined;
    _ = std.os.linux.pipe2(&pipe, .{ .CLOEXEC = true });
    defer sys.close(pipe[0]);
    try pair[0].sendMessageFds(.signal, 42, .{
        .path = "/org/x",
        .interface = "org.x.Iface",
        .member = "Ping",
        .signature = "su",
    }, m.buf.items, 9, &.{pipe[1]});
    sys.close(pipe[1]); // the receiver holds its own copy now

    var msg = try pair[1].readMessage();
    defer msg.deinit(alloc);
    try std.testing.expectEqual(MessageType.signal, msg.type);
    try std.testing.expectEqual(@as(u32, 42), msg.serial);
    try std.testing.expectEqual(@as(?u32, 9), msg.reply_serial);
    try std.testing.expectEqualStrings("/org/x", msg.path.?);
    try std.testing.expectEqualStrings("su", msg.signature.?);
    try std.testing.expect(msg.isSignal("org.x.Iface", "Ping"));
    var r = msg.reader();
    try std.testing.expectEqualStrings("hello", try r.readString());
    try std.testing.expectEqual(@as(u32, 7), try r.readU32());
    try std.testing.expectEqual(@as(u8, 1), msg.n_fds);
    try std.testing.expectEqual(@as(usize, 0), pair[1].in_fds.items.len);

    // the claimed fd is the write end of our pipe
    const wfd = msg.takeFd().?;
    defer sys.close(wfd);
    try sys.writeAll(wfd, "x");
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.read(pipe[0], &b));
}

test "too many fds are closed and the stream stays usable" {
    const alloc = std.testing.allocator;
    var pair = try testPair(alloc);
    defer pair[0].deinit();
    defer pair[1].deinit();

    var pipe: [2]sys.fd_t = undefined;
    _ = std.os.linux.pipe2(&pipe, .{ .CLOEXEC = true });
    defer sys.close(pipe[0]);
    const many = [_]sys.fd_t{ pipe[1], pipe[1], pipe[1], pipe[1], pipe[1], pipe[1] };
    try pair[0].sendMessageFds(.signal, 1, .{ .path = "/a", .interface = "a.b", .member = "C" }, &.{}, null, &many);
    sys.close(pipe[1]);
    try pair[0].sendMessage(.signal, 2, .{ .path = "/a", .interface = "a.b", .member = "D" }, &.{}, null);

    try std.testing.expectError(error.TooManyFds, pair[1].readMessage());
    try std.testing.expectEqual(@as(usize, 0), pair[1].in_fds.items.len);
    // every copy of the write end is gone: the pipe reports EOF
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try sys.read(pipe[0], &b));

    var next = try pair[1].readMessage();
    defer next.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), next.serial);
}

test "readMessageDeadline times out and drops malformed headers" {
    const alloc = std.testing.allocator;
    var pair = try testPair(alloc);
    defer pair[0].deinit();
    defer pair[1].deinit();

    const t0 = sys.monoMs();
    try std.testing.expectEqual(@as(?Message, null), try pair[1].readMessageDeadline(t0 + 30));
    try std.testing.expect(sys.monoMs() - t0 >= 25);

    // header field PATH declared as 'u' instead of 'o'
    var m = Marshal.init(alloc);
    defer m.deinit();
    try m.putByte('l');
    try m.putByte(4);
    try m.putByte(1);
    try m.putByte(1);
    try m.putU32(0);
    try m.putU32(5);
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putByte(1);
    try m.putSignature("u");
    try m.putU32(3);
    m.endArray(arr);
    try m.pad(8);
    try sys.writeAll(pair[0].fd, m.buf.items);
    try pair[0].sendMessage(.signal, 6, .{ .path = "/ok", .interface = "a.b", .member = "C" }, &.{}, null);

    const err = pair[1].readMessage();
    try std.testing.expectError(error.BadHeaderField, err);
    try std.testing.expect(!isFatal(error.BadHeaderField));
    var ok = try pair[1].readMessage();
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("/ok", ok.path.?);
}

test "skipType rejects truncated signatures and data" {
    const data = [_]u8{ 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0 };
    const sigs = [_][]const u8{ "a", "(", "(i", "a{", "a{s", "a(i", ")", "}", "v", "", "aaaa", "z" };
    for (sigs) |sig| {
        var r = Reader{ .data = &data, .pos = 0 };
        var idx: usize = 0;
        if (r.skipType(sig, &idx)) |_| {} else |_| {}
    }
    // array length larger than the data
    var r = Reader{ .data = &data, .pos = 0 };
    var idx: usize = 0;
    try std.testing.expectError(error.BadArrayLength, r.skipType("ay", &idx));

    // variants nested beyond the depth limit
    var deep: [3 * 200 + 4]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= 600) : (i += 3) {
        deep[i] = 1;
        deep[i + 1] = 'v';
        deep[i + 2] = 0;
    }
    var rd = Reader{ .data = deep[0..600], .pos = 0 };
    try std.testing.expectError(error.TooDeep, rd.readVariant());
}

/// Exercise every Reader entry point on `data`; only errors are allowed.
fn fuzzOne(data: []const u8, sig: []const u8) void {
    {
        var r = Reader{ .data = data, .pos = 0 };
        var idx: usize = 0;
        while (idx < sig.len) {
            r.skipType(sig, &idx) catch break;
        }
    }
    {
        var r = Reader{ .data = data, .pos = 0 };
        if (r.readDictSV()) |it0| {
            var it = it0;
            var guard: usize = 0;
            while (guard < 10_000) : (guard += 1) {
                const e = it.next() catch break;
                if (e == null) break;
            }
        } else |_| {}
    }
    {
        var r = Reader{ .data = data, .pos = 0 };
        _ = r.readU32() catch {};
        _ = r.readVariant() catch {};
        _ = r.readString() catch {};
    }
    {
        var conn = Connection{ .fd = -1, .alloc = std.testing.allocator };
        defer {
            conn.in_fds.deinit(conn.alloc);
        }
        var msg = Message{ .type = .signal, .serial = 1 };
        conn.parseHeaderFields(&msg, data) catch {};
    }
}

test "fuzz: random and mutated bytes never crash the reader" {
    var prng = std.Random.DefaultPrng.init(0x5107_1e7);
    const rand = prng.random();
    const alphabet = "ybnqiuxtdhsogva(){}";

    // a realistic seed: a portal Start response body
    var m = Marshal.init(std.testing.allocator);
    defer m.deinit();
    try m.putU32(0);
    const dict = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("streams");
    try m.putSignature("a(ua{sv})");
    const streams = try m.beginArray(8);
    try m.beginStruct();
    try m.putU32(42);
    const props = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("position");
    try m.putSignature("(ii)");
    try m.beginStruct();
    try m.putI32(1920);
    try m.putI32(0);
    m.endArray(props);
    m.endArray(streams);
    try m.beginStruct();
    try m.putString("restore_token");
    try m.putVariantString("abc");
    m.endArray(dict);
    const seed = m.buf.items;

    var buf: [512]u8 = undefined;
    var sigbuf: [24]u8 = undefined;
    var iter: usize = 0;
    while (iter < 20_000) : (iter += 1) {
        const len: usize = rand.uintLessThan(usize, buf.len);
        if (iter % 2 == 0) {
            rand.bytes(buf[0..len]);
        } else {
            const n = @min(len, seed.len);
            @memcpy(buf[0..n], seed[0..n]);
            var flips = rand.uintLessThan(usize, 6) + 1;
            while (flips > 0 and n > 0) : (flips -= 1) {
                buf[rand.uintLessThan(usize, n)] = rand.int(u8);
            }
        }
        const slen = rand.uintLessThan(usize, sigbuf.len);
        for (sigbuf[0..slen]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        fuzzOne(buf[0..len], sigbuf[0..slen]);
        fuzzOne(buf[0..@min(len, seed.len)], "ua{sv}");
    }
}
