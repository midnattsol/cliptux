//! org.freedesktop.portal.ScreenCast: a one-shot monitor capture session
//! (create, select + start, open the PipeWire remote) and the streams it
//! hands out.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const request = @import("request.zig");

const Outcome = request.Outcome;
const Result = request.Result;
const notGranted = request.notGranted;
const iface = "org.freedesktop.portal.ScreenCast";

/// One captured monitor, as the portal describes it.
pub const Stream = struct {
    node_id: u32,
    /// top-left in the compositor's logical layout
    position: ?[2]i32 = null,
    /// logical size (not pixels: a 2x monitor reports half its pixel size)
    size: ?[2]i32 = null,
    source_type: u32 = 0,
};

pub const ScStart = struct {
    streams: []Stream,
    /// new restore token to persist for silent future sessions (owned)
    restore_token: ?[]u8 = null,

    pub fn deinit(self: *ScStart, alloc: std.mem.Allocator) void {
        alloc.free(self.streams);
        if (self.restore_token) |t| alloc.free(t);
        self.* = undefined;
    }
};

pub const ScreenCastSession = struct {
    session_path: []u8,
    start: ScStart,
    pw_fd: sys.fd_t,

    pub fn deinit(self: *ScreenCastSession, alloc: std.mem.Allocator) void {
        alloc.free(self.session_path);
        self.start.deinit(alloc);
        // pw_fd ownership is transferred to the PipeWire client; not closed here
        self.* = undefined;
    }
};

/// Stage 1: create a ScreenCast session. Returns the session path (owned).
pub fn scCreateSession(alloc: std.mem.Allocator, conn: *dbus.Connection) !Result([]u8) {
    var tok_buf: [64]u8 = undefined;
    var stok_buf: [64]u8 = undefined;
    const tok = try request.makeToken(&tok_buf, "shotlet_r");
    const stok = try request.makeToken(&stok_buf, "shotlet_s");

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(tok);
    try m.beginStruct();
    try m.putString("session_handle_token");
    try m.putVariantString(stok);
    m.endArray(arr);

    var req = try request.call(alloc, conn, iface, "CreateSession", "a{sv}", m.buf.items, tok, request.timeout_quick_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return notGranted([]u8, req.outcome.?);
    var r = try req.results();
    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        // spec says 's'; some versions send 'o'
        if (std.mem.eql(u8, e.key, "session_handle") and (std.mem.eql(u8, e.sig, "s") or std.mem.eql(u8, e.sig, "o")))
            return .{ .granted = try alloc.dupe(u8, try r.readString()) };
        try r.skipValue(e.sig);
    }
    return error.NoSessionHandle;
}

/// Stage 2: get the PipeWire socket fd for a started session.
pub fn scOpenRemote(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8) !sys.fd_t {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    const arr = try m.beginArray(8);
    m.endArray(arr);
    const serial = try conn.callMethod(request.bus_name, request.object_path, iface, "OpenPipeWireRemote", "oa{sv}", m.buf.items);
    var reply = try conn.waitReplyTimeout(serial, request.timeout_quick_ms);
    defer reply.deinit(alloc);
    return reply.takeFd() orelse error.NoPipeWireFd;
}

/// Stage 3: select monitor sources (all of them, so the whole desktop is
/// one capture) and start the cast. GNOME shows its picker here unless the
/// restore token still matches.
pub fn scSelectAndStart(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8, prev_token: ?[]const u8) !Result(ScStart) {
    const selected = try selectSources(alloc, conn, session_path, prev_token);
    if (selected != .granted) return notGranted(ScStart, selected);
    return startCast(alloc, conn, session_path);
}

/// SelectSources: every monitor, cursor hidden, the choice persisted
/// until revoked (and restored from `prev_token` when given).
fn selectSources(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8, prev_token: ?[]const u8) !Outcome {
    var tok_buf: [64]u8 = undefined;
    const tok = try request.makeToken(&tok_buf, "shotlet_r");
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(tok);
    try m.beginStruct();
    try m.putString("types");
    try m.putVariantU32(1); // MONITOR
    try m.beginStruct();
    try m.putString("multiple");
    try m.putVariantBool(true);
    try m.beginStruct();
    try m.putString("cursor_mode");
    try m.putVariantU32(1); // HIDDEN
    try m.beginStruct();
    try m.putString("persist_mode");
    try m.putVariantU32(2); // until revoked
    if (prev_token) |t| {
        try m.beginStruct();
        try m.putString("restore_token");
        try m.putVariantString(t);
    }
    m.endArray(arr);

    var req = try request.call(alloc, conn, iface, "SelectSources", "oa{sv}", m.buf.items, tok, request.timeout_dialog_ms);
    defer req.deinit(alloc);
    return req.outcome.?;
}

