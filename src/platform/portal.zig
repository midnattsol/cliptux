//! xdg-desktop-portal clients: Screenshot, ScreenCast, FileChooser, plus
//! desktop notifications.
//!
//! Portal requests answer with a Response signal that may take as long as a
//! person looking at a dialog. Every wait here has a deadline, watches the
//! portal's bus name so a crashed portal fails fast, and reports an
//! explicit Outcome instead of folding everything into one error.

const std = @import("std");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");

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

fn notGranted(comptime T: type, o: Outcome) Result(T) {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}

/// A dialog may be on screen: give the person time to read and click.
pub const timeout_dialog_ms: i64 = 60_000;
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
            if (msg.type == .@"error") {
                const name = msg.error_name orelse "?";
                std.log.warn("portal {s} failed: {s}", .{ self.what, name });
                self.outcome = if (isDenialError(name)) .denied else .unavailable;
                return false;
            }
            var r = msg.reader();
            const handle_path = r.readString() catch {
                self.outcome = .unavailable;
                return false;
            };
            // portals older than 0.9 do not use the predicted path
            if (!std.mem.eql(u8, handle_path, self.path)) {
                const copy = try alloc.dupe(u8, handle_path);
                alloc.free(self.path);
                self.path = copy;
            }
            self.got_reply = true;
            return false;
        }
        if (msg.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) {
            var r = msg.reader();
            const name = r.readString() catch return false;
            if (!std.mem.eql(u8, name, bus_name)) return false;
            _ = r.readString() catch return false; // old owner
            const new_owner = r.readString() catch return false;
            if (new_owner.len == 0) {
                std.log.warn("the desktop portal exited during {s}", .{self.what});
                self.outcome = .unavailable;
            }
            return false;
        }
        if (msg.isSignal("org.freedesktop.portal.Request", "Response")) {
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
            if (code == 0) {
                self.response = msg.*;
                return true;
            }
        }
        return false;
    }

    /// Pump the connection until the request finishes or `timeout_ms`
    /// passes. Unrelated messages are dropped.
    pub fn wait(self: *Request, alloc: std.mem.Allocator, conn: *dbus.Connection, timeout_ms: i64) !void {
        const deadline = sys.monoMs() + timeout_ms;
        while (self.outcome == null) {
            var msg = (conn.nextMessageDeadline(deadline) catch |err| {
                if (dbus.isFatal(err)) return err;
                std.log.warn("dropped malformed bus message: {t}", .{err});
                continue;
            }) orelse {
                std.log.warn("portal {s}: no answer after {d} s; giving up", .{ self.what, @divTrunc(timeout_ms, 1000) });
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

// --- Screenshot ---

/// Take a full-screen screenshot via org.freedesktop.portal.Screenshot.
/// When granted, returns the PNG file contents and removes the temporary
/// file from disk.
pub fn screenshot(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool) !Result([]u8) {
    var req = try beginScreenshot(alloc, conn, interactive);
    defer req.deinit(alloc);
    // non-interactive still may show GNOME's one-time permission dialog
    try req.wait(alloc, conn, timeout_dialog_ms);
    if (req.outcome.? != .granted) return notGranted([]u8, req.outcome.?);
    const uri = try screenshotUri(&req);
    return .{ .granted = try readAndUnlink(alloc, uri) };
}

/// Start a Screenshot request; pump messages into the returned Request.
pub fn beginScreenshot(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool) !Request {
    var tok_buf: [64]u8 = undefined;
    const token = try makeToken(&tok_buf, "shotlet_");

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
    return Request.start(alloc, conn, "org.freedesktop.portal.Screenshot", "Screenshot", "sa{sv}", m.buf.items, token);
}

/// The "uri" result of a granted Screenshot request (borrowed).
pub fn screenshotUri(req: *const Request) ![]const u8 {
    var r = try req.results();
    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.key, "uri") and std.mem.eql(u8, e.sig, "s")) return r.readString();
        try r.skipValue(e.sig);
    }
    return error.NoUri;
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

/// Move this process into its own `app-shotlet-<pid>.scope` transient systemd
/// scope (same mechanism as `systemd-run --user --scope`). xdg-desktop-portal
/// derives the caller's app id from the unit name, so this makes us "shotlet"
/// regardless of which terminal/launcher started the process. GNOME requires
/// that id to match the focused window's app_id before showing its consent
/// dialog, and keys the stored permission on it.
pub fn ensureAppScope(alloc: std.mem.Allocator, conn: *dbus.Connection) void {
    ensureAppScopeInner(alloc, conn) catch |err| {
        std.log.warn("could not move into app-shotlet scope: {t}", .{err});
    };
}

fn ensureAppScopeInner(alloc: std.mem.Allocator, conn: *dbus.Connection) !void {
    {
        const cg = try sys.readFileAlloc(alloc, "/proc/self/cgroup", 4096);
        defer alloc.free(cg);
        if (std.mem.indexOf(u8, cg, "app-shotlet") != null) return; // already there
    }

    const systemd_name = "org.freedesktop.systemd1";
    const has_systemd = conn.nameHasOwner(systemd_name) catch |err| {
        std.log.debug("skipping app scope: could not query {s}: {t}", .{ systemd_name, err });
        return;
    };
    if (!has_systemd) {
        // dbus-daemon may list systemd1 as activatable even when activating it
        // only spawns a child that exits. Do not pay that cost on every shot.
        std.log.debug("skipping app scope: {s} has no bus owner", .{systemd_name});
        return;
    }
    const pid: u32 = @intCast(std.os.linux.getpid());
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "app-shotlet-{d}.scope", .{pid});

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
        if (std.mem.indexOf(u8, cg, "app-shotlet") != null) return;
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
    try m.putString("Shotlet"); // app_name
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

// --- FileChooser ---

pub const SaveFileOptions = struct {
    title: []const u8 = "Save Screenshot",
    current_name: []const u8,
    current_folder: ?[]const u8 = null,
};

/// Ask for a path to save a PNG to (org.freedesktop.portal.FileChooser
/// SaveFile). Returns the chosen local path (owned) when granted. The
/// dialog already asked about overwriting an existing file.
pub fn saveFile(alloc: std.mem.Allocator, conn: *dbus.Connection, opts: SaveFileOptions) !Result([]u8) {
    var tok_buf: [64]u8 = undefined;
    const token = try makeToken(&tok_buf, "shotlet_f");

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(""); // parent_window
    try m.putString(opts.title);
    const arr = try m.beginArray(8);
    {
        try m.beginStruct();
        try m.putString("handle_token");
        try m.putVariantString(token);

        try m.beginStruct();
        try m.putString("modal");
        try m.putVariantBool(true);

        try m.beginStruct();
        try m.putString("current_name");
        try m.putVariantString(opts.current_name);

        if (opts.current_folder) |dir| {
            // bytes with a terminating NUL, not a string
            try m.beginStruct();
            try m.putString("current_folder");
            try m.putSignature("ay");
            const bytes = try m.beginArray(1);
            try m.buf.appendSlice(m.alloc, dir);
            try m.putByte(0);
            m.endArray(bytes);
        }

        try m.beginStruct();
        try m.putString("filters");
        try m.putSignature("a(sa(us))");
        const filters = try m.beginArray(8);
        try putPngFilter(&m);
        m.endArray(filters);

        try m.beginStruct();
        try m.putString("current_filter");
        try m.putSignature("(sa(us))");
        try putPngFilter(&m);
    }
    m.endArray(arr);

    var req = try call(alloc, conn, "org.freedesktop.portal.FileChooser", "SaveFile", "ssa{sv}", m.buf.items, token, timeout_file_chooser_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return notGranted([]u8, req.outcome.?);
    const uri = try firstUri(&req);
    if (!std.mem.startsWith(u8, uri, "file://")) return error.BadUri;
    return .{ .granted = try percentDecode(alloc, uri["file://".len..]) };
}

fn putPngFilter(m: *dbus.Marshal) !void {
    try m.beginStruct();
    try m.putString("PNG image");
    const pats = try m.beginArray(8);
    try m.beginStruct();
    try m.putU32(0); // glob
    try m.putString("*.png");
    try m.beginStruct();
    try m.putU32(1); // MIME type
    try m.putString("image/png");
    m.endArray(pats);
}

fn firstUri(req: *const Request) ![]const u8 {
    var r = try req.results();
    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.key, "uris") and std.mem.eql(u8, e.sig, "as")) {
            const len = try r.readU32();
            if (len == 0) return error.NoUri;
            return r.readString();
        }
        try r.skipValue(e.sig);
    }
    return error.NoUri;
}

