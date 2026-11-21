//! Captures taken by the Shotlet GNOME Shell extension (prompt free):
//!
//!     shotlet --from-shell ID --monitors "x,y,w,h,scale;..."
//!             --pieces "x,y,w,h,scale;..." [--t0 MS]
//!
//! The extension took the screenshot inside the shell with
//! Shell.Screenshot.screenshot_area, one area ("piece") per monitor, or a
//! few horizontal strips of a monitor at an integer scale so that the PNG
//! encoding runs on several threads. Each piece is painted at its
//! monitor's own scale, without the cursor. Piece K is the PNG
//! $XDG_RUNTIME_DIR/shotlet/shot-ID-K.png: a private directory, the file
//! 0600. Shotlet builds those names itself from ID (letters and digits
//! only), reads each file once, deletes it at once, and stitches the
//! pieces as the portal path does (capture.stitch).

const std = @import("std");
const capture = @import("capture.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/sys.zig");

pub const max_monitors = 16;

/// One monitor in the compositor's logical layout.
pub const LogicalMonitor = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    scale: f64,
};

/// `--from-shell` and its companions.
pub const Args = struct {
    id: []const u8,
    monitors: []const u8 = "",
    pieces: []const u8 = "",
    /// the key press, on CLOCK_MONOTONIC, in ms
    t0_ms: ?i64 = null,
};

pub const max_pieces = 32;

/// "x,y,w,h,scale;..." as the extension writes it.
pub fn parseLayout(s: []const u8, out: []LogicalMonitor) ![]LogicalMonitor {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        if (n == out.len) return error.TooManyMonitors;
        var f = std.mem.splitScalar(u8, item, ',');
        const x = try std.fmt.parseInt(i32, f.next() orelse return error.BadLayout, 10);
        const y = try std.fmt.parseInt(i32, f.next() orelse return error.BadLayout, 10);
        const w = try std.fmt.parseInt(u32, f.next() orelse return error.BadLayout, 10);
        const h = try std.fmt.parseInt(u32, f.next() orelse return error.BadLayout, 10);
        const scale = try std.fmt.parseFloat(f64, f.next() orelse return error.BadLayout);
        if (f.next() != null) return error.BadLayout;
        if (w == 0 or h == 0 or w > 65535 or h > 65535) return error.BadLayout;
        if (!(scale >= 0.25 and scale <= 8)) return error.BadLayout;
        if (@abs(x) > 1 << 20 or @abs(y) > 1 << 20) return error.BadLayout;
        out[n] = .{ .x = x, .y = y, .w = w, .h = h, .scale = scale };
        n += 1;
    }
    if (n == 0) return error.BadLayout;
    return out[0..n];
}

/// The capture directory, $XDG_RUNTIME_DIR/shotlet.
pub fn dirPath(buf: []u8, runtime_dir: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet", .{runtime_dir});
}

/// The extension's capture ids: letters and digits.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// <runtime_dir>/shotlet/shot-<id>-<k>.png
pub fn piecePath(buf: []u8, runtime_dir: []const u8, id: []const u8, k: usize) ![]u8 {
    if (!validId(id)) return error.NotAShellCapture;
    return std.fmt.bufPrint(buf, "{s}/shotlet/shot-{s}-{d}.png", .{ runtime_dir, id, k });
}

/// The capture directory must be ours, private and not a symlink.
fn checkDir(runtime_dir: []const u8) !void {
    const linux = std.os.linux;
    var z: [1100]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&z, "{s}/shotlet", .{runtime_dir}, 0);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, dir.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stx)) != .SUCCESS) return error.NotAShellCapture;
    if (stx.mode & linux.S.IFMT != linux.S.IFDIR or stx.uid != linux.getuid() or stx.mode & 0o077 != 0) return error.NotAShellCapture;
}

