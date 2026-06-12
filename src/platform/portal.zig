//! xdg-desktop-portal Screenshot + desktop notifications.

const std = @import("std");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");

pub const CaptureResult = struct {
    /// PNG bytes, owned by caller.
    png: []u8,
};

/// In-flight Screenshot request; feed it incoming DBus messages until done.
pub const Pending = struct {
    serial: u32,
    request_path: []u8,
    got_reply: bool = false,
    uri: ?[]u8 = null,
    err: ?anyerror = null,

    pub fn deinit(self: *Pending, alloc: std.mem.Allocator) void {
        alloc.free(self.request_path);
        if (self.uri) |u| alloc.free(u);
        self.* = undefined;
    }

    pub fn done(self: *const Pending) bool {
        return self.uri != null or self.err != null;
    }

    pub fn handleMessage(self: *Pending, alloc: std.mem.Allocator, msg: *const dbus.Message) !void {
        if (!self.got_reply and msg.reply_serial == self.serial) {
            if (msg.type == .@"error") {
                std.log.err("portal error: {s}", .{msg.error_name orelse "?"});
                self.err = error.PortalError;
                return;
            }
            var r = msg.reader();
            const handle = try r.readString();
            if (!std.mem.eql(u8, handle, self.request_path)) {
                alloc.free(self.request_path);
                self.request_path = try alloc.dupe(u8, handle);
            }
            self.got_reply = true;
            return;
        }
        if (msg.isSignal("org.freedesktop.portal.Request", "Response")) {
            if (msg.path == null or !std.mem.eql(u8, msg.path.?, self.request_path)) return;
            var r = msg.reader();
            const response = try r.readU32();
            if (response != 0) {
                self.err = if (response == 1) error.CaptureCancelled else error.PermissionDenied;
                return;
            }
            var it = try r.readDictSV();
            while (try it.next()) |entry| {
                if (std.mem.eql(u8, entry.key, "uri")) {
                    switch (entry.value) {
                        .string => |s| self.uri = try alloc.dupe(u8, s),
                        else => {},
                    }
                }
            }
            if (self.uri == null) self.err = error.NoUri;
        }
    }
};

/// Take a full-screen screenshot via org.freedesktop.portal.Screenshot.
/// Returns the PNG file contents and removes the temporary file from disk.
pub fn screenshot(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool) ![]u8 {
    var pending = try begin(alloc, conn, interactive);
    defer pending.deinit(alloc);
    while (!pending.done()) {
        // nextMessage drains messages parked by earlier waitReply calls
        var msg = try conn.nextMessage();
        defer msg.deinit(alloc);
        try pending.handleMessage(alloc, &msg);
    }
    if (pending.err) |e| return e;
    return readAndUnlink(alloc, pending.uri.?);
}

/// Start a Screenshot request; pump messages into the returned Pending.
pub fn begin(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool) !Pending {
    try conn.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response'");

    var token_buf: [48]u8 = undefined;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const token = try std.fmt.bufPrint(&token_buf, "cliptux_{d}_{d}", .{
        std.os.linux.getpid(),
        @as(u64, @intCast(ts.nsec)),
    });

    // Predicted request object path: /org/freedesktop/portal/desktop/request/SENDER/TOKEN
    // where SENDER is our unique name without ':' and with '.' -> '_'
    var sender_buf: [64]u8 = undefined;
    var sender_len: usize = 0;
    for (conn.unique_name) |c| {
        if (c == ':') continue;
        sender_buf[sender_len] = if (c == '.') '_' else c;
        sender_len += 1;
    }
    const expected_path = try std.fmt.allocPrint(
        alloc,
        "/org/freedesktop/portal/desktop/request/{s}/{s}",
        .{ sender_buf[0..sender_len], token },
    );
    defer alloc.free(expected_path);

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(""); // parent_window
    const arr = try m.beginArray(8);
    {
        try m.beginStruct();
        try m.putString("handle_token");
        try m.putVariantString(token);
        try m.beginStruct();
        try m.putString("interactive");
        try m.putVariantBool(interactive);
    }
    m.endArray(arr);

    const serial = try conn.callMethod(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Screenshot",
        "Screenshot",
        "sa{sv}",
        m.buf.items,
    );

    return .{
        .serial = serial,
        .request_path = try alloc.dupe(u8, expected_path),
    };
}

