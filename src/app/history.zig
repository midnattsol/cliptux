//! Captures kept after Copy or Save: one directory per capture under a
//! root ($XDG_STATE_HOME/shotlet/history, or a cache directory when the
//! history is off and the floating thumbnail still needs the files).
//!
//!     <root>/<id>/image.png    what was copied or saved
//!     <root>/<id>/thumb.png    small preview for the thumbnail and grid
//!     <root>/<id>/meta         key=value: time, size, saved path, OCR text
//!     <root>/<id>/source.png   the unannotated pixels around the selection
//!     <root>/<id>/doc          the annotations (annot.zig), editable again
//!
//! An id is "<unix ms, 13 digits>-<8 hex>", so names sort by age. An entry
//! appears atomically (written into ".new-<id>", then renamed); anything
//! without a readable meta and image is ignored by list() and removed by
//! prune(). The newest entries are kept: at most `max_count` of them, and
//! older ones are dropped while the total exceeds `max_bytes`.

const std = @import("std");
const sys = @import("../platform/linux/sys.zig");
const env_mod = @import("env.zig");

pub const Id = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn fromSlice(s: []const u8) ?Id {
        if (!valid(s)) return null;
        var id: Id = .{ .len = @intCast(s.len) };
        @memcpy(id.buf[0..s.len], s);
        return id;
    }

    /// "<13 digits>-<8 hex>": also keeps paths built from ids inside the root
    pub fn valid(s: []const u8) bool {
        if (s.len != 22 or s[13] != '-') return false;
        for (s[0..13]) |c| if (!std.ascii.isDigit(c)) return false;
        for (s[14..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    pub fn make(time_ms: i64) Id {
        var rnd: [4]u8 = undefined;
        sys.getRandom(&rnd);
        var id: Id = .{};
        const s = std.fmt.bufPrint(&id.buf, "{d:0>13}-{x:0>8}", .{ @as(u64, @intCast(@max(0, time_ms))), std.mem.readInt(u32, &rnd, .little) }) catch unreachable;
        id.len = @intCast(s.len);
        return id;
    }
};

pub const Meta = struct {
    /// unix milliseconds of the capture
    time_ms: i64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// where Save wrote it; empty when only copied
    saved: []const u8 = "",
    /// recognised text; null until OCR ran
    ocr: ?[]const u8 = null,

    pub fn deinit(self: *Meta, alloc: std.mem.Allocator) void {
        alloc.free(self.saved);
        if (self.ocr) |o| alloc.free(o);
        self.* = .{};
    }

    pub fn format(self: *const Meta, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.print(alloc, "shotlet-history 1\ntime={d}\nsize={d}x{d}\n", .{ self.time_ms, self.width, self.height });
        if (self.saved.len > 0) {
            try out.appendSlice(alloc, "saved=");
            try escape(alloc, &out, self.saved);
            try out.append(alloc, '\n');
        }
        if (self.ocr) |o| {
            try out.appendSlice(alloc, "ocr=");
            try escape(alloc, &out, o);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn parse(alloc: std.mem.Allocator, data: []const u8) !Meta {
        var lines = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", "shotlet-history 1")) return error.BadMeta;
        var m: Meta = .{};
        errdefer m.deinit(alloc);
        var have_time = false;
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "time")) {
                m.time_ms = std.fmt.parseInt(i64, v, 10) catch return error.BadMeta;
                have_time = true;
            } else if (std.mem.eql(u8, k, "size")) {
                const x = std.mem.indexOfScalar(u8, v, 'x') orelse return error.BadMeta;
                m.width = std.fmt.parseInt(u32, v[0..x], 10) catch return error.BadMeta;
                m.height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch return error.BadMeta;
            } else if (std.mem.eql(u8, k, "saved")) {
                alloc.free(m.saved);
                m.saved = try unescape(alloc, v);
            } else if (std.mem.eql(u8, k, "ocr")) {
                if (m.ocr) |o| alloc.free(o);
                m.ocr = try unescape(alloc, v);
            }
        }
        if (!have_time) return error.BadMeta;
        return m;
    }
};

/// Backslash escapes for \, newline and CR, so values stay on one line.
fn escape(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        else => try out.append(alloc, c),
    };
}

fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(alloc, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                else => s[i],
            });
        } else try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

pub const Entry = struct {
    id: Id,
    meta: Meta,
    /// bytes on disk
    bytes: u64,
    /// the annotations can be edited again (doc + source.png present)
    editable: bool,

    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        self.meta.deinit(alloc);
    }
};

pub fn freeList(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(alloc);
    alloc.free(entries);
}

