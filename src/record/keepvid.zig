//! A finished recording in the history (or the cache, with the history
//! off): an ordinary entry whose image is the first picture, with `saved`
//! the video file, plus
//!
//!     <entry>/video       key=value: path, format, duration_ms, frames,
//!                         fps, width, height, strip (frame of each picture)
//!     <entry>/strip.png   the filmstrip (strip.zig), pictures side by side
//!
//! The video itself stays where it was written (the Videos folder).

const std = @import("std");
const history = @import("../app/history.zig");
const keep = @import("../app/keep.zig");
const config = @import("../app/config.zig");
const env_mod = @import("../app/env.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/sys.zig");
const strip_mod = @import("strip.zig");
const sink = @import("../encode/sink.zig");

pub const Info = struct {
    path: []const u8 = "",
    format: sink.Format = .mp4,
    duration_ms: i64 = 0,
    frames: u64 = 0,
    fps: u32 = 30,
    width: u32 = 0,
    height: u32 = 0,
    /// frame number of each filmstrip picture, "0,12,24"
    strip: []const u8 = "",

    pub fn format_(self: *const Info, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "shotlet-video 1\npath={s}\nformat={t}\nduration_ms={d}\nframes={d}\nfps={d}\nsize={d}x{d}\nstrip={s}\n", .{ self.path, self.format, self.duration_ms, self.frames, self.fps, self.width, self.height, self.strip });
    }

    /// Values point into `data`.
    pub fn parse(data: []const u8) !Info {
        var it = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, it.next() orelse "", "shotlet-video 1")) return error.BadVideoInfo;
        var i: Info = .{};
        while (it.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = line[eq + 1 ..];
            if (std.mem.eql(u8, k, "path")) i.path = v;
            if (std.mem.eql(u8, k, "format")) i.format = std.meta.stringToEnum(sink.Format, v) orelse .mp4;
            if (std.mem.eql(u8, k, "duration_ms")) i.duration_ms = std.fmt.parseInt(i64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "frames")) i.frames = std.fmt.parseInt(u64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "fps")) i.fps = std.fmt.parseInt(u32, v, 10) catch 30;
            if (std.mem.eql(u8, k, "strip")) i.strip = v;
            if (std.mem.eql(u8, k, "size")) {
                const x = std.mem.indexOfScalar(u8, v, 'x') orelse continue;
                i.width = std.fmt.parseInt(u32, v[0..x], 10) catch 0;
                i.height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch 0;
            }
        }
        if (i.path.len == 0) return error.BadVideoInfo;
        return i;
    }
};

/// Read an entry's video info (null when it is not a recording). The
/// values point into the returned buffer.
pub fn read(gpa: std.mem.Allocator, root: []const u8, id: []const u8) ?struct { info: Info, buf: []u8 } {
    var pbuf: [1200]u8 = undefined;
    const p = history.entryPath(&pbuf, root, id, "video") catch return null;
    const data = sys.readFileAlloc(gpa, p, 64 * 1024) catch return null;
    const info = Info.parse(data) catch {
        gpa.free(data);
        return null;
    };
    return .{ .info = info, .buf = data };
}

pub const What = struct {
    info: Info,
    first: []const u32,
    first_w: u32,
    first_h: u32,
    strip: *const strip_mod.Strip,
};

/// Store the recording; null (logged) when nothing was stored.
pub fn store(gpa: std.mem.Allocator, env: env_mod.Env, cfg: *const config.Config, what: What) ?keep.Kept {
    return storeInner(gpa, env, cfg, what) catch |err| {
        std.log.warn("could not keep the recording: {t}", .{err});
        return null;
    };
}

fn storeInner(gpa: std.mem.Allocator, env: env_mod.Env, cfg: *const config.Config, what: What) !?keep.Kept {
    if (!cfg.history and !cfg.quick_access) return null;
    var k: keep.Kept = .{ .id = undefined };
    k.root_len = (try keep.rootFor(cfg, env, &k.root_buf)).len;
    const image = try png.encode(gpa, what.first, what.first_w, what.first_h);
    defer gpa.free(image);
    const t = try keep.thumbnail(gpa, what.first, what.first_w, what.first_h, keep.thumb_w, keep.thumb_h);
    defer gpa.free(t.pixels);
    const thumb = try png.encode(gpa, t.pixels, t.width, t.height);
    defer gpa.free(thumb);
    k.id = try history.create(gpa, k.root(), .{
        .meta = .{ .time_ms = sys.realtimeMs(), .width = what.info.width, .height = what.info.height, .saved = what.info.path },
        .image_png = image,
        .thumb_png = thumb,
    });
    const info = try what.info.format_(gpa);
    defer gpa.free(info);
    try history.replaceFile(k.root(), k.id.slice(), "video", info);
    if (what.strip.n > 0) {
        const px = try what.strip.joined(gpa);
        defer gpa.free(px);
        const sp = try png.encode(gpa, px, what.strip.w * @as(u32, @intCast(what.strip.n)), what.strip.h);
        defer gpa.free(sp);
        try history.replaceFile(k.root(), k.id.slice(), "strip.png", sp);
    }
    if (cfg.history) _ = history.prune(gpa, k.root(), cfg.history_max, @as(u64, cfg.history_max_mb) * 1024 * 1024) catch 0;
    return k;
}

test "video info round-trips" {
    const gpa = std.testing.allocator;
    const i: Info = .{ .path = "/v/a b.mp4", .format = .gif, .duration_ms = 2500, .frames = 38, .fps = 15, .width = 320, .height = 200, .strip = "0,4,8" };
    const s = try i.format_(gpa);
    defer gpa.free(s);
    const back = try Info.parse(s);
    try std.testing.expectEqualStrings("/v/a b.mp4", back.path);
    try std.testing.expectEqual(sink.Format.gif, back.format);
    try std.testing.expectEqual(@as(i64, 2500), back.duration_ms);
    try std.testing.expectEqual(@as(u32, 200), back.height);
    try std.testing.expectEqualStrings("0,4,8", back.strip);
    try std.testing.expectError(error.BadVideoInfo, Info.parse("nope"));
}
