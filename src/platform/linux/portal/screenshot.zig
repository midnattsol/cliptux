//! org.freedesktop.portal.Screenshot, and reading back the file a portal
//! answered with (a percent-encoded file:// URI).

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const request = @import("request.zig");

const Request = request.Request;
const Result = request.Result;

/// Take a full-screen screenshot via org.freedesktop.portal.Screenshot.
/// When granted, returns the PNG file contents and removes the temporary
/// file from disk. `timeout_ms`: timeout_dialog_ms when a consent dialog
/// may show, shorter when none can.
pub fn screenshot(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool, timeout_ms: i64) !Result([]u8) {
    var req = try beginScreenshot(alloc, conn, interactive);
    defer req.deinit(alloc);
    try req.wait(alloc, conn, timeout_ms);
    if (req.outcome.? != .granted) return request.notGranted([]u8, req.outcome.?);
    const uri = try screenshotUri(&req);
    return .{ .granted = try readAndUnlink(alloc, uri) };
}

/// Start a Screenshot request; pump messages into the returned Request.
pub fn beginScreenshot(alloc: std.mem.Allocator, conn: *dbus.Connection, interactive: bool) !Request {
    var tok_buf: [64]u8 = undefined;
    const token = try request.makeToken(&tok_buf, "shotlet_");

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

/// Read the file a file:// URI names (PNG-sized limit), then delete it.
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
pub fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
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