/// $XDG_STATE_HOME/shotlet/history
pub fn historyRoot(buf: []u8, home: []const u8) ![]u8 {
    var tmp: [1024]u8 = undefined;
    const state = try env_mod.stateDir(&tmp, home);
    return std.fmt.bufPrint(buf, "{s}/history", .{state});
}

/// $XDG_CACHE_HOME/shotlet/quick: captures shown while the history is off
pub fn cacheRoot(buf: []u8, home: []const u8) ![]u8 {
    var tmp: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&tmp, home);
    return std.fmt.bufPrint(buf, "{s}/quick", .{cache});
}

pub fn entryPath(buf: []u8, root: []const u8, id: []const u8, file: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ root, id, file });
}

pub const NewEntry = struct {
    meta: Meta,
    image_png: []const u8,
    thumb_png: []const u8,
    source_png: ?[]const u8 = null,
    doc: ?[]const u8 = null,
};

/// Write a new entry; it becomes visible all at once. Returns its id.
pub fn create(alloc: std.mem.Allocator, root: []const u8, e: NewEntry) !Id {
    sys.mkdirAll(root, 0o700);
    const id = Id.make(e.meta.time_ms);
    var tmp_buf: [1200]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/.new-{s}", .{ root, id.slice() });
    sys.mkdirMode(tmp, 0o700);
    errdefer sys.removeTree(tmp);
    const meta = try e.meta.format(alloc);
    defer alloc.free(meta);
    try writeIn(tmp, "image.png", e.image_png);
    try writeIn(tmp, "thumb.png", e.thumb_png);
    if (e.source_png) |d| try writeIn(tmp, "source.png", d);
    if (e.doc) |d| try writeIn(tmp, "doc", d);
    try writeIn(tmp, "meta", meta);
    var dst_buf: [1200]u8 = undefined;
    try sys.rename(tmp, try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ root, id.slice() }));
    return id;
}

fn writeIn(dir: []const u8, name: []const u8, data: []const u8) !void {
    var buf: [1200]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    const fd = try sys.createExclusive(path, 0o600);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
}

/// Replace one file of an entry atomically (write aside, rename over).
pub fn replaceFile(root: []const u8, id: []const u8, name: []const u8, data: []const u8) !void {
    if (!Id.valid(id)) return error.BadId;
    var tmp_buf: [1200]u8 = undefined;
    var rnd: [4]u8 = undefined;
    sys.getRandom(&rnd);
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/{s}/.{s}.{x}", .{ root, id, name, std.mem.readInt(u32, &rnd, .little) });
    {
        const fd = try sys.createExclusive(tmp, 0o600);
        defer sys.close(fd);
        errdefer sys.unlink(tmp) catch {};
        try sys.writeAll(fd, data);
    }
    var dst_buf: [1200]u8 = undefined;
    sys.rename(tmp, try entryPath(&dst_buf, root, id, name)) catch |err| {
        sys.unlink(tmp) catch {};
        return err;
    };
}

/// Rewrite an entry's meta (e.g. after Save or OCR).
pub fn writeMeta(alloc: std.mem.Allocator, root: []const u8, id: []const u8, m: *const Meta) !void {
    const data = try m.format(alloc);
    defer alloc.free(data);
    try replaceFile(root, id, "meta", data);
}

pub fn readMeta(alloc: std.mem.Allocator, root: []const u8, id: []const u8) !Meta {
    if (!Id.valid(id)) return error.BadId;
    var buf: [1200]u8 = undefined;
    const data = try sys.readFileAlloc(alloc, try entryPath(&buf, root, id, "meta"), 1 << 20);
    defer alloc.free(data);
    return Meta.parse(alloc, data);
}

fn fileBytes(root: []const u8, id: []const u8, name: []const u8) ?u64 {
    var buf: [1200]u8 = undefined;
    return sys.fileSize(entryPath(&buf, root, id, name) catch return null) catch null;
}

