//! Annotate: the pin opens its picture in the editor (`shotlet edit FILE
//! --pin-fd N`) and steps aside, invisible and letting clicks through,
//! where it is. Whatever the editor then copies, saves or pins comes back
//! through the pipe N and replaces the picture in place; a Cancel (or an
//! editor that went away) leaves it as it was. Either way the pin shows
//! again once the pipe closes. The editor's side is ui/tools/launch.zig's
//! backToPin.

const std = @import("std");
const png = @import("../../gfx/png.zig");
const env_mod = @import("../env.zig");
const keep = @import("../keep.zig");
const sys = @import("../../platform/api.zig").sys;
const state = @import("state.zig");

const Pin = state.Pin;
/// the largest picture the editor may hand back
const max_png = 512 * 1024 * 1024;

/// The editor at work on the pin's picture.
pub const Editing = struct {
    /// the pipe's read end
    fd: sys.fd_t,
    /// the picture as the editor opened it
    path_buf: [1200]u8 = undefined,
    path_len: usize = 0,
    got: std.ArrayList(u8) = .empty,

    pub fn deinit(e: *Editing, gpa: std.mem.Allocator) void {
        sys.close(e.fd);
        sys.unlink(e.path_buf[0..e.path_len]) catch {};
        e.got.deinit(gpa);
    }
};

pub fn start(p: *Pin) !void {
    if (p.edit != null) return;
    var e: Editing = .{ .fd = -1 };
    const path = try writePicture(p, &e.path_buf);
    e.path_len = path.len;
    errdefer sys.unlink(path) catch {};
    const fds = try sys.pipe();
    e.fd = fds[0];
    var fd_buf: [16]u8 = undefined;
    const fd_arg = try std.fmt.bufPrintSentinel(&fd_buf, "{d}", .{fds[1]}, 0);
    keep.spawnKeeping(p.env, &.{ "edit", path.ptr, "--pin-fd", fd_arg.ptr }, fds[1]);
    sys.close(fds[1]);
    p.edit = e;
    p.hover = .none;
    p.drag_from = null;
    p.dirty = true;
    std.log.info("pin: annotating in the editor", .{});
}

/// The picture as a PNG in the cache, for the editor to open.
fn writePicture(p: *Pin, buf: []u8) ![:0]const u8 {
    const data = try png.encodeWith(p.gpa, p.img.pixels, p.img.width, p.img.height, .{ .alpha = .auto });
    defer p.gpa.free(data);
    var dir_buf: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&dir_buf, p.env.home);
    const dir = try std.fmt.bufPrint(buf, "{s}/pin", .{cache});
    sys.mkdirAll(dir, 0o700);
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/pin/annotate-{d}-{d}.png", .{ cache, sys.processId(), sys.realtimeMs() }, 0);
    try sys.writeFileExclusive(path, data, 0o600);
    return path;
}

/// Reads what the editor sent; once the pipe closes, the pin is back.
pub fn pump(p: *Pin) void {
    const e = if (p.edit) |*v| v else return;
    var buf: [65536]u8 = undefined;
    const n = sys.read(e.fd, &buf) catch 0;
    if (n > 0 and e.got.items.len + n <= max_png) {
        e.got.appendSlice(p.gpa, buf[0..n]) catch |err| std.log.warn("pin: {t}", .{err});
        return;
    }
    if (n > 0) return; // too big: ignored, read to the end
    finish(p);
}

fn finish(p: *Pin) void {
    var e = p.edit.?;
    p.edit = null;
    defer e.deinit(p.gpa);
    p.dirty = true;
    if (e.got.items.len == 0) return std.log.info("pin: back from the editor, unchanged", .{});
    const img = png.decode(p.gpa, e.got.items) catch |err| {
        std.log.warn("pin: the editor's picture does not decode: {t}", .{err});
        return;
    };
    p.img.deinit(p.gpa);
    p.img.* = img;
    // the cached scaled copy is of the old picture
    p.scaled_w = 0;
    p.scaled_h = 0;
    std.log.info("pin: updated from the editor ({d}x{d})", .{ img.width, img.height });
}
