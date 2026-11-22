//! After Copy or Save: keep the capture (history entry, or a cache entry
//! for the floating thumbnail alone) and start the quick-access process.

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const annot = @import("annot.zig");
const png = @import("../gfx/png.zig");
const resample = @import("../gfx/resample.zig");
const sys = @import("../platform/api.zig").sys;
const shapes = @import("../ui/shapes.zig");
const doc_mod = @import("../ui/doc.zig");
const Env = env_mod.Env;

/// Thumbnails fit in this box (twice the 240x150 card, for HiDPI).
pub const thumb_w = 480;
pub const thumb_h = 300;

pub const Kept = struct {
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    id: history.Id,

    pub fn root(self: *const Kept) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

pub const What = struct {
    /// the exported PNG (what was copied or saved)
    image_png: []const u8,
    /// the unannotated capture and the document, to edit it again
    source: ?*const png.Image = null,
    doc: ?*const doc_mod.Document = null,
    beautify: doc_mod.Beautify = .{},
    /// where Save wrote it
    saved: []const u8 = "",
    /// replace this entry (a capture edited again) instead of adding one
    replace: ?Kept = null,
};

/// Where entries go: the history when it is on, else the cache.
pub fn rootFor(cfg: *const config.Config, env: Env, buf: []u8) ![]u8 {
    return if (cfg.history) history.historyRoot(buf, env.home) else history.cacheRoot(buf, env.home);
}

/// Store a capture. Null (logged) when nothing was stored.
pub fn keep(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) ?Kept {
    const k = keepEntry(gpa, env, cfg, what) orelse return null;
    finishEntry(gpa, cfg, &k, what);
    return k;
}

/// The part of keep() a thumbnail needs: the image, its thumbnail, the
/// meta and the annotations. finishEntry() adds the rest.
pub fn keepEntry(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) ?Kept {
    return keepInner(gpa, env, cfg, what) catch |err| {
        std.log.warn("could not keep the capture: {t}", .{err});
        return null;
    };
}

/// The slower rest of an entry keepEntry() stored: the unannotated
/// source to edit it again, then the history's limits.
pub fn finishEntry(gpa: std.mem.Allocator, cfg: *const config.Config, k: *const Kept, what: What) void {
    if (what.source != null and what.doc != null) {
        const src = encodeCrop(gpa, what.source.?, sourceCrop(what.doc.?)) catch |err| {
            std.log.warn("could not keep the capture's source: {t}", .{err});
            return;
        };
        defer gpa.free(src);
        history.replaceFile(k.root(), k.id.slice(), "source.png", src) catch |err|
            std.log.warn("could not keep the capture's source: {t}", .{err});
    }
    if (cfg.history) {
        _ = history.prune(gpa, k.root(), cfg.history_max, @as(u64, cfg.history_max_mb) * 1024 * 1024) catch 0;
    }
}

fn keepInner(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) !?Kept {
    if (!cfg.history and !cfg.thumbnails()) return null;
    var k: Kept = .{ .id = undefined };
    if (what.replace) |r| {
        k = r;
    } else {
        k.root_len = (try rootFor(cfg, env, &k.root_buf)).len;
    }
    var img = try png.decode(gpa, what.image_png);
    defer img.deinit(gpa);
    const thumb_px = try thumbnail(gpa, img.pixels, img.width, img.height, thumb_w, thumb_h);
    defer gpa.free(thumb_px.pixels);
    const thumb_png = try png.encodeWith(gpa, thumb_px.pixels, thumb_px.width, thumb_px.height, .{ .alpha = .auto });
    defer gpa.free(thumb_png);
    const doc_text: ?[]u8 = if (what.source != null and what.doc != null)
        try docRelativeTo(gpa, what.doc.?, sourceCrop(what.doc.?), what.beautify)
    else
        null;
    defer if (doc_text) |d| gpa.free(d);

    const meta: history.Meta = .{ .time_ms = sys.realtimeMs(), .width = img.width, .height = img.height, .saved = what.saved };
    if (what.replace != null) {
        const id = k.id.slice();
        try history.replaceFile(k.root(), id, "image.png", what.image_png);
        try history.replaceFile(k.root(), id, "thumb.png", thumb_png);
        if (doc_text) |d| try history.replaceFile(k.root(), id, "doc", d);
        try history.writeMeta(gpa, k.root(), id, &meta);
    } else {
        k.id = try history.create(gpa, k.root(), .{ .meta = meta, .image_png = what.image_png, .thumb_png = thumb_png, .doc = doc_text });
    }
    return k;
}

/// `crop` of `src` as a PNG.
fn encodeCrop(gpa: std.mem.Allocator, src: *const png.Image, crop: shapes.Rect) ![]u8 {
    const cw: u32 = @intCast(crop.w);
    const ch: u32 = @intCast(crop.h);
    const px = try gpa.alloc(u32, @as(usize, cw) * ch);
    defer gpa.free(px);
    for (0..ch) |y| {
        const off = (@as(usize, @intCast(crop.y)) + y) * src.width + @as(usize, @intCast(crop.x));
        @memcpy(px[y * cw ..][0..cw], src.pixels[off..][0..cw]);
    }
    return png.encode(gpa, px, cw, ch);
}

/// The document as annot text, shapes relative to the cropped source.
fn docRelativeTo(gpa: std.mem.Allocator, d: *const doc_mod.Document, crop: shapes.Rect, beautify: doc_mod.Beautify) ![]u8 {
    var moved: std.ArrayList(shapes.Shape) = .empty;
    defer {
        for (moved.items) |*s| s.deinit(gpa);
        moved.deinit(gpa);
    }
    for (d.shapes.items) |*s| {
        var c = try s.clone(gpa);
        c.translate(-crop.x, -crop.y);
        moved.append(gpa, c) catch |err| {
            c.deinit(gpa);
            return err;
        };
    }
    var sel = d.exportRect();
    sel.x -= crop.x;
    sel.y -= crop.y;
    return annot.write(gpa, sel, beautify, moved.items);
}

/// The part of the capture kept for editing again: the selection plus
/// what blur and pixelate read around it.
pub fn sourceCrop(d: *const doc_mod.Document) shapes.Rect {
    var margin: i32 = 0;
    for (d.shapes.items) |*s| margin = @max(margin, s.readMargin());
    const sel = d.exportRect();
    return shapes.Rect.intersect(sel.expand(@min(margin, 256)), d.imageRect()) orelse d.imageRect();
}

pub const Pixels = struct { pixels: []u32, width: u32, height: u32 };

/// Scale down to fit max_w x max_h (never up), area-filtered.
pub fn thumbnail(alloc: std.mem.Allocator, src: []const u32, sw: u32, sh: u32, max_w: u32, max_h: u32) !Pixels {
    const fx = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(@max(1, sw)));
    const fy = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(@max(1, sh)));
    const f = @min(1.0, @min(fx, fy));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sw)) * f))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sh)) * f))));
    const out = try alloc.alloc(u32, @as(usize, dw) * dh);
    errdefer alloc.free(out);
    try resample.scale(alloc, src, sw, sh, out, dw, dh);
    return .{ .pixels = out, .width = dw, .height = dh };
}