/// Start the cast and parse what it started.
fn startCast(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8) !Result(ScStart) {
    var tok_buf: [64]u8 = undefined;
    const tok = try request.makeToken(&tok_buf, "shotlet_r");
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    try m.putString(""); // parent window
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(tok);
    m.endArray(arr);

    var req = try request.call(alloc, conn, iface, "Start", "osa{sv}", m.buf.items, tok, request.timeout_dialog_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return notGranted(ScStart, req.outcome.?);
    var r = try req.results();
    return .{ .granted = try parseStartResults(alloc, &r) };
}

/// Parse the a{sv} results of ScreenCast.Start: every stream with its node
/// id, logical position and size, and the restore token. Values with an
/// unexpected signature are skipped, never misread.
pub fn parseStartResults(alloc: std.mem.Allocator, r: *dbus.Reader) !ScStart {
    var streams: std.ArrayList(Stream) = .empty;
    errdefer streams.deinit(alloc);
    var token: ?[]u8 = null;
    errdefer if (token) |t| alloc.free(t);

    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.key, "streams") and std.mem.eql(u8, e.sig, "a(ua{sv})")) {
            try parseStreams(alloc, r, &streams);
        } else if (std.mem.eql(u8, e.key, "restore_token") and std.mem.eql(u8, e.sig, "s")) {
            const t = try r.readString();
            if (token) |old| alloc.free(old);
            token = try alloc.dupe(u8, t);
        } else {
            try r.skipValue(e.sig);
        }
    }
    if (streams.items.len == 0) return error.NoStream;
    return .{ .streams = try streams.toOwnedSlice(alloc), .restore_token = token };
}

/// The "streams" a(ua{sv}) array; streams without a node id are dropped.
fn parseStreams(alloc: std.mem.Allocator, r: *dbus.Reader, streams: *std.ArrayList(Stream)) !void {
    const len = try r.readU32();
    r.pad(8);
    if (r.pos > r.data.len or len > r.data.len - r.pos) return error.ShortRead;
    const end = r.pos + len;
    while (r.pos < end) {
        r.pad(8);
        if (r.pos >= end) break;
        const st = try parseStream(r);
        if (st.node_id != 0) try streams.append(alloc, st);
    }
    if (r.pos != end) return error.BadArrayLength;
}

/// One (ua{sv}) stream: node id, then position, size and source_type.
fn parseStream(r: *dbus.Reader) !Stream {
    var st = Stream{ .node_id = try r.readU32() };
    var props = try r.readDictRaw();
    while (try props.next()) |p| {
        if (std.mem.eql(u8, p.sig, "(ii)") and
            (std.mem.eql(u8, p.key, "position") or std.mem.eql(u8, p.key, "size")))
        {
            r.pad(8);
            const a: i32 = @bitCast(try r.readU32());
            const b: i32 = @bitCast(try r.readU32());
            if (p.key[0] == 'p') st.position = .{ a, b } else st.size = .{ a, b };
        } else if (std.mem.eql(u8, p.key, "source_type") and std.mem.eql(u8, p.sig, "u")) {
            st.source_type = try r.readU32();
        } else {
            try r.skipValue(p.sig);
        }
    }
    if (st.size) |sz| {
        if (sz[0] <= 0 or sz[1] <= 0) st.size = null;
    }
    return st;
}

