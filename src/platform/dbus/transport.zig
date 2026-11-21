//! Message framing over the connection socket: sending messages (with
//! SCM_RIGHTS fds), reading them back, and handing received fds to the
//! message that announced them.

const std = @import("std");
const sys = @import("../sys.zig");
const Marshal = @import("marshal.zig").Marshal;
const Reader = @import("reader.zig").Reader;
const message = @import("message.zig");
const Message = message.Message;
const MessageType = message.MessageType;
const HeaderFields = message.HeaderFields;
const Connection = @import("connection.zig").Connection;

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

pub fn sendMessage(
    conn: *Connection,
    mtype: MessageType,
    serial: u32,
    fields: HeaderFields,
    body: []const u8,
    reply_serial: ?u32,
) !void {
    try sendMessageFds(conn, mtype, serial, fields, body, reply_serial, &.{});
}

pub fn sendMessageFds(
    conn: *Connection,
    mtype: MessageType,
    serial: u32,
    fields: HeaderFields,
    body: []const u8,
    reply_serial: ?u32,
    fds: []const sys.fd_t,
) !void {
    var m = Marshal.init(conn.alloc);
    defer m.deinit();
    try message.encodeHeader(&m, mtype, serial, fields, body.len, reply_serial, fds.len);
    if (fds.len > 0) {
        try sendHeaderWithFds(conn.fd, m.buf.items, fds);
    } else {
        try sys.writeAll(conn.fd, m.buf.items);
    }
    try sys.writeAll(conn.fd, body);
}

/// Write the header so that `fds` travel with its first bytes.
fn sendHeaderWithFds(fd: sys.fd_t, header: []const u8, fds: []const sys.fd_t) !void {
    var sent: usize = 0;
    var fds_sent = false;
    while (sent < header.len) {
        const f: []const sys.fd_t = if (!fds_sent) fds else &.{};
        sent += try sys.sendWithFds(fd, header[sent..], f);
        fds_sent = true;
    }
}

fn readExact(conn: *Connection, buf: []u8, deadline_ms: ?i64) !void {
    var off: usize = 0;
    while (off < buf.len) {
        if (deadline_ms != null and !try sys.waitReadable(conn.fd, deadline_ms)) {
            // a message started arriving but stalled: the stream position
            // is now unknown, so the connection cannot be reused
            if (off > 0) return error.BadMessageFraming;
            return error.Timeout;
        }
        const n = try sys.recvWithFds(conn.fd, buf[off..], &conn.in_fds, conn.alloc);
        if (n == 0) return error.Disconnected;
        off += n;
    }
}

/// Read and throw away `len` bytes (keeps the stream in sync after a
/// message we refuse to keep).
fn discard(conn: *Connection, len: usize, deadline_ms: ?i64) !void {
    var scratch: [4096]u8 = undefined;
    var left = len;
    while (left > 0) {
        const n = @min(left, scratch.len);
        readExact(conn, scratch[0..n], deadline_ms) catch |err| switch (err) {
            error.Timeout => return error.BadMessageFraming,
            else => return err,
        };
        left -= n;
    }
}

/// Read the next complete message, or null if none starts arriving
/// before `deadline_ms` (monotonic). Malformed messages are consumed
/// whole and reported as a non-fatal error (see isFatal).
pub fn readMessageDeadline(conn: *Connection, deadline_ms: ?i64) !?Message {
    var fixed: [16]u8 = undefined;
    readExact(conn, &fixed, deadline_ms) catch |err| switch (err) {
        error.Timeout => return null,
        else => return err,
    };
    // once a message has begun, finish reading it within a fixed bound
    const body_deadline = sys.monoMs() + default_reply_timeout_ms;
    const hdr = try message.FixedHeader.parse(&fixed);
    try rejectUnsupported(conn, hdr, body_deadline);

    const raw = try conn.alloc.alloc(u8, hdr.restLen());
    errdefer conn.alloc.free(raw);
    try readExact(conn, raw, body_deadline);

    var msg = Message{
        .type = hdr.mtype,
        .serial = hdr.serial,
        .body = raw[hdr.fieldsPadded()..],
        .raw = raw,
    };
    errdefer for (msg.fds[0..msg.n_fds]) |fd| {
        if (fd >= 0) sys.close(fd);
    };
    try parseHeaderFields(conn, &msg, raw[0..hdr.fields_len]);
    return msg;
}

