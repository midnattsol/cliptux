//! A recording's file handed on: to the clipboard (its uri, and the bytes
//! as video/mp4 or image/gif), or copied where the person chooses.

const std = @import("std");
const env_mod = @import("../app/env.zig");
const portal = @import("../platform/linux/portal.zig");
const dbus = @import("../platform/linux/dbus.zig");
const sys = @import("../platform/linux/sys.zig");
const window = @import("../platform/linux/window.zig");
const settings_mod = @import("settings.zig");

/// Larger files go on the clipboard as a file reference only.
const max_clipboard_bytes = 256 * 1024 * 1024;

pub fn mimeOf(path: []const u8) []const u8 {
    return if (std.ascii.endsWithIgnoreCase(path, ".gif")) "image/gif" else "video/mp4";
}

/// Copy: the file as text/uri-list (file managers, chat apps) and, when
/// not too large, its bytes as its own type.
pub fn copyToClipboard(gpa: std.mem.Allocator, win: *window.Window, path: []const u8) !void {
    const uri = try window.fileUriList(gpa, path);
    errdefer gpa.free(uri);
    const size = try sys.fileSize(path);
    const bytes: []u8 = if (size <= max_clipboard_bytes) try sys.readFileAlloc(gpa, path, max_clipboard_bytes) else &.{};
    errdefer gpa.free(bytes);
    if (bytes.len > 0) {
        try win.claimClipboardSource(&.{ "text/uri-list", mimeOf(path) });
    } else {
        try win.claimClipboardSource(&.{"text/uri-list"});
    }
    win.clipboard_text = uri;
    win.clipboard_png = bytes;
}

/// Copy `src` byte for byte to a new path `dst` (never over a file).
pub fn copyFile(gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const in = try sys.openRead(src);
    defer sys.close(in);
    const out = try sys.createExclusive(dst, 0o644);
    defer sys.close(out);
    const buf = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buf);
    while (true) {
        const n = try sys.read(in, buf);
        if (n == 0) break;
        try sys.writeAllBlocking(out, buf[0..n]);
    }
}

/// Ask where (FileChooser portal) and copy the recording there; the new
/// path, or null when cancelled.
pub fn saveAs(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, src: []const u8) !?[]u8 {
    var dir_buf: [1024]u8 = undefined;
    const set = settings_mod.load(gpa, env.home);
    const dir = try settings_mod.outputDir(gpa, &set, env.home, &dir_buf);
    const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse return error.BadPath;
    const name = src[slash + 1 ..];
    const path = switch (try portal.saveFile(gpa, bus, .{ .title = "Save Recording", .current_name = name, .current_folder = dir })) {
        .granted => |p| p,
        .cancelled, .denied, .timeout => return null,
        .unavailable => return error.NoFileChooser,
    };
    errdefer gpa.free(path);
    if (std.mem.eql(u8, path, src)) return path;
    // the chooser asked before replacing a file
    sys.unlink(path) catch {};
    try copyFile(gpa, src, path);
    return path;
}

test "copyFile copies and never overwrites" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-files");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const pa = try std.fmt.bufPrint(&a, "{s}/a.mp4", .{dir});
    const pb = try std.fmt.bufPrint(&b, "{s}/b.mp4", .{dir});
    try sys.writeFile(pa, "video bytes");
    try copyFile(gpa, pa, pb);
    const got = try sys.readFileAlloc(gpa, pb, 64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("video bytes", got);
    try std.testing.expectError(error.PathAlreadyExists, copyFile(gpa, pa, pb));
    try std.testing.expectEqualStrings("image/gif", mimeOf("/x/A.GIF"));
}