// --- ScreenCast portal: one-shot session + PipeWire stream handles ---

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

/// A handle token: unique per request, only [A-Za-z0-9_] as the spec asks.
fn makeToken(buf: []u8, prefix: []const u8) ![]u8 {
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

/// Stage 1: create a ScreenCast session. Returns the session path (owned).
pub fn scCreateSession(alloc: std.mem.Allocator, conn: *dbus.Connection) !Result([]u8) {
    var tok_buf: [64]u8 = undefined;
    var stok_buf: [64]u8 = undefined;
    const tok = try makeToken(&tok_buf, "shotlet_r");
    const stok = try makeToken(&stok_buf, "shotlet_s");

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

    var req = try call(alloc, conn, "org.freedesktop.portal.ScreenCast", "CreateSession", "a{sv}", m.buf.items, tok, timeout_quick_ms);
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
    const serial = try conn.callMethod(bus_name, object_path, "org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote", "oa{sv}", m.buf.items);
    var reply = try conn.waitReplyTimeout(serial, timeout_quick_ms);
    defer reply.deinit(alloc);
    return reply.takeFd() orelse error.NoPipeWireFd;
}

/// Stage 3: select monitor sources (all of them, so the whole desktop is
/// one capture) and start the cast. GNOME shows its picker here unless the
/// restore token still matches.
pub fn scSelectAndStart(alloc: std.mem.Allocator, conn: *dbus.Connection, session_path: []const u8, prev_token: ?[]const u8) !Result(ScStart) {
    const iface = "org.freedesktop.portal.ScreenCast";
    var tok_buf: [64]u8 = undefined;

    {
        const tok = try makeToken(&tok_buf, "shotlet_r");
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

        var req = try call(alloc, conn, iface, "SelectSources", "oa{sv}", m.buf.items, tok, timeout_dialog_ms);
        defer req.deinit(alloc);
        if (req.outcome.? != .granted) return notGranted(ScStart, req.outcome.?);
    }

    const tok = try makeToken(&tok_buf, "shotlet_r");
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    try m.putString(""); // parent window
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(tok);
    m.endArray(arr);

    var req = try call(alloc, conn, iface, "Start", "osa{sv}", m.buf.items, tok, timeout_dialog_ms);
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
            const len = try r.readU32();
            r.pad(8);
            if (r.pos > r.data.len or len > r.data.len - r.pos) return error.ShortRead;
            const end = r.pos + len;
            while (r.pos < end) {
                r.pad(8);
                if (r.pos >= end) break;
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
                if (st.node_id != 0) try streams.append(alloc, st);
            }
            if (r.pos != end) return error.BadArrayLength;
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
    _ = conn.callMethod(bus_name, session_path, "org.freedesktop.portal.Session", "Close", "", &.{}) catch return;
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

/// Body of a Start Response: code, then {streams, restore_token}.
fn startResponseBody(m: *dbus.Marshal, code: u32, token_sig: []const u8) !void {
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
        try startResponseBody(&m, c.code, "s");

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
            var st = try parseStartResults(alloc, &r);
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
