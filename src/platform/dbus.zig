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
        const len = try self.readU32();
        if (self.pos + len + 1 > self.data.len) return error.ShortRead;
        defer self.pos += len + 1;
        return self.data[self.pos..][0..len];
    }
    pub fn readSignature(self: *Reader) ![]const u8 {
        const len = try self.readByte();
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
        switch (sig[0]) {
            's' => return .{ .string = try self.readString() },
            'o' => return .{ .object_path = try self.readString() },
            'b' => return .{ .boolean = (try self.readU32()) != 0 },
            'u' => return .{ .u32_ = try self.readU32() },
            'i' => return .{ .i32_ = @bitCast(try self.readU32()) },
            'x', 't' => return .{ .u64_ = try self.readU64() },
            'd' => return .{ .f64_ = @bitCast(try self.readU64()) },
            else => {
                var idx: usize = 0;
                try self.skipType(sig, &idx);
                return .other;
            },
        }
    }

    /// Skip one complete type starting at sig[idx.*]; advances idx past it.
    pub fn skipType(self: *Reader, sig: []const u8, idx: *usize) anyerror!void {
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
                try self.skipType(inner, &i);
            },
            'a' => {
                const len = try self.readU32();
                // element alignment
                const elem_align: usize = switch (sig[idx.*]) {
                    'y', 'g', 'v' => 1,
                    'n', 'q' => 2,
                    'b', 'u', 'i', 'h', 's', 'o', 'a' => 4,
                    'x', 't', 'd', '(', '{' => 8,
                    else => return error.BadSignature,
                };
                self.pad(elem_align);
                self.pos += len;
                // skip the element type in the signature
                var depth: usize = 0;
                while (true) {
                    const ec = sig[idx.*];
                    idx.* += 1;
                    switch (ec) {
                        'a' => continue, // array of...: keep consuming
                        '(', '{' => depth += 1,
                        ')', '}' => {
                            depth -= 1;
                            if (depth == 0) break;
                        },
                        else => {
                            if (depth == 0) break;
                        },
                    }
                }
            },
            '(', '{' => {
                self.pad(8);
                while (sig[idx.*] != ')' and sig[idx.*] != '}') {
                    try self.skipType(sig, idx);
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
            return .{ .key = key, .value = value };
        }
    };
};