/// Read one piece and delete it. Refuses a symlink, anything but a
/// regular file, and a file that is not ours or that others may read.
fn readAndRemove(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const linux = std.os.linux;
    var z: [4096]u8 = undefined;
    if (path.len >= z.len) return error.PathTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.openat(linux.AT.FDCWD, z[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
    // whatever happens next, the capture does not stay on disk
    defer sys.unlink(path) catch {};
    if (linux.errno(rc) != .SUCCESS) return error.NotAShellCapture;
    const fd: sys.fd_t = @intCast(rc);
    defer sys.close(fd);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true }, &stx)) != .SUCCESS) return error.NotAShellCapture;
    if (stx.mode & linux.S.IFMT != linux.S.IFREG or stx.uid != linux.getuid() or stx.mode & 0o077 != 0) return error.NotAShellCapture;
    if (stx.size > 512 * 1024 * 1024) return error.FileTooBig;
    const data = try gpa.alloc(u8, @intCast(stx.size));
    errdefer gpa.free(data);
    var got: usize = 0;
    while (got < data.len) {
        const n = try sys.read(fd, data[got..]);
        if (n == 0) return error.ShortRead;
        got += n;
    }
    return data;
}

fn contains(m: LogicalMonitor, p: LogicalMonitor) bool {
    return p.x >= m.x and p.y >= m.y and
        @as(i64, p.x) + p.w <= @as(i64, m.x) + m.w and
        @as(i64, p.y) + p.h <= @as(i64, m.y) + m.h;
}

/// Which monitor each piece belongs to; every monitor must be covered by
/// its pieces exactly (same scale, areas adding up).
pub fn assignPieces(monitors: []const LogicalMonitor, pieces: []const LogicalMonitor, owner: []usize) !void {
    var area: [max_monitors]u64 = @splat(0);
    for (pieces, owner) |p, *o| {
        o.* = for (monitors, 0..) |m, i| {
            if (contains(m, p)) break i;
        } else return error.BadLayout;
        if (@abs(monitors[o.*].scale - p.scale) > 1e-6) return error.BadLayout;
        area[o.*] += @as(u64, p.w) * p.h;
    }
    for (monitors, 0..) |m, i| if (area[i] != @as(u64, m.w) * m.h) return error.BadLayout;
}

/// Stitch the decoded pieces (each at its monitor's scale) into one
/// image, as capture.stitch does for the portal's monitor frames; the
/// monitors are the unions of their pieces.
pub fn build(gpa: std.mem.Allocator, monitors: []const LogicalMonitor, pieces: []const LogicalMonitor, images: []const png.Image) !capture.Capture {
    var owner: [max_pieces]usize = undefined;
    try assignPieces(monitors, pieces, owner[0..pieces.len]);
    var parts: [max_pieces]capture.Part = undefined;
    for (pieces, images, 0..) |p, im, i| {
        parts[i] = .{ .pixels = im.pixels, .width = im.width, .height = im.height, .logical = .{ .x = p.x, .y = p.y, .w = p.w, .h = p.h } };
    }
    var cap = try capture.stitch(gpa, parts[0..pieces.len]);
    errdefer cap.deinit(gpa);
    const mons = try gpa.alloc(capture.Monitor, monitors.len);
    for (monitors, mons, 0..) |m, *out, i| {
        var x0: u32 = std.math.maxInt(u32);
        var y0: u32 = std.math.maxInt(u32);
        var x1: u32 = 0;
        var y1: u32 = 0;
        for (cap.monitors, owner[0..pieces.len]) |pm, o| {
            if (o != i) continue;
            x0 = @min(x0, pm.x);
            y0 = @min(y0, pm.y);
            x1 = @max(x1, pm.x + pm.w);
            y1 = @max(y1, pm.y + pm.h);
        }
        out.* = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0, .logical = .{ .x = m.x, .y = m.y, .w = m.w, .h = m.h } };
    }
    gpa.free(cap.monitors);
    cap.monitors = mons;
    return cap;
}

const Slot = struct {
    data: []const u8,
    image: ?png.Image = null,
    err: ?anyerror = null,

    fn decode(self: *Slot, gpa: std.mem.Allocator) void {
        self.image = png.decode(gpa, self.data) catch |err| {
            self.err = err;
            return;
        };
    }
};

