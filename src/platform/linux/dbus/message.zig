//! DBus messages: the in-memory model plus header encoding and decoding.

const std = @import("std");
const sys = @import("../sys.zig");
const Marshal = @import("marshal.zig").Marshal;
const Reader = @import("reader.zig").Reader;

pub const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
};

pub const FieldCode = enum(u8) {
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
        self.closeFds();
        alloc.free(self.raw);
        self.* = undefined;
    }

    fn closeFds(self: *Message) void {
        for (self.fds[0..self.n_fds]) |fd| {
            if (fd >= 0) sys.close(fd);
        }
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
        return self.type == .signal and self.matches(iface, member);
    }

    pub fn isCall(self: *const Message, iface: []const u8, member: []const u8) bool {
        return self.type == .method_call and self.matches(iface, member);
    }

    fn matches(self: *const Message, iface: []const u8, member: []const u8) bool {
        return self.interface != null and std.mem.eql(u8, self.interface.?, iface) and
            self.member != null and std.mem.eql(u8, self.member.?, member);
    }

    pub fn reader(self: *const Message) Reader {
        return .{ .data = self.body, .pos = 0 };
    }
};

/// Optional string-valued header fields of an outgoing message.
pub const HeaderFields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

/// Append a complete little-endian message header to `m`, padded to 8 so
/// the body can follow directly.
pub fn encodeHeader(
    m: *Marshal,
    mtype: MessageType,
    serial: u32,
    fields: HeaderFields,
    body_len: usize,
    reply_serial: ?u32,
    n_fds: usize,
) !void {
    try m.putByte('l'); // little-endian
    try m.putByte(@backingInt(mtype));
    try m.putByte(if (mtype == .method_call) 0 else 1); // NO_REPLY_EXPECTED on non-calls
    try m.putByte(1); // protocol version
    try m.putU32(@intCast(body_len));
    try m.putU32(serial);

    const mark = try m.beginArray(8);
    try putFields(m, fields, reply_serial, n_fds);
    m.endArray(mark);
    try m.pad(8); // header padded to 8 before body
}

fn putFields(m: *Marshal, fields: HeaderFields, reply_serial: ?u32, n_fds: usize) !void {
    if (fields.path) |v| try putStringField(m, .path, 'o', v);
    if (fields.interface) |v| try putStringField(m, .interface, 's', v);
    if (fields.member) |v| try putStringField(m, .member, 's', v);
    if (fields.error_name) |v| try putStringField(m, .error_name, 's', v);
    if (fields.destination) |v| try putStringField(m, .destination, 's', v);
    if (reply_serial) |rs| try putU32Field(m, .reply_serial, rs);
    if (fields.signature) |v| {
        if (v.len > 0) {
            try m.beginStruct();
            try m.putByte(@backingInt(FieldCode.signature));
            try m.putSignature("g");
            try m.putSignature(v);
        }
    }
    if (n_fds > 0) try putU32Field(m, .unix_fds, @intCast(n_fds));
}

fn putStringField(m: *Marshal, code: FieldCode, type_char: u8, value: []const u8) !void {
    try m.beginStruct();
    try m.putByte(@backingInt(code));
    try m.putSignature(&.{type_char});
    try m.putString(value);
}

fn putU32Field(m: *Marshal, code: FieldCode, value: u32) !void {
    try m.beginStruct();
    try m.putByte(@backingInt(code));
    try m.putSignature("u");
    try m.putU32(value);
}

/// The fixed 16-byte prefix of every message.
pub const FixedHeader = struct {
    endian: std.builtin.Endian,
    mtype: MessageType,
    body_len: u32,
    serial: u32,
    fields_len: u32,

    pub fn parse(fixed: *const [16]u8) !FixedHeader {
        const endian: std.builtin.Endian = switch (fixed[0]) {
            'l' => .little,
            'B' => .big,
            else => return error.BadMessageFraming,
        };
        return .{
            .endian = endian,
            .mtype = switch (fixed[1]) {
                1 => .method_call,
                2 => .method_return,
                3 => .@"error",
                4 => .signal,
                else => .invalid,
            },
            .body_len = std.mem.readInt(u32, fixed[4..8], endian),
            .serial = std.mem.readInt(u32, fixed[8..12], endian),
            .fields_len = std.mem.readInt(u32, fixed[12..16], endian),
        };
    }

    /// Length of the header field array including padding before the body.
    pub fn fieldsPadded(self: FixedHeader) usize {
        return std.mem.alignForward(usize, self.fields_len, 8);
    }

    /// Bytes following the fixed prefix: padded fields plus body.
    pub fn restLen(self: FixedHeader) usize {
        return self.fieldsPadded() + @as(usize, self.body_len);
    }
};

/// Outcome of decoding a header field array: the UNIX_FDS count, if any,
/// and the error that stopped decoding, if any.
pub const ParsedFields = struct {
    fd_count: ?u32 = null,
    err: ?anyerror = null,
};

/// Decode the header field array into `msg`. Never fails outright: the
/// first malformed field stops decoding and is reported in `err`.
pub fn parseHeaderFields(msg: *Message, fields: []const u8) ParsedFields {
    var r = Reader{ .data = fields, .pos = 0 };
    var out: ParsedFields = .{};
    while (r.pos < fields.len) {
        r.pad(8);
        if (r.pos >= fields.len) break;
        readField(&r, msg, &out.fd_count) catch |e| {
            out.err = e;
            break;
        };
    }
    return out;
}

/// Read one (code, variant) header field and store it in `msg`.
fn readField(r: *Reader, msg: *Message, fd_count: *?u32) !void {
    const code = try r.readByte();
    const sig = try r.readSignature();
    if (expectedSignature(code)) |e| {
        if (!std.mem.eql(u8, sig, e)) return error.BadHeaderField;
    }
    switch (code) {
        @backingInt(FieldCode.path) => msg.path = try r.readString(),
        @backingInt(FieldCode.interface) => msg.interface = try r.readString(),
        @backingInt(FieldCode.member) => msg.member = try r.readString(),
        @backingInt(FieldCode.error_name) => msg.error_name = try r.readString(),
        @backingInt(FieldCode.reply_serial) => msg.reply_serial = try r.readU32(),
        @backingInt(FieldCode.destination) => msg.destination = try r.readString(),
        @backingInt(FieldCode.sender) => msg.sender = try r.readString(),
        @backingInt(FieldCode.signature) => msg.signature = try r.readSignature(),
        @backingInt(FieldCode.unix_fds) => fd_count.* = try r.readU32(),
        else => try r.skipValue(sig),
    }
}

/// The signature the spec mandates for a known field code.
fn expectedSignature(code: u8) ?[]const u8 {
    return switch (code) {
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
}