pub const Connection = struct {
    fd: sys.fd_t,
    alloc: std.mem.Allocator,
    serial: u32 = 1,
    unique_name: []u8 = &.{},
    rbuf: [64 * 1024]u8 = undefined,
    rbuf_len: usize = 0,
    /// messages received while waiting for a specific reply
    pending: std.ArrayList(Message) = .empty,
    /// fds received via SCM_RIGHTS (consumed in arrival order)
    in_fds: std.ArrayList(sys.fd_t) = .empty,
    unix_fd_ok: bool = false,

    /// `address` is the value of DBUS_SESSION_BUS_ADDRESS.
    pub fn connectSession(alloc: std.mem.Allocator, addr_env: []const u8) !Connection {
        // expected form: unix:path=/run/user/1000/bus (possibly with ,guid=...)
        const prefix = "unix:path=";
        const start = std.mem.indexOf(u8, addr_env, prefix) orelse return error.UnsupportedBusAddress;
        var path = addr_env[start + prefix.len ..];
        if (std.mem.indexOfScalar(u8, path, ',')) |comma| path = path[0..comma];

        const fd = try sys.socketUnixStream();
        errdefer sys.close(fd);
        try sys.connectUnix(fd, path);

        var self = Connection{ .fd = fd, .alloc = alloc };
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
        var line: [512]u8 = undefined;
        var n: usize = 0;
        while (true) {
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
        try m.putByte(@intFromEnum(mtype));
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
            try m.putByte(@intFromEnum(FieldCode.reply_serial));
            try m.putSignature("u");
            try m.putU32(rs);
        }
        if (fields.signature) |v| {
            if (v.len > 0) {
                try m.beginStruct();
                try m.putByte(@intFromEnum(FieldCode.signature));
                try m.putSignature("g");
                try m.putSignature(v);
            }
        }
        if (fds.len > 0) {
            try m.beginStruct();
            try m.putByte(@intFromEnum(FieldCode.unix_fds));
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
        try m.putByte(@intFromEnum(code));
        try m.putSignature(&.{type_char});
        try m.putString(value);
    }

    fn readExact(self: *Connection, buf: []u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try sys.recvWithFds(self.fd, buf[off..], &self.in_fds, self.alloc);
            if (n == 0) return error.Disconnected;
            off += n;
        }
    }

    /// Blocking read of the next complete message.
    pub fn readMessage(self: *Connection) !Message {
        var fixed: [16]u8 = undefined;
        try self.readExact(&fixed);
        if (fixed[0] != 'l') return error.BigEndianUnsupported;
        const mtype: MessageType = switch (fixed[1]) {
            1 => .method_call,
            2 => .method_return,
            3 => .@"error",
            4 => .signal,
            else => .invalid,
        };
        const body_len = std.mem.readInt(u32, fixed[4..8], .little);
        const serial = std.mem.readInt(u32, fixed[8..12], .little);
        const fields_len = std.mem.readInt(u32, fixed[12..16], .little);
        // spec maximum is 128 MiB; cap well below to bound allocations
        if (body_len > 32 * 1024 * 1024 or fields_len > 1024 * 1024) return error.MessageTooLarge;
        const fields_padded = std.mem.alignForward(usize, fields_len, 8);

        const raw = try self.alloc.alloc(u8, fields_padded + body_len);
        errdefer self.alloc.free(raw);
        try self.readExact(raw);

        var msg = Message{
            .type = mtype,
            .serial = serial,
            .body = raw[fields_padded..],
            .raw = raw,
        };
        errdefer for (msg.fds[0..msg.n_fds]) |fd| {
            if (fd >= 0) sys.close(fd);
        };

        var r = Reader{ .data = raw[0..fields_len], .pos = 0 };
        while (r.pos < fields_len) {
            r.pad(8);
            if (r.pos >= fields_len) break;
            const code = try r.readByte();
            const sig = try r.readSignature();
            switch (code) {
                @intFromEnum(FieldCode.path) => msg.path = try r.readString(),
                @intFromEnum(FieldCode.interface) => msg.interface = try r.readString(),
                @intFromEnum(FieldCode.member) => msg.member = try r.readString(),
                @intFromEnum(FieldCode.error_name) => msg.error_name = try r.readString(),
                @intFromEnum(FieldCode.reply_serial) => msg.reply_serial = try r.readU32(),
                @intFromEnum(FieldCode.destination) => msg.destination = try r.readString(),
                @intFromEnum(FieldCode.sender) => msg.sender = try r.readString(),
                @intFromEnum(FieldCode.signature) => msg.signature = try r.readSignature(),
                @intFromEnum(FieldCode.unix_fds) => {
                    const count = try r.readU32();
                    if (count > msg.fds.len) return error.TooManyFds;
                    // fds attached to this message have been collected by the
                    // recv calls that consumed its bytes; claim them in order
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        if (self.in_fds.items.len == 0) return error.MissingFds;
                        msg.fds[i] = self.in_fds.orderedRemove(0);
                        msg.n_fds += 1;
                    }
                },
                else => {
                    var idx: usize = 0;
                    try r.skipType(sig, &idx);
                },
            }
        }
        return msg;
    }

    /// Wait for the reply to `serial`. Unrelated messages (e.g. incoming
    /// method calls while we block) are queued for nextMessage, not dropped.
    pub fn waitReply(self: *Connection, serial: u32) !Message {
        while (true) {
            var msg = try self.readMessage();
            if (msg.reply_serial == serial) {
                if (msg.type == .@"error") {
                    const name = msg.error_name orelse "unknown";
                    std.log.err("dbus error: {s}", .{name});
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

    /// True if a queued or buffered message may be available without blocking.
    pub fn hasPending(self: *const Connection) bool {
        return self.pending.items.len > 0;
    }

    pub fn addMatch(self: *Connection, rule: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(rule);
        const serial = try self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        reply.deinit(self.alloc);
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