/// Read, delete and decode the pieces (on as many threads), and stitch
/// them. Every piece file is deleted, also when something fails.
pub fn load(gpa: std.mem.Allocator, runtime_dir: []const u8, args: Args) !capture.Capture {
    if (!validId(args.id)) return error.NotAShellCapture;
    var mons_buf: [max_monitors]LogicalMonitor = undefined;
    var pieces_buf: [max_pieces]LogicalMonitor = undefined;
    const pieces_or = parseLayout(args.pieces, &pieces_buf);
    const n_files = if (pieces_or) |p| p.len else |_| 0;
    var datas: [max_pieces][]u8 = undefined;
    var n_read: usize = 0;
    defer for (datas[0..n_read]) |d| gpa.free(d);
    defer removeAll(runtime_dir, args.id, n_read);
    const pieces = try pieces_or;
    const monitors = try parseLayout(args.monitors, &mons_buf);
    var owner: [max_pieces]usize = undefined;
    try assignPieces(monitors, pieces, owner[0..pieces.len]);
    try checkDir(runtime_dir);
    for (0..n_files) |k| {
        var buf: [1200]u8 = undefined;
        datas[k] = try readAndRemove(gpa, try piecePath(&buf, runtime_dir, args.id, k));
        n_read += 1;
    }

    var slots: [max_pieces]Slot = undefined;
    for (slots[0..pieces.len], datas[0..pieces.len]) |*sl, d| sl.* = .{ .data = d };
    defer for (slots[0..pieces.len]) |*sl| if (sl.image) |*im| im.deinit(gpa);
    var threads: [max_pieces]?std.Thread = @splat(null);
    for (slots[1..pieces.len], 1..) |*sl, i| {
        threads[i] = std.Thread.spawn(.{}, Slot.decode, .{ sl, gpa }) catch null;
        if (threads[i] == null) sl.decode(gpa);
    }
    slots[0].decode(gpa);
    for (threads[1..pieces.len]) |t| if (t) |th| th.join();
    var images: [max_pieces]png.Image = undefined;
    for (slots[0..pieces.len], 0..) |sl, i| {
        if (sl.err) |err| return err;
        images[i] = sl.image.?;
    }
    return build(gpa, monitors, pieces, images[0..pieces.len]);
}

/// Delete pieces left over after a failure (from `from` on).
fn removeAll(runtime_dir: []const u8, id: []const u8, from: usize) void {
    var k = from;
    while (k < max_pieces) : (k += 1) {
        var buf: [1200]u8 = undefined;
        const p = piecePath(&buf, runtime_dir, id, k) catch return;
        sys.unlink(p) catch return;
    }
}

test "layout parsing" {
    var buf: [4]LogicalMonitor = undefined;
    const l = try parseLayout("0,0,1280,720,2;1280,0,1280,720,1", &buf);
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try std.testing.expectEqual(LogicalMonitor{ .x = 1280, .y = 0, .w = 1280, .h = 720, .scale = 1 }, l[1]);
    const neg = try parseLayout("-1712,-10,1712,963,1.4953271150588989;", &buf);
    try std.testing.expectEqual(@as(i32, -1712), neg[0].x);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4953), neg[0].scale, 1e-3);
    try std.testing.expectError(error.BadLayout, parseLayout("", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,1,9", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,0,10,1", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,nan", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,0", &buf));
    try std.testing.expectError(error.InvalidCharacter, parseLayout("a,0,10,10,1", &buf));
    try std.testing.expectError(error.TooManyMonitors, parseLayout("0,0,1,1,1;1,0,1,1,1;2,0,1,1,1;3,0,1,1,1;4,0,1,1,1", &buf));
}

test "piece files: names Shotlet builds itself from a plain id" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/1000/shotlet/shot-0a1B-3.png", try piecePath(&buf, "/run/user/1000", "0a1B", 3));
    const long: [65]u8 = @splat('x');
    for ([_][]const u8{ "", "../x", "a/b", "a-b", "a.b", "a b", &long }) |id|
        try std.testing.expectError(error.NotAShellCapture, piecePath(&buf, "/run/user/1000", id, 0));
}

