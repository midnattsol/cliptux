//! Images in and out of the floating windows: `shotlet pin` with no file
//! pins the clipboard's image, and an image dropped on the thumbnail or
//! the history panel opens in the editor (`shotlet edit FILE`).
//!
//! Wayland hands the clipboard only to a focused client, so reading it
//! takes a tiny see-through window for a moment, as wl-paste does.

const std = @import("std");
const env_mod = @import("env.zig");
const keep = @import("keep.zig");
const sys = @import("../platform/api.zig").sys;
const window = @import("../platform/api.zig").window;
const imgload = @import("../gfx/imgload.zig");
const pin = @import("pin.zig");
const Env = env_mod.Env;

const image_mimes = [_][]const u8{"image/png"};

/// What a drop target takes: a file (from a file manager) or the image.
pub const drop_mimes = [_][]const u8{ "text/uri-list", "image/png" };

/// The clipboard's image/png (owned); error.NoImageOnClipboard when it
/// holds something else or nothing.
pub fn readPng(gpa: std.mem.Allocator, env: Env) ![]u8 {
    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    win.accept_mimes = &image_mimes;
    try win.open("shotlet:clipboard", .{ .fullscreen = false, .transparent = true, .width = 1, .height = 1 });
    const px = try win.backBuffer();
    @memset(px, 0);
    try win.present();
    // the selection comes with the keyboard focus; give it a moment more
    const deadline = sys.monoMs() + 3000;
    var focused_at: i64 = 0;
    while (sys.monoMs() < deadline) {
        _ = try win.nextEventTimeout(50);
        if (win.kb_focus and focused_at == 0) focused_at = sys.monoMs();
        if (focused_at != 0 and sys.monoMs() - focused_at > 150) break;
    }
    if (focused_at == 0) return error.NoClipboardAccess;
    const d = (try win.clipboardAccepted(gpa, imgload.max_file, 5000)) orelse return error.NoImageOnClipboard;
    win.closeWindow();
    return d.data;
}

/// `shotlet pin` without a file.
pub fn pinClipboard(gpa: std.mem.Allocator, env: Env) !void {
    const data = readPng(gpa, env) catch |err| {
        std.log.err("pin: no image on the clipboard ({t})", .{err});
        return err;
    };
    var img = blk: {
        defer gpa.free(data);
        break :blk try imgload.decode(gpa, data);
    };
    defer img.deinit(gpa);
    try pin.show(gpa, env, &img, "the clipboard", null);
}

/// A drop on `win` (whose accept_mimes are drop_mimes) opens the image in
/// a new editor; drags of our own are not drops.
pub fn takeDrop(gpa: std.mem.Allocator, env: Env, win: *window.Window) void {
    const d = win.dropped orelse return;
    win.dropped = null;
    defer gpa.free(d.data);
    if (win.drag_state != .none) return;
    var buf: [1024]u8 = undefined;
    const path = if (std.mem.eql(u8, d.mime, "text/uri-list"))
        imgload.firstFileUri(buf[0 .. buf.len - 1], d.data) orelse return
    else
        savedDrop(gpa, env, d.data, &buf) catch |err| {
            std.log.warn("drop: cannot keep the image: {t}", .{err});
            return;
        };
    buf[path.len] = 0;
    std.log.info("drop: opening {s}", .{path});
    keep.spawnSelf(env, &.{ "edit", buf[0..path.len :0].ptr });
}

/// A dropped image kept as a file in the cache, for `shotlet edit`.
fn savedDrop(gpa: std.mem.Allocator, env: Env, data: []const u8, buf: []u8) ![]const u8 {
    _ = gpa;
    if (imgload.sniff(data) == .unknown) return error.UnknownImageFormat;
    var dir_buf: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&dir_buf, env.home);
    var drop_dir: [1100]u8 = undefined;
    const dir = try std.fmt.bufPrint(&drop_dir, "{s}/drop", .{cache});
    sys.mkdirAll(dir, 0o700);
    const path = try std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}/dropped-{d}.png", .{ dir, sys.realtimeMs() });
    try sys.writeFileExclusive(path, data, 0o600);
    return path;
}
