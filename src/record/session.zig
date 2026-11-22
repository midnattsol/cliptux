//! One recording from its source to the kept file: open the source,
//! start the engine into a new file in the Videos folder, then stop
//! (keeping it in the history, with the thumbnail) or discard it.

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("../app/env.zig");
const config = @import("../app/config.zig");
const keep = @import("../app/keep.zig");
const shot = @import("../app/shot.zig");
const sys = @import("../platform/api.zig").sys;
const ffmpeg = @import("../encode/ffmpeg_proc.zig");
const proc = @import("../platform/api.zig").proc;
const engine_mod = @import("engine.zig");
const source_mod = @import("../platform/linux/record/source.zig");
const settings_mod = @import("settings.zig");
const keepvid = @import("keepvid.zig");
const region = @import("region.zig");
const Env = env_mod.Env;

pub const Request = struct {
    area: region.Rect,
    /// write here instead of a new file in the Videos folder
    out: ?[]const u8 = null,
};

pub const Recording = struct {
    gpa: std.mem.Allocator,
    env: Env,
    bus: *desktop.Session,
    set: settings_mod.Settings,
    source: source_mod.Source,
    engine: *engine_mod.Engine,
    path: [:0]u8,

    pub const Begin = union(enum) { ok: Recording, cancelled, failed: anyerror };

    pub fn begin(gpa: std.mem.Allocator, env: Env, bus: *desktop.Session, cfg: *config.Config, set: settings_mod.Settings, req: Request) Begin {
        var src = switch (source_mod.open(gpa, bus, env.home, cfg, .{ .area = req.area, .clicks = set.clicks, .keys = set.keys })) {
            .ok => |s| s,
            .cancelled => return .cancelled,
            .failed => |e| return .{ .failed = e },
        };
        const path = outputPath(gpa, env, &set, req.out) catch |e| {
            src.close(gpa, bus);
            return .{ .failed = e };
        };
        const vaapi = if (set.format == .mp4) ffmpeg.probeVaapi(gpa, envp(env)) else null;
        const eng = engine_mod.Engine.start(gpa, envp(env), src.cap, src.node, path, .{
            .format = set.format,
            .fps = set.rate(),
            .quality = set.quality,
            .mic = set.mic,
            .system = set.system_audio,
            .gif_max_width = set.gif_width,
            .dither = set.dither,
            .vaapi = vaapi,
            .crop = src.crop,
            .stream_rect = src.stream_rect,
        }) catch |e| {
            src.close(gpa, bus);
            sys.unlink(path) catch {};
            gpa.free(path);
            return .{ .failed = e };
        };
        std.log.info("recording: {s} into {s}", .{ src.label(), path });
        return .{ .ok = .{ .gpa = gpa, .env = env, .bus = bus, .set = set, .source = src, .engine = eng, .path = path } };
    }

    fn envp(env: Env) proc.Envp {
        return @ptrCast(env.envp);
    }

    /// Finish the file and keep it; the kept entry (for the thumbnail).
    pub fn finish(self: *Recording, cfg: *const config.Config) !?keep.Kept {
        defer self.release();
        const done = try self.engine.stop();
        const size = sys.fileSize(self.path) catch 0;
        std.log.info("recording: saved {s} ({d}x{d}, {d} frames, {d} ms, {d} KiB, {s})", .{ self.path, done.width, done.height, done.frames, done.duration_ms, size / 1024, done.backend.label() });
        var lbuf: [2048]u8 = undefined;
        return keepvid.store(self.gpa, self.env, cfg, .{
            .info = .{
                .path = self.path,
                .format = self.set.format,
                .duration_ms = done.duration_ms,
                .frames = done.frames,
                .fps = self.set.rate(),
                .width = done.width,
                .height = done.height,
                .strip = self.engine.strip.indexList(&lbuf),
            },
            .first = done.first,
            .first_w = done.src_w,
            .first_h = done.src_h,
            .strip = &self.engine.strip,
        });
    }

    pub fn discard(self: *Recording) void {
        self.engine.discard();
        std.log.info("recording: discarded", .{});
        self.release();
    }

    fn release(self: *Recording) void {
        self.source.close(self.gpa, self.bus);
        self.engine.deinit();
        self.gpa.free(self.path);
    }
};

/// A new file in the Videos folder: shotlet-YYYYMMDD-HHMMSS.mp4 (never
/// over an existing one), or the path asked for.
fn outputPath(gpa: std.mem.Allocator, env: Env, set: *const settings_mod.Settings, out: ?[]const u8) ![:0]u8 {
    if (out) |o| return gpa.dupeSentinel(u8, o, 0);
    var dir_buf: [1024]u8 = undefined;
    const dir = try settings_mod.outputDir(gpa, set, env.home, &dir_buf);
    sys.mkdirAll(dir, 0o755);
    var name_buf: [64]u8 = undefined;
    const base = try shot.baseName(gpa, env, &name_buf);
    const ext: []const u8 = if (set.format == .gif) ".gif" else ".mp4";
    // reserve the name (the encoder then writes over the empty file)
    const p = try shot.writeUnique(gpa, dir, base, ext, "");
    defer gpa.free(p);
    return gpa.dupeSentinel(u8, p, 0);
}