/// Readable entries, newest first. Damaged ones are left out.
pub fn list(alloc: std.mem.Allocator, root: []const u8) ![]Entry {
    const names = sys.listDir(alloc, root) catch |err| switch (err) {
        error.NotFound => return try alloc.alloc(Entry, 0),
        else => return err,
    };
    defer {
        sys.freeNames(alloc, names);
        alloc.free(names);
    }
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(alloc);
        out.deinit(alloc);
    }
    for (names) |n| {
        if (!n.is_dir) continue;
        const id = Id.fromSlice(n.name) orelse continue;
        const image = fileBytes(root, n.name, "image.png") orelse continue;
        var meta = readMeta(alloc, root, n.name) catch continue;
        errdefer meta.deinit(alloc);
        var bytes = image;
        for ([_][]const u8{ "thumb.png", "meta", "source.png", "doc" }) |f| bytes += fileBytes(root, n.name, f) orelse 0;
        const editable = fileBytes(root, n.name, "doc") != null and fileBytes(root, n.name, "source.png") != null;
        try out.append(alloc, .{ .id = id, .meta = meta, .bytes = bytes, .editable = editable });
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            if (a.meta.time_ms != b.meta.time_ms) return a.meta.time_ms > b.meta.time_ms;
            return std.mem.order(u8, a.id.slice(), b.id.slice()) == .gt;
        }
    }.newer);
    return out.toOwnedSlice(alloc);
}

pub fn remove(root: []const u8, id: []const u8) !void {
    if (!Id.valid(id)) return error.BadId;
    var buf: [1200]u8 = undefined;
    sys.removeTree(try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, id }));
}

/// Remove every entry (and anything else) under the root.
pub fn clear(root: []const u8) void {
    sys.removeTree(root);
}

/// Enforce the caps; also removes damaged entries and leftovers of
/// interrupted writes older than a minute. Returns how many entries went.
pub fn prune(alloc: std.mem.Allocator, root: []const u8, max_count: usize, max_bytes: u64) !usize {
    var removed: usize = 0;
    // damaged and half-written directories
    if (sys.listDir(alloc, root)) |names| {
        defer {
            sys.freeNames(alloc, names);
            alloc.free(names);
        }
        const now = sys.realtimeSec();
        for (names) |n| {
            if (!n.is_dir) continue;
            var buf: [1200]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, n.name }) catch continue;
            const old = (sys.mtimeSec(path) orelse now) < now - 60;
            if (std.mem.startsWith(u8, n.name, ".new-")) {
                if (old) sys.removeTree(path);
                continue;
            }
            if (!Id.valid(n.name)) continue; // not ours: leave it alone
            const ok = fileBytes(root, n.name, "image.png") != null and blk: {
                var m = readMeta(alloc, root, n.name) catch break :blk false;
                m.deinit(alloc);
                break :blk true;
            };
            if (!ok and old) {
                sys.removeTree(path);
                removed += 1;
            }
        }
    } else |_| {}

    const entries = try list(alloc, root);
    defer freeList(alloc, entries);
    var total: u64 = 0;
    for (entries, 0..) |e, i| {
        total += e.bytes;
        // the newest entry always stays, whatever its size
        if (i > 0 and (i >= max_count or total > max_bytes)) {
            remove(root, e.id.slice()) catch continue;
            removed += 1;
        }
    }
    return removed;
}

// --- tests ---

fn testRoot(alloc: std.mem.Allocator) ![]u8 {
    return sys.makeTempDir(alloc, "/tmp", "shotlet-history-test");
}

fn addTest(alloc: std.mem.Allocator, root: []const u8, time: i64, size: usize) !Id {
    const img = try alloc.alloc(u8, size);
    defer alloc.free(img);
    @memset(img, 0xAB);
    return create(alloc, root, .{ .meta = .{ .time_ms = time, .width = 10, .height = 20 }, .image_png = img, .thumb_png = "t" });
}

test "meta round-trips and escapes its values" {
    const alloc = std.testing.allocator;
    var m: Meta = .{ .time_ms = 1763740953123, .width = 640, .height = 480, .saved = "/home/u/a\\b\nc.png", .ocr = "line 1\nline 2\r" };
    const data = try m.format(alloc);
    defer alloc.free(data);
    var back = try Meta.parse(alloc, data);
    defer back.deinit(alloc);
    try std.testing.expectEqual(m.time_ms, back.time_ms);
    try std.testing.expectEqual(@as(u32, 640), back.width);
    try std.testing.expectEqualStrings(m.saved, back.saved);
    try std.testing.expectEqualStrings(m.ocr.?, back.ocr.?);
    // no OCR yet stays null; a missing time is damage
    var plain = try Meta.parse(alloc, "shotlet-history 1\ntime=5\nsize=1x2\n");
    defer plain.deinit(alloc);
    try std.testing.expect(plain.ocr == null and plain.saved.len == 0);
    try std.testing.expectError(error.BadMeta, Meta.parse(alloc, "shotlet-history 1\nsize=1x2\n"));
    try std.testing.expectError(error.BadMeta, Meta.parse(alloc, "garbage"));
    try std.testing.expectError(error.BadMeta, Meta.parse(alloc, "shotlet-history 1\ntime=x\n"));
}

