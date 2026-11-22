//! Cutting a recording to [start, end): MP4 through the ffmpeg program
//! (re-encoded, so the cut is exact, sound kept), GIF by our own decoder
//! and encoder. The result is a new file next to the original
//! (`<name>-trim.mp4`), never over one.

const std = @import("std");
const proc = @import("../encode/proc.zig");
const gif = @import("../encode/gif.zig");
const gifdec = @import("../encode/gifdec.zig");
const sys = @import("../platform/api.zig").sys;
const shot = @import("../app/shot.zig");

pub const Range = struct { start_ms: i64, end_ms: i64 };

/// `<dir>/<base>-trim<ext>` (or -trim-2 ...), reserved; owned.
pub fn outputPath(gpa: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse return error.BadPath;
    const dot = std.mem.lastIndexOfScalar(u8, src, '.') orelse src.len;
    if (dot < slash) return error.BadPath;
    var base_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "{s}-trim", .{src[slash + 1 .. dot]});
    const p = try shot.writeUnique(gpa, src[0..slash], base, src[dot..], "");
    defer gpa.free(p);
    return gpa.dupeSentinel(u8, p, 0);
}

/// Write the part `r` of `src` to `dst` (already reserved).
pub fn cut(gpa: std.mem.Allocator, envp: proc.Envp, src: []const u8, dst: [:0]const u8, r: Range) !void {
    if (r.end_ms <= r.start_ms) return error.EmptyRange;
    if (std.ascii.endsWithIgnoreCase(src, ".gif")) return cutGif(gpa, src, dst, r);
    return cutMp4(gpa, envp, src, dst, r);
}

fn seconds(buf: []u8, ms: i64) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{d}.{d:0>3}", .{ @divTrunc(ms, 1000), @as(u64, @intCast(@mod(ms, 1000))) }, 0);
}

fn cutMp4(gpa: std.mem.Allocator, envp: proc.Envp, src: []const u8, dst: [:0]const u8, r: Range) !void {
    var exe_buf: [512]u8 = undefined;
    const exe = proc.which(&exe_buf, "ffmpeg") orelse return error.NoFfmpeg;
    const srcz = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(srcz);
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const ss = try seconds(&a, r.start_ms);
    const len = try seconds(&b, r.end_ms - r.start_ms);
    const res = try proc.output(gpa, &.{ exe.ptr, "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", ss.ptr, "-i", srcz.ptr, "-t", len.ptr, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", "-f", "mp4", dst.ptr }, envp, 1 << 20, 10 * 60_000);
    gpa.free(res.out);
    if (res.status == null or res.status.? != 0) return error.FfmpegFailed;
}

fn cutGif(gpa: std.mem.Allocator, src: []const u8, dst: [:0]const u8, r: Range) !void {
    const data = try sys.readFileAlloc(gpa, src, 512 * 1024 * 1024);
    defer gpa.free(data);
    var d = try gifdec.Decoder.init(gpa, data);
    defer d.deinit();
    const fd = try sys.createWrite(dst);
    defer sys.close(fd);
    var enc = try gif.Encoder.init(gpa, d.width, d.height, .{}, fd);
    defer enc.deinit();
    var last: ?[]u32 = null;
    defer if (last) |l| gpa.free(l);
    while (try d.next()) |f| {
        const end = f.start_ms + f.delay_ms;
        if (end <= r.start_ms) {
            // the picture showing when the cut starts opens it
            if (last == null) last = try gpa.alloc(u32, f.pixels.len);
            @memcpy(last.?, f.pixels);
            continue;
        }
        if (f.start_ms >= r.end_ms) break;
        if (last) |l| {
            if (f.start_ms > r.start_ms) try enc.addFrame(l, d.width, 0);
            gpa.free(l);
            last = null;
        }
        try enc.addFrame(f.pixels, d.width, @max(0, f.start_ms - r.start_ms));
    }
    if (last) |l| try enc.addFrame(l, d.width, 0);
    try enc.finish(r.end_ms - r.start_ms);
}

/// The first picture of an MP4 at `ms`, as 0xFFRRGGBB w x h (ffmpeg).
pub fn frameAt(gpa: std.mem.Allocator, envp: proc.Envp, path: []const u8, ms: i64, w: u32, h: u32) ![]u32 {
    var exe_buf: [512]u8 = undefined;
    const exe = proc.which(&exe_buf, "ffmpeg") orelse return error.NoFfmpeg;
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var a: [32]u8 = undefined;
    const ss = try seconds(&a, ms);
    const res = try proc.output(gpa, &.{ exe.ptr, "-hide_banner", "-nostdin", "-loglevel", "error", "-ss", ss.ptr, "-i", pz.ptr, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgra", "-" }, envp, @as(usize, w) * h * 4 + 1, 30_000);
    errdefer gpa.free(res.out);
    if (res.out.len != @as(usize, w) * h * 4) return error.NoFrame;
    const px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, res.out));
    for (px) |*p| p.* |= 0xFF000000;
    return px;
}

test "trimmed GIFs keep the pictures of the range" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-trim");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    const src = try std.fmt.allocPrint(gpa, "{s}/a.gif", .{dir});
    defer gpa.free(src);
    {
        const fd = try sys.createWrite(src);
        defer sys.close(fd);
        var e = try gif.Encoder.init(gpa, 16, 8, .{}, fd);
        defer e.deinit();
        var px: [16 * 8]u32 = undefined;
        for (0..10) |i| {
            @memset(&px, 0xFF000000 | @as(u32, @intCast(i * 20)) << 8);
            try e.addFrame(&px, 16, @intCast(i * 100));
        }
        try e.finish(1000);
    }
    const dst = try outputPath(gpa, src);
    defer gpa.free(dst);
    try std.testing.expect(std.mem.endsWith(u8, dst, "/a-trim.gif"));
    try cut(gpa, @ptrCast(std.c.environ), src, dst, .{ .start_ms = 250, .end_ms = 650 });
    const data = try sys.readFileAlloc(gpa, dst, 1 << 20);
    defer gpa.free(data);
    const st = try gifdec.stats(gpa, data);
    try std.testing.expectEqual(@as(i64, 400), st.duration_ms);
    try std.testing.expectEqual(@as(u32, 5), st.frames);
}