/// Consume and refuse oversized or big-endian messages (closing any fds
/// that came with them). Hopelessly oversized ones are fatal.
fn rejectUnsupported(conn: *Connection, hdr: message.FixedHeader, deadline_ms: i64) !void {
    // spec maximum is 128 MiB; cap well below to bound allocations
    if (hdr.body_len > 32 * 1024 * 1024 or hdr.fields_len > 1024 * 1024) {
        if (hdr.body_len > 128 * 1024 * 1024 or hdr.fields_len > 64 * 1024 * 1024) return error.BadMessageFraming;
        try discard(conn, hdr.restLen(), deadline_ms);
        dropFds(conn, 0);
        return error.MessageTooLarge;
    }
    if (hdr.endian == .big) {
        try discard(conn, hdr.restLen(), deadline_ms);
        dropFds(conn, 0);
        return error.BigEndianUnsupported;
    }
}

/// Close `count` fds from the front of the received queue (fds that
/// arrived with a message we drop). count 0 closes everything queued.
fn dropFds(conn: *Connection, count: usize) void {
    const n = if (count == 0) conn.in_fds.items.len else @min(count, conn.in_fds.items.len);
    for (conn.in_fds.items[0..n]) |fd| sys.close(fd);
    removeFrontFds(conn, n);
}

fn removeFrontFds(conn: *Connection, n: usize) void {
    std.mem.copyForwards(sys.fd_t, conn.in_fds.items[0..], conn.in_fds.items[n..]);
    conn.in_fds.shrinkRetainingCapacity(conn.in_fds.items.len - n);
}

/// Decode the header fields into `msg` and give it the fds it announced.
pub fn parseHeaderFields(conn: *Connection, msg: *Message, fields: []const u8) !void {
    // fds are claimed even after a malformed field so they cannot be stranded
    const parsed = message.parseHeaderFields(msg, fields);
    if (parsed.fd_count) |count| try claimFds(conn, msg, count);
    if (parsed.err) |e| return e;
    if (msg.type == .invalid) return error.BadMessageType;
}

/// Move `count` queued fds into `msg`.
fn claimFds(conn: *Connection, msg: *Message, count: u32) !void {
    // fds attached to this message have been collected by the recv
    // calls that consumed its bytes; they belong to it whatever
    // happens next, so surplus or orphaned ones are closed here
    if (count > msg.fds.len) {
        dropFds(conn, count);
        return error.TooManyFds;
    }
    if (conn.in_fds.items.len < count) {
        dropFds(conn, 0);
        return error.MissingFds;
    }
    for (0..count) |i| msg.fds[i] = conn.in_fds.items[i];
    msg.n_fds = @intCast(count);
    removeFrontFds(conn, count);
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
    try sendMessageFds(&pair[0], .signal, 42, .{
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
    try sendMessageFds(&pair[0], .signal, 1, .{ .path = "/a", .interface = "a.b", .member = "C" }, &.{}, null, &many);
    sys.close(pipe[1]);
    try sendMessage(&pair[0], .signal, 2, .{ .path = "/a", .interface = "a.b", .member = "D" }, &.{}, null);

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
    try sendMessage(&pair[0], .signal, 6, .{ .path = "/ok", .interface = "a.b", .member = "C" }, &.{}, null);

    const err = pair[1].readMessage();
    try std.testing.expectError(error.BadHeaderField, err);
    try std.testing.expect(!isFatal(error.BadHeaderField));
    var ok = try pair[1].readMessage();
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("/ok", ok.path.?);
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
        parseHeaderFields(&conn, &msg, data) catch {};
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
