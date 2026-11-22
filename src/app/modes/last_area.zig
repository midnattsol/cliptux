//! "Capture previous area": the last selection copied or saved, kept per
//! monitor layout in $XDG_STATE_HOME/shotlet/last-area, one line each,
//! newest first:
//!
//!     <layout hash, 16 hex digits> X Y W H
//!
//! The rectangle is in image pixels of a capture of that layout (every
//! monitor's position, logical size and pixel size go into the hash), so
//! a selection made with one set of monitors is never applied to another.

const std = @import("std");
const capture = @import("../capture.zig");
const env = @import("../env.zig");
const sys = @import("../../platform/linux/sys.zig");
const Rect = @import("geom.zig").Rect;

const max_layouts = 8;

pub fn layoutKey(mons: []const capture.Monitor, img_w: u32, img_h: u32) u64 {
    var h = std.hash.Wyhash.init(0x1a57);
    h.update(std.mem.asBytes(&[2]u32{ img_w, img_h }));
    for (mons) |m| {
        h.update(std.mem.asBytes(&[4]u32{ m.x, m.y, m.w, m.h }));
        if (m.logical) |l| h.update(std.mem.asBytes(&[4]i64{ l.x, l.y, l.w, l.h }));
    }
    return h.final();
}

fn parseLine(line: []const u8) ?struct { key: u64, rect: Rect } {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const key = std.fmt.parseInt(u64, it.next() orelse return null, 16) catch return null;
    var v: [4]i32 = undefined;
    for (&v) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    if (v[2] <= 0 or v[3] <= 0) return null;
    return .{ .key = key, .rect = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] } };
}

/// The rectangle remembered for `key` in the file's contents.
pub fn lookup(data: []const u8, key: u64) ?Rect {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| if (parseLine(line)) |e| if (e.key == key) return e.rect;
    return null;
}

/// The file's new contents: `key` first, then up to max_layouts - 1
/// other layouts as they were.
pub fn merged(out: []u8, data: []const u8, key: u64, r: Rect) ![]u8 {
    var w: std.Io.Writer = .fixed(out);
    try w.print("{x:0>16} {d} {d} {d} {d}\n", .{ key, r.x, r.y, r.w, r.h });
    var n: usize = 1;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const e = parseLine(line) orelse continue;
        if (e.key == key or n == max_layouts) continue;
        try w.print("{s}\n", .{line});
        n += 1;
    }
    return w.buffered();
}

fn filePath(buf: []u8, home: []const u8) ![]u8 {
    var dbuf: [1024]u8 = undefined;
    const dir = try env.stateDir(&dbuf, home);
    return std.fmt.bufPrint(buf, "{s}/last-area", .{dir});
}

pub fn load(gpa: std.mem.Allocator, home: []const u8, key: u64) ?Rect {
    var pbuf: [1100]u8 = undefined;
    const data = sys.readFileAlloc(gpa, filePath(&pbuf, home) catch return null, 4096) catch return null;
    defer gpa.free(data);
    return lookup(data, key);
}

pub fn save(gpa: std.mem.Allocator, home: []const u8, key: u64, r: Rect) void {
    saveInner(gpa, home, key, r) catch |err| std.log.warn("could not remember the selection: {t}", .{err});
}

fn saveInner(gpa: std.mem.Allocator, home: []const u8, key: u64, r: Rect) !void {
    var dbuf: [1024]u8 = undefined;
    sys.mkdirAll(try env.stateDir(&dbuf, home), 0o700);
    var pbuf: [1100]u8 = undefined;
    const path = try filePath(&pbuf, home);
    const old = sys.readFileAlloc(gpa, path, 4096) catch try gpa.dupe(u8, "");
    defer gpa.free(old);
    var out: [4096]u8 = undefined;
    try sys.writeFile(path, try merged(&out, old, key, r));
}

/// Remember the selection of a capture that was copied or saved.
pub fn remember(gpa: std.mem.Allocator, home: []const u8, cap: *const capture.Capture, sel: Rect) void {
    if (sel.w <= 0 or sel.h <= 0) return;
    save(gpa, home, layoutKey(cap.monitors, cap.image.width, cap.image.height), sel);
}

test "previous areas are kept per monitor layout" {
    const one = [_]capture.Monitor{.{ .x = 0, .y = 0, .w = 1600, .h = 900, .logical = .{ .x = 0, .y = 0, .w = 1600, .h = 900 } }};
    const two = [_]capture.Monitor{ one[0], .{ .x = 1600, .y = 0, .w = 1280, .h = 720, .logical = .{ .x = 1600, .y = 0, .w = 1280, .h = 720 } } };
    const k1 = layoutKey(&one, 1600, 900);
    const k2 = layoutKey(&two, 2880, 900);
    try std.testing.expect(k1 != k2);
    var b1: [4096]u8 = undefined;
    const d1 = try merged(&b1, "", k1, .{ .x = 10, .y = 20, .w = 300, .h = 200 });
    var b2: [4096]u8 = undefined;
    const d2 = try merged(&b2, d1, k2, .{ .x = 1700, .y = 5, .w = 50, .h = 60 });
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 300, .h = 200 }, lookup(d2, k1).?);
    try std.testing.expectEqual(Rect{ .x = 1700, .y = 5, .w = 50, .h = 60 }, lookup(d2, k2).?);
    // the same layout again: replaced, not duplicated
    var b3: [4096]u8 = undefined;
    const d3 = try merged(&b3, d2, k1, .{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, lookup(d3, k1).?);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, d3, "\n"));
    try std.testing.expectEqual(@as(?Rect, null), lookup("garbage\nffff 1 2 0 4\n", 0xffff));
}

test "at most a few layouts are remembered" {
    var buf: [2][4096]u8 = undefined;
    var data: []const u8 = "";
    for (0..20) |i| data = try merged(&buf[i % 2], data, i, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(usize, max_layouts), std.mem.count(u8, data, "\n"));
    try std.testing.expect(lookup(data, 19) != null);
    try std.testing.expect(lookup(data, 0) == null);
}

test "previous area persists on disk" {
    const gpa = std.testing.allocator;
    const home = try sys.makeTempDir(gpa, "/tmp", "shotlet-home");
    defer gpa.free(home);
    defer sys.removeTree(home);
    const saved = env.xdg;
    defer env.xdg = saved;
    env.xdg = .{};
    save(gpa, home, 42, .{ .x = 5, .y = 6, .w = 7, .h = 8 });
    try std.testing.expectEqual(Rect{ .x = 5, .y = 6, .w = 7, .h = 8 }, load(gpa, home, 42).?);
    try std.testing.expectEqual(@as(?Rect, null), load(gpa, home, 43));
}