test "pieces must tile the monitors" {
    var mb: [4]LogicalMonitor = undefined;
    var pb: [8]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,100,60,2;100,0,50,50,1", &mb);
    var owner: [8]usize = undefined;
    const ok = try parseLayout("0,0,100,30,2;0,30,100,30,2;100,0,50,50,1", &pb);
    try assignPieces(mons, ok, owner[0..ok.len]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1 }, owner[0..3]);
    const gap = try parseLayout("0,0,100,30,2;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, gap, owner[0..gap.len]));
    const across = try parseLayout("0,0,120,60,2;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, across, owner[0..across.len]));
    const scale = try parseLayout("0,0,100,60,1;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, scale, owner[0..scale.len]));
}

fn solid(gpa: std.mem.Allocator, w: u32, h: u32, color: u32) !png.Image {
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    @memset(px, color);
    return .{ .width = w, .height = h, .pixels = px };
}

test "pieces stitch into mixed-scale monitors" {
    const gpa = std.testing.allocator;
    // 1280x720 logical at 2, in two strips; 1280x720 at 1 on its right
    var mb: [4]LogicalMonitor = undefined;
    var pb: [8]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,1280,720,2;1280,0,1280,720,1", &mb);
    const pieces = try parseLayout("0,0,1280,360,2;0,360,1280,360,2;1280,0,1280,720,1", &pb);
    var imgs = [_]png.Image{
        try solid(gpa, 2560, 720, 0xFFFF0000),
        try solid(gpa, 2560, 720, 0xFF00FF00),
        try solid(gpa, 1280, 720, 0xFF0000FF),
    };
    defer for (&imgs) |*im| im.deinit(gpa);
    var cap = try build(gpa, mons, pieces, &imgs);
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 5120), cap.image.width);
    try std.testing.expectEqual(@as(u32, 1440), cap.image.height);
    try std.testing.expectEqual(@as(usize, 2), cap.monitors.len);
    try std.testing.expectEqual(capture.Monitor{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 } }, cap.monitors[0]);
    try std.testing.expectEqual(capture.Monitor{ .x = 2560, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 } }, cap.monitors[1]);
    const W = 5120;
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), cap.image.pixels[719 * W + 10]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cap.image.pixels[720 * W + 10]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[1439 * W + 5119]);
}

test "a fractional monitor in one piece next to a 1x one" {
    const gpa = std.testing.allocator;
    var mb: [4]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,1712,963,1.4953271150588989;1712,0,1280,720,1", &mb);
    var imgs = [_]png.Image{ try solid(gpa, 2560, 1440, 0xFF111111), try solid(gpa, 1280, 720, 0xFF222222) };
    defer for (&imgs) |*im| im.deinit(gpa);
    var cap = try build(gpa, mons, mons, &imgs);
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2560), cap.monitors[0].w);
    try std.testing.expectEqual(@as(u32, 1440), cap.monitors[0].h);
    try std.testing.expectEqual(@as(u32, 2560), cap.monitors[1].x);
    try std.testing.expect(cap.monitors[1].x + cap.monitors[1].w <= cap.image.width);
}

test "pieces are read once, deleted, and never through a symlink" {
    const gpa = std.testing.allocator;
    const rt = try sys.makeTempDir(gpa, "/tmp", "shotlet-rt");
    defer gpa.free(rt);
    defer sys.removeTree(rt);
    var dbuf: [1024]u8 = undefined;
    const dir = try dirPath(&dbuf, rt);
    sys.mkdirMode(dir, 0o700);
    var pbuf: [1200]u8 = undefined;

    // a tiny 2x1 PNG as the only piece of a 2x1 monitor
    const data = try png.encode(gpa, &.{ 0xFFFF0000, 0xFF0000FF }, 2, 1);
    defer gpa.free(data);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    var cap = try load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" });
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[1]);
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));

    // readable by others: refused, and still deleted
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o644);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);

    // a symlink in its place is not followed; the target stays
    var tbuf: [1200]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&tbuf, "{s}/keep.png", .{rt}, 0);
    try sys.writeFileExclusive(target, data, 0o600);
    var lz: [1200]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&lz, "{s}", .{try piecePath(&pbuf, rt, "abc", 0)}, 0);
    _ = std.os.linux.symlinkat(target.ptr, std.os.linux.AT.FDCWD, link.ptr);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
    try std.testing.expect(sys.mtimeSec(target) != null);

    // a layout that does not add up: the files go anyway
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 1), data, 0o600);
    try std.testing.expectError(error.BadLayout, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,4,1,1", .pieces = "0,0,2,1,1;2,0,2,1,1;0,0,9,9,1" }));
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 1)) == null);

    // the directory open to others: refused
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, (try std.fmt.bufPrintSentinel(&lz, "{s}", .{dir}, 0)).ptr, 0o755);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
}