pub fn readAndUnlink(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const file_prefix = "file://";
    if (!std.mem.startsWith(u8, uri, file_prefix)) return error.BadUri;
    const path = try percentDecode(alloc, uri[file_prefix.len..]);
    defer alloc.free(path);

    const png = try sys.readFileAlloc(alloc, path, 256 * 1024 * 1024);
    // Honor "no files on disk": the portal wrote a temp screenshot; remove it.
    sys.unlink(path) catch {};
    return png;
}

/// Decode %XX escapes (file URIs are percent-encoded UTF-8, e.g. the Spanish
/// XDG pictures dir "Imágenes" arrives as "Im%C3%A1genes").
fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(alloc, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(alloc, s[i]);
                continue;
            };
            try out.append(alloc, hi * 16 + lo);
            i += 2;
        } else {
            try out.append(alloc, s[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "percent decode" {
    const alloc = std.testing.allocator;
    const decoded = try percentDecode(alloc, "/home/x/Im%C3%A1genes/a%20b.png");
    defer alloc.free(decoded);
    try std.testing.expectEqualStrings("/home/x/Imágenes/a b.png", decoded);
}

/// Move this process into its own `app-cliptux-<pid>.scope` transient systemd
/// scope (same mechanism as `systemd-run --user --scope`). xdg-desktop-portal
/// derives the caller's app id from the unit name, so this makes us "cliptux"
/// regardless of which terminal/launcher started the process. GNOME requires
/// that id to match the focused window's app_id before showing its consent
/// dialog, and keys the stored permission on it.
pub fn ensureAppScope(alloc: std.mem.Allocator, conn: *dbus.Connection) void {
    ensureAppScopeInner(alloc, conn) catch |err| {
        std.log.warn("could not move into app-cliptux scope: {t}", .{err});
    };
}

fn ensureAppScopeInner(alloc: std.mem.Allocator, conn: *dbus.Connection) !void {
    {
        const cg = try sys.readFileAlloc(alloc, "/proc/self/cgroup", 4096);
        defer alloc.free(cg);
        if (std.mem.indexOf(u8, cg, "app-cliptux") != null) return; // already there
    }
    const pid: u32 = @intCast(std.os.linux.getpid());
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "app-cliptux-{d}.scope", .{pid});

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(name);
    try m.putString("fail"); // mode
    const props = try m.beginArray(8); // a(sv)
    {
        try m.beginStruct();
        try m.putString("PIDs");
        try m.putSignature("au");
        const pids = try m.beginArray(4);
        try m.putU32(pid);
        m.endArray(pids);

        try m.beginStruct();
        try m.putString("Slice");
        try m.putVariantString("app.slice");
    }
    m.endArray(props);
    const aux = try m.beginArray(8); // a(sa(sv))
    m.endArray(aux);

    const serial = try conn.callMethod(
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
        m.buf.items,
    );
    var reply = try conn.waitReply(serial);
    reply.deinit(alloc);

    // the cgroup move is asynchronous; wait for it to land
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        const cg = try sys.readFileAlloc(alloc, "/proc/self/cgroup", 4096);
        defer alloc.free(cg);
        if (std.mem.indexOf(u8, cg, "app-cliptux") != null) return;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    return error.ScopeMoveTimedOut;
}

/// Fire-and-forget desktop notification.
pub fn notify(alloc: std.mem.Allocator, conn: *dbus.Connection, summary: []const u8, text: []const u8) void {
    notifyInner(alloc, conn, summary, text) catch |err| {
        std.log.warn("notification failed: {t}", .{err});
    };
}

fn notifyInner(alloc: std.mem.Allocator, conn: *dbus.Connection, summary: []const u8, text: []const u8) !void {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString("cliptux"); // app_name
    try m.putU32(0); // replaces_id
    try m.putString("camera-photo"); // icon
    try m.putString(summary);
    try m.putString(text);
    const actions = try m.beginArray(4);
    m.endArray(actions);
    const hints = try m.beginArray(8);
    m.endArray(hints);
    try m.putI32(4000); // timeout ms

    const serial = try conn.callMethod(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        "susssasa{sv}i",
        m.buf.items,
    );
    var reply = try conn.waitReply(serial);
    reply.deinit(alloc);
}

// --- ScreenCast portal: persistent session + PipeWire stream handle ---

pub const ScreenCastSession = struct {
    session_path: []u8,
    node_id: u32,
    pw_fd: sys.fd_t,
    /// new restore token to persist for silent future sessions (owned)
    restore_token: ?[]u8,

    pub fn deinit(self: *ScreenCastSession, alloc: std.mem.Allocator) void {
        alloc.free(self.session_path);
        if (self.restore_token) |t| alloc.free(t);
        // pw_fd ownership is transferred to the PipeWire client; not closed here
        self.* = undefined;
    }
};

fn makeToken(buf: []u8, prefix: []const u8) ![]u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return std.fmt.bufPrint(buf, "{s}{d}_{d}", .{ prefix, std.os.linux.getpid(), @as(u64, @intCast(ts.nsec)) });
}

fn senderPath(conn: *const dbus.Connection, buf: []u8, kind: []const u8, token: []const u8) ![]u8 {
    var sender_buf: [64]u8 = undefined;
    var n: usize = 0;
    for (conn.unique_name) |c| {
        if (c == ':') continue;
        sender_buf[n] = if (c == '.') '_' else c;
        n += 1;
    }
    return std.fmt.bufPrint(buf, "/org/freedesktop/portal/desktop/{s}/{s}/{s}", .{ kind, sender_buf[0..n], token });
}

/// Call a portal request-style method and wait for its Response signal.
/// Returns the Response message (caller owns and parses the body).
fn callPortalRequest(
    alloc: std.mem.Allocator,
    conn: *dbus.Connection,
    iface: []const u8,
    member: []const u8,
    signature: []const u8,
    body: []const u8,
    handle_token: []const u8,
) !dbus.Message {
    var path_buf: [256]u8 = undefined;
    var request_path: []u8 = try alloc.dupe(u8, try senderPath(conn, &path_buf, "request", handle_token));
    defer alloc.free(request_path);

    const serial = try conn.callMethod(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        iface,
        member,
        signature,
        body,
    );

    var got_reply = false;
    while (true) {
        var msg = try conn.nextMessage();
        var keep = false;
        defer if (!keep) msg.deinit(alloc);

        if (!got_reply and msg.reply_serial == serial) {
            if (msg.type == .@"error") {
                std.log.warn("portal {s} error: {s}", .{ member, msg.error_name orelse "?" });
                return error.PortalError;
            }
            var r = msg.reader();
            const handle = try r.readString();
            if (!std.mem.eql(u8, handle, request_path)) {
                alloc.free(request_path);
                request_path = try alloc.dupe(u8, handle);
            }
            got_reply = true;
            continue;
        }
        if (msg.isSignal("org.freedesktop.portal.Request", "Response")) {
            if (msg.path != null and std.mem.eql(u8, msg.path.?, request_path)) {
                keep = true;
                return msg;
            }
        }
    }
}

/// Stage 1: create a ScreenCast session. Returns the session path (owned).
pub fn scCreateSession(alloc: std.mem.Allocator, conn: *dbus.Connection) ![]u8 {
    try conn.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response'");
    var tok_buf: [64]u8 = undefined;
    var stok_buf: [64]u8 = undefined;
    const tok = try makeToken(&tok_buf, "cliptux_r");
    const stok = try makeToken(&stok_buf, "cliptux_s");

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

    var resp = try callPortalRequest(alloc, conn, "org.freedesktop.portal.ScreenCast", "CreateSession", "a{sv}", m.buf.items, tok);
    defer resp.deinit(alloc);
    var r = resp.reader();
    if (try r.readU32() != 0) return error.ScreenCastDenied;
    var it = try r.readDictSV();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.key, "session_handle")) {
            switch (entry.value) {
                .string, .object_path => |s| return try alloc.dupe(u8, s),
                else => {},
            }
        }
    }
    return error.NoSessionHandle;
}