test "ids are validated before they become paths" {
    try std.testing.expect(Id.valid(Id.make(1763740953123).slice()));
    try std.testing.expect(!Id.valid("../../etc/passwd"));
    try std.testing.expect(!Id.valid("1763740953123-0000000g"));
    try std.testing.expect(!Id.valid(""));
    try std.testing.expectError(error.BadId, remove("/tmp", ".."));
}

test "entries list newest first and survive a reload" {
    const alloc = std.testing.allocator;
    const root = try testRoot(alloc);
    defer alloc.free(root);
    defer sys.removeTree(root);
    _ = try addTest(alloc, root, 1000, 10);
    const newest = try addTest(alloc, root, 3000, 10);
    _ = try addTest(alloc, root, 2000, 10);
    const l = try list(alloc, root);
    defer freeList(alloc, l);
    try std.testing.expectEqual(@as(usize, 3), l.len);
    try std.testing.expectEqualStrings(newest.slice(), l[0].id.slice());
    try std.testing.expectEqual(@as(i64, 2000), l[1].meta.time_ms);
    try std.testing.expectEqual(@as(i64, 1000), l[2].meta.time_ms);
    try std.testing.expect(!l[0].editable);

    // saving later records the path
    var m = l[0].meta;
    m.saved = "/x/y.png";
    try writeMeta(alloc, root, l[0].id.slice(), &m);
    var r = try readMeta(alloc, root, l[0].id.slice());
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("/x/y.png", r.saved);
}

test "caps by count and size keep the newest" {
    const alloc = std.testing.allocator;
    const root = try testRoot(alloc);
    defer alloc.free(root);
    defer sys.removeTree(root);
    for (0..6) |i| _ = try addTest(alloc, root, @intCast(1000 + i), 1000);
    try std.testing.expectEqual(@as(usize, 2), try prune(alloc, root, 4, 1 << 30));
    {
        const l = try list(alloc, root);
        defer freeList(alloc, l);
        try std.testing.expectEqual(@as(usize, 4), l.len);
        try std.testing.expectEqual(@as(i64, 1005), l[0].meta.time_ms);
        try std.testing.expectEqual(@as(i64, 1002), l[3].meta.time_ms);
    }
    // each entry is a bit over 1000 bytes: 2500 bytes keep two
    _ = try prune(alloc, root, 50, 2500);
    {
        const l = try list(alloc, root);
        defer freeList(alloc, l);
        try std.testing.expectEqual(@as(usize, 2), l.len);
        try std.testing.expectEqual(@as(i64, 1004), l[1].meta.time_ms);
    }
    // the newest stays even when it alone is over the size cap
    _ = try prune(alloc, root, 50, 10);
    const l = try list(alloc, root);
    defer freeList(alloc, l);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqual(@as(i64, 1005), l[0].meta.time_ms);
}

test "damaged entries are skipped, then cleaned up" {
    const alloc = std.testing.allocator;
    const root = try testRoot(alloc);
    defer alloc.free(root);
    defer sys.removeTree(root);
    const good = try addTest(alloc, root, 5000, 10);
    // no image
    const a = Id.make(6000);
    var buf: [1200]u8 = undefined;
    sys.mkdirMode(try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, a.slice() }), 0o700);
    try sys.writeFile(try entryPath(&buf, root, a.slice(), "meta"), "shotlet-history 1\ntime=6000\n");
    // garbage meta
    const b = try addTest(alloc, root, 7000, 10);
    try sys.writeFile(try entryPath(&buf, root, b.slice(), "meta"), "\x00\xff junk");
    // a stray directory that is not ours, and a half-written entry
    sys.mkdirMode(try std.fmt.bufPrint(&buf, "{s}/notes", .{root}), 0o700);
    sys.mkdirMode(try std.fmt.bufPrint(&buf, "{s}/.new-1", .{root}), 0o700);
    const l = try list(alloc, root);
    defer freeList(alloc, l);
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectEqualStrings(good.slice(), l[0].id.slice());
    // fresh damage may be a write in progress elsewhere: kept for now
    try std.testing.expectEqual(@as(usize, 0), try prune(alloc, root, 50, 1 << 30));
    try std.testing.expect(sys.fileSize(try std.fmt.bufPrint(&buf, "{s}/notes", .{root})) != error.NotFound);
    try remove(root, good.slice());
    const l2 = try list(alloc, root);
    defer freeList(alloc, l2);
    try std.testing.expectEqual(@as(usize, 0), l2.len);
    clear(root);
    const l3 = try list(alloc, root);
    defer freeList(alloc, l3);
    try std.testing.expectEqual(@as(usize, 0), l3.len);
}