/// Run `shotlet ARGS...` detached (double fork: never a zombie, and it
/// outlives us), with our own environment.
pub fn spawnSelf(env: Env, args: []const [*:0]const u8) void {
    spawnKeeping(env, args, null);
}

/// spawnSelf, handing the child `fd` (every other descriptor of ours
/// closes on exec).
pub fn spawnKeeping(env: Env, args: []const [*:0]const u8, fd: ?sys.fd_t) void {
    const linux = std.os.linux;
    var argv: [8:null]?[*:0]const u8 = @splat(null);
    argv[0] = "shotlet";
    for (args, 1..) |a, i| argv[i] = a;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        std.log.err("fork failed", .{});
        return;
    }
    if (pid == 0) {
        if (linux.fork() != 0) linux.exit(0);
        _ = linux.setsid();
        // the child's own descriptor table: the parent's copy still
        // closes on exec
        if (fd) |f| _ = linux.fcntl(f, linux.F.SETFD, 0);
        _ = linux.execve("/proc/self/exe", &argv, env.envp);
        linux.exit(127);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

/// Show the floating thumbnail for a kept capture. With `ready`, the
/// write end of a pipe: the thumbnail process writes to it once its
/// first frame is committed (or closes it, giving up).
pub fn spawnQuick(gpa: std.mem.Allocator, env: Env, k: *const Kept, ready: ?sys.fd_t) void {
    const root = gpa.dupeSentinel(u8, k.root(), 0) catch return;
    defer gpa.free(root);
    const id = gpa.dupeSentinel(u8, k.id.slice(), 0) catch return;
    defer gpa.free(id);
    var fd_buf: [16]u8 = undefined;
    const fd_arg = std.fmt.bufPrintSentinel(&fd_buf, "{d}", .{ready orelse -1}, 0) catch return;
    spawnKeeping(env, &.{ "quick", root.ptr, id.ptr, fd_arg.ptr }, ready);
}

test "thumbnails fit the box and average colours" {
    const alloc = std.testing.allocator;
    var src: [8 * 4]u32 = undefined;
    for (&src, 0..) |*p, i| p.* = if (i % 2 == 0) 0xFF000000 else 0xFFFFFFFF;
    const t = try thumbnail(alloc, &src, 8, 4, 4, 4);
    defer alloc.free(t.pixels);
    try std.testing.expectEqual(@as(u32, 4), t.width);
    try std.testing.expectEqual(@as(u32, 2), t.height);
    // black and white columns average to grey
    try std.testing.expectEqual(@as(u32, 0xFF808080), t.pixels[0]);
    // never scaled up
    const same = try thumbnail(alloc, &src, 8, 4, 100, 100);
    defer alloc.free(same.pixels);
    try std.testing.expectEqual(@as(u32, 8), same.width);
}