/// Stage 2 (can run before Start on GNOME): get the PipeWire socket fd.
pub fn scOpenRemote(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8) !sys.fd_t {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    const arr = try m.beginArray(8);
    m.endArray(arr);
    const serial = try conn.callMethod(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        "OpenPipeWireRemote",
        "oa{sv}",
        m.buf.items,
    );
    var reply = try conn.waitReply(serial);
    defer reply.deinit(alloc);
    return reply.takeFd() orelse error.NoPipeWireFd;
}

pub const ScStart = struct {
    node_id: u32,
    restore_token: ?[]u8,
};

/// Stage 3: select the monitor source and start the cast.
pub fn scSelectAndStart(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8, prev_token: ?[]const u8) !ScStart {
    const iface = "org.freedesktop.portal.ScreenCast";
    var tok_buf: [64]u8 = undefined;

    {
        const tok = try makeToken(&tok_buf, "cliptux_r");
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
        try m.putVariantBool(false);
        try m.beginStruct();
        try m.putString("cursor_mode");
        try m.putVariantU32(1); // HIDDEN
        try m.beginStruct();
        try m.putString("persist_mode");
        try m.putVariantU32(2);
        if (prev_token) |t| {
            try m.beginStruct();
            try m.putString("restore_token");
            try m.putVariantString(t);
        }
        m.endArray(arr);

        var resp = try callPortalRequest(alloc, conn, iface, "SelectSources", "oa{sv}", m.buf.items, tok);
        defer resp.deinit(alloc);
        var r = resp.reader();
        if (try r.readU32() != 0) return error.ScreenCastDenied;
    }

    var node_id: u32 = 0;
    var new_token: ?[]u8 = null;
    errdefer if (new_token) |t| alloc.free(t);
    {
        const tok = try makeToken(&tok_buf, "cliptux_r");
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putObjectPath(session_path);
        try m.putString(""); // parent window
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("handle_token");
        try m.putVariantString(tok);
        m.endArray(arr);

        var resp = try callPortalRequest(alloc, conn, iface, "Start", "osa{sv}", m.buf.items, tok);
        defer resp.deinit(alloc);
        var r = resp.reader();
        if (try r.readU32() != 0) return error.ScreenCastDenied;

        const dict_len = try r.readU32();
        r.pad(8);
        const dict_end = r.pos + dict_len;
        while (r.pos < dict_end) {
            r.pad(8);
            if (r.pos >= dict_end) break;
            const key = try r.readString();
            const sig = try r.readSignature();
            if (std.mem.eql(u8, key, "streams")) {
                const arr_len = try r.readU32();
                const arr_start = blk: {
                    r.pad(8);
                    break :blk r.pos;
                };
                if (arr_len >= 4) node_id = try r.readU32();
                r.pos = arr_start + arr_len;
            } else if (std.mem.eql(u8, key, "restore_token")) {
                new_token = try alloc.dupe(u8, try r.readString());
            } else {
                var idx: usize = 0;
                try r.skipType(sig, &idx);
            }
        }
        if (node_id == 0) return error.NoStream;
    }
    return .{ .node_id = node_id, .restore_token = new_token };
}

/// Open a ScreenCast session for monitor capture. With a valid restore
/// token this is fully silent; otherwise GNOME shows its source picker once
/// (check "remember" semantics are handled by persist_mode=2).
pub fn openScreenCast(alloc: std.mem.Allocator, conn: *dbus.Connection, prev_token: ?[]const u8) !ScreenCastSession {
    const session_path = try scCreateSession(alloc, conn);
    errdefer alloc.free(session_path);
    const started = try scSelectAndStart(alloc, conn, session_path, prev_token);
    const pw_fd = try scOpenRemote(alloc, conn, session_path);
    return .{
        .session_path = session_path,
        .node_id = started.node_id,
        .pw_fd = pw_fd,
        .restore_token = started.restore_token,
    };
}

/// Close a portal session (stops GNOME's screen-sharing indicator).
/// Fire-and-forget: the call is flushed but the reply is not awaited (it is
/// queued and freed with the connection if it ever arrives).
pub fn closeSession(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8) void {
    _ = alloc;
    _ = conn.callMethod(
        "org.freedesktop.portal.Desktop",
        session_path,
        "org.freedesktop.portal.Session",
        "Close",
        "",
        &.{},
    ) catch return;
}
