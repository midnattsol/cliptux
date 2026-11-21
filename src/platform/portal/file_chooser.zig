//! org.freedesktop.portal.FileChooser: a path to save a PNG to, and a
//! folder to save screenshots in.

const std = @import("std");
const dbus = @import("../dbus.zig");
const request = @import("request.zig");
const screenshot = @import("screenshot.zig");

const Request = request.Request;
const Result = request.Result;

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
    const token = try request.makeToken(&tok_buf, "shotlet_f");

    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(""); // parent_window
    try m.putString(opts.title);
    const arr = try m.beginArray(8);
    try putSaveFileOptions(&m, token, opts);
    m.endArray(arr);

    var req = try request.call(alloc, conn, "org.freedesktop.portal.FileChooser", "SaveFile", "ssa{sv}", m.buf.items, token, request.timeout_file_chooser_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return request.notGranted([]u8, req.outcome.?);
    return .{ .granted = try chosenPath(alloc, &req) };
}

/// The a{sv} entries of a SaveFile call: modal, the suggested name and
/// folder, and a PNG filter (offered and preselected).
fn putSaveFileOptions(m: *dbus.Marshal, token: []const u8, opts: SaveFileOptions) !void {
    try m.beginStruct();
    try m.putString("handle_token");
    try m.putVariantString(token);

    try m.beginStruct();
    try m.putString("modal");
    try m.putVariantBool(true);

    try m.beginStruct();
    try m.putString("current_name");
    try m.putVariantString(opts.current_name);

    if (opts.current_folder) |dir| try putCurrentFolder(m, dir);

    try m.beginStruct();
    try m.putString("filters");
    try m.putSignature("a(sa(us))");
    const filters = try m.beginArray(8);
    try putPngFilter(m);
    m.endArray(filters);

    try m.beginStruct();
    try m.putString("current_filter");
    try m.putSignature("(sa(us))");
    try putPngFilter(m);
}

pub const FolderOptions = struct {
    title: []const u8 = "Save Screenshots To",
    current_folder: ?[]const u8 = null,
};

/// Start asking for a folder (FileChooser OpenFile with directory=true)
/// without blocking: feed bus messages to the Request's handle() while
/// the window stays responsive, then read the answer with chosenPath().
pub fn beginChooseFolder(alloc: std.mem.Allocator, conn: *dbus.Connection, opts: FolderOptions) !Request {
    var tok_buf: [64]u8 = undefined;
    const token = try request.makeToken(&tok_buf, "shotlet_d");
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
        try m.putString("directory");
        try m.putVariantBool(true);

        try m.beginStruct();
        try m.putString("accept_label");
        try m.putVariantString("Select");

        if (opts.current_folder) |dir| try putCurrentFolder(&m, dir);
    }
    m.endArray(arr);
    return Request.start(alloc, conn, "org.freedesktop.portal.FileChooser", "OpenFile", "ssa{sv}", m.buf.items, token);
}

/// The local path a granted FileChooser request chose (owned).
pub fn chosenPath(alloc: std.mem.Allocator, req: *const Request) ![]u8 {
    const uri = try firstUri(req);
    if (!std.mem.startsWith(u8, uri, "file://")) return error.BadUri;
    return screenshot.percentDecode(alloc, uri["file://".len..]);
}

/// beginChooseFolder + wait: blocks until the dialog is answered.
pub fn chooseFolder(alloc: std.mem.Allocator, conn: *dbus.Connection, opts: FolderOptions) !Result([]u8) {
    var req = try beginChooseFolder(alloc, conn, opts);
    defer req.deinit(alloc);
    try req.wait(alloc, conn, request.timeout_file_chooser_ms);
    if (req.outcome.? != .granted) return request.notGranted([]u8, req.outcome.?);
    return .{ .granted = try chosenPath(alloc, &req) };
}

/// The current_folder option: bytes with a terminating NUL, not a string.
fn putCurrentFolder(m: *dbus.Marshal, dir: []const u8) !void {
    try m.beginStruct();
    try m.putString("current_folder");
    try m.putSignature("ay");
    const bytes = try m.beginArray(1);
    try m.buf.appendSlice(m.alloc, dir);
    try m.putByte(0);
    m.endArray(bytes);
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
