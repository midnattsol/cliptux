//! Images into and out of the editor: an image file (or image) dropped
//! on it replaces the picture, and Pin (Ctrl+P, More menu) pins what
//! Copy would copy and closes the editor.

const std = @import("std");
const doc_mod = @import("../doc.zig");
const editor_mod = @import("../editor.zig");
const png = @import("../../gfx/png.zig");
const imgload = @import("../../gfx/imgload.zig");
const sys = @import("../../platform/sys.zig");
const env_mod = @import("../../app/env.zig");
const keep = @import("../../app/keep.zig");
const launch = @import("launch.zig");

const Editor = editor_mod.Editor;

pub const drop_mimes = [_][]const u8{ "text/uri-list", "image/png" };

/// A finished drop on the editor: open what it brought.
pub fn poll(ed: *Editor) void {
    const d = ed.win.dropped orelse return;
    ed.win.dropped = null;
    defer ed.alloc.free(d.data);
    var buf: [1024]u8 = undefined;
    const is_file = std.mem.eql(u8, d.mime, "text/uri-list");
    const path: []const u8 = if (is_file) (imgload.firstFileUri(&buf, d.data) orelse return) else "the dropped image";
    const img = (if (is_file) imgload.loadFile(ed.alloc, path) else imgload.decode(ed.alloc, d.data)) catch |err| {
        std.log.warn("drop: cannot open {s}: {t}", .{ path, err });
        ed.tools.toast.show(.problem, "Not an image Shotlet can open", 3000);
        ed.needs_render = true;
        return;
    };
    replaceDocument(ed, img) catch |err| {
        std.log.warn("drop: {t}", .{err});
        return;
    };
    std.log.info("drop: opened {s} ({d}x{d})", .{ path, ed.img.width, ed.img.height });
    var msg: [160]u8 = undefined;
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    ed.tools.toast.show(.done, std.fmt.bufPrint(&msg, "Opened {s}", .{base}) catch "Opened", 2400);
}

/// A new document on `img` (taken): the shapes and their history go.
fn replaceDocument(ed: *Editor, img: png.Image) !void {
    try ed.settle();
    ed.tools.mode = .none;
    const p = try ed.tools.crops.adopt(ed.alloc, img);
    ed.doc.deinit();
    ed.doc = doc_mod.Document.init(ed.alloc, p.width, p.height);
    ed.doc.sel = ed.doc.imageRect();
    try ed.replaceImage(p);
}

/// Pin the export to the screen (`shotlet pin`), and close.
pub fn pinExport(ed: *Editor) !void {
    const env = launch.env orelse return error.NoEnvironment;
    const data = try ed.exportPng();
    defer ed.alloc.free(data);
    var dir_buf: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&dir_buf, env.home);
    var path_buf: [1200]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "{s}/pin", .{cache});
    sys.mkdirAll(dir, 0o700);
    var file_buf: [1300]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&file_buf, "{s}/pin-{d}.png", .{ dir, sys.realtimeMs() }, 0);
    try sys.writeFileExclusive(path, data, 0o600);
    std.log.info("pin: pinning the export ({s})", .{path});
    var at_buf: [32]u8 = undefined;
    if (selectionCentre(ed)) |c| {
        // where the capture was, rather than wherever a new window goes
        const at = try std.fmt.bufPrintSentinel(&at_buf, "{d},{d}", .{ c[0], c[1] }, 0);
        keep.spawnSelf(env, &.{ "pin", path.ptr, "--at", at.ptr });
    } else keep.spawnSelf(env, &.{ "pin", path.ptr });
    ed.finish(.cancel);
}

/// The selection's centre in the desktop's logical pixels, when the
/// capture's monitor layout is known.
fn selectionCentre(ed: *const Editor) ?[2]i32 {
    const s = ed.doc.sel orelse return null;
    const cx: i64 = s.x + @divTrunc(s.w, 2);
    const cy: i64 = s.y + @divTrunc(s.h, 2);
    for (ed.monitors) |m| {
        const l = m.logical orelse continue;
        if (cx < m.x or cy < m.y or cx >= m.x + m.w or cy >= m.y + m.h or m.w == 0 or m.h == 0) continue;
        return .{
            @intCast(l.x + @divTrunc((cx - m.x) * l.w, m.w)),
            @intCast(l.y + @divTrunc((cy - m.y) * l.h, m.h)),
        };
    }
    return null;
}