/// Open a ScreenCast session for monitor capture: create, select + start,
/// and open the PipeWire remote. With a valid restore token this is fully
/// silent; otherwise the compositor shows its source picker (persist_mode=2
/// remembers the choice).
pub fn openScreenCast(alloc: std.mem.Allocator, conn: *dbus.Connection, prev_token: ?[]const u8) !Result(ScreenCastSession) {
    const session_path = switch (try scCreateSession(alloc, conn)) {
        .granted => |p| p,
        else => |o| return notGranted(ScreenCastSession, o),
    };
    errdefer {
        closeSession(alloc, conn, session_path);
        alloc.free(session_path);
    }
    var started = switch (try scSelectAndStart(alloc, conn, session_path, prev_token)) {
        .granted => |st| st,
        else => |o| {
            closeSession(alloc, conn, session_path);
            alloc.free(session_path);
            return notGranted(ScreenCastSession, o);
        },
    };
    errdefer started.deinit(alloc);
    const pw_fd = try scOpenRemote(alloc, conn, session_path);
    return .{ .granted = .{ .session_path = session_path, .start = started, .pw_fd = pw_fd } };
}

/// Close a portal session (stops GNOME's screen-sharing indicator).
/// Fire-and-forget: the call is flushed but the reply is not awaited.
pub fn closeSession(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8) void {
    _ = alloc;
    _ = conn.callMethod(request.bus_name, session_path, "org.freedesktop.portal.Session", "Close", "", &.{}) catch return;
}

fn putStream(m: *dbus.Marshal, node: u32, pos: ?[2]i32, size: ?[2]i32) !void {
    try m.beginStruct();
    try m.putU32(node);
    const props = try m.beginArray(8);
    if (pos) |p| {
        try m.beginStruct();
        try m.putString("position");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(p[0]);
        try m.putI32(p[1]);
    }
    if (size) |sz| {
        try m.beginStruct();
        try m.putString("size");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(sz[0]);
        try m.putI32(sz[1]);
    }
    try m.beginStruct();
    try m.putString("source_type");
    try m.putVariantU32(1);
    try m.beginStruct();
    try m.putString("id");
    try m.putVariantString("monitor-x");
    m.endArray(props);
}

/// Test fixture: the body of a Start Response (code, then {streams,
/// restore_token}); `token_sig` "s" is well-formed, anything else is not.
pub fn startResponseBody(m: *dbus.Marshal, code: u32, token_sig: []const u8) !void {
    try m.putU32(code);
    const dict = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("streams");
    try m.putSignature("a(ua{sv})");
    const streams = try m.beginArray(8);
    try putStream(m, 41, .{ 0, 0 }, .{ 1280, 720 });
    try putStream(m, 42, .{ 1280, -100 }, .{ 1600, 900 });
    try putStream(m, 43, null, null);
    m.endArray(streams);
    try m.beginStruct();
    try m.putString("restore_token");
    if (std.mem.eql(u8, token_sig, "s")) {
        try m.putVariantString("tok-1");
    } else {
        try m.putVariantU32(5);
    }
    m.endArray(dict);
}

test "Start results: every stream with position and size" {
    const alloc = std.testing.allocator;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try startResponseBody(&m, 0, "s");

    var r = dbus.Reader{ .data = m.buf.items, .pos = 0 };
    try std.testing.expectEqual(@as(u32, 0), try r.readU32());
    var st = try parseStartResults(alloc, &r);
    defer st.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), st.streams.len);
    try std.testing.expectEqual(@as(u32, 41), st.streams[0].node_id);
    try std.testing.expectEqual([2]i32{ 1280, -100 }, st.streams[1].position.?);
    try std.testing.expectEqual([2]i32{ 1600, 900 }, st.streams[1].size.?);
    try std.testing.expectEqual(@as(u32, 1), st.streams[1].source_type);
    try std.testing.expect(st.streams[2].position == null and st.streams[2].size == null);
    try std.testing.expectEqualStrings("tok-1", st.restore_token.?);
}

test "Start results: a restore token of the wrong type is ignored" {
    const alloc = std.testing.allocator;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try startResponseBody(&m, 0, "u");
    var r = dbus.Reader{ .data = m.buf.items, .pos = 0 };
    _ = try r.readU32();
    var st = try parseStartResults(alloc, &r);
    defer st.deinit(alloc);
    try std.testing.expect(st.restore_token == null);
    try std.testing.expectEqual(@as(usize, 3), st.streams.len);

    // truncated anywhere: an error, never a crash or a leak
    var cut: usize = 4;
    while (cut < m.buf.items.len) : (cut += 1) {
        var rr = dbus.Reader{ .data = m.buf.items[0..cut], .pos = 4 };
        if (parseStartResults(alloc, &rr)) |res| {
            var x = res;
            x.deinit(alloc);
        } else |_| {}
    }
}
