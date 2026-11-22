//! Recording settings: `record_*` keys in the same settings file as the
//! rest (config.zig ignores keys it does not know, and config.update
//! rewrites only the keys it is given).
//!
//!     record_format=mp4|gif       record_fps=30 (MP4: 15..60)
//!     record_quality=low|medium|high
//!     record_mic=false            record_system_audio=false
//!     record_clicks=false         record_keys=false   (GNOME)
//!     record_countdown=3          (seconds, 0: none)
//!     record_gif_fps=15 (10..30)  record_gif_width=800 (0: full size)
//!     record_gif_dither=ordered|floyd|none
//!     record_dir=                 (default: the Videos folder)

const std = @import("std");
const config = @import("../app/config.zig");
const env_mod = @import("../app/env.zig");
const sys = @import("../platform/api.zig").sys;
const sink = @import("../encode/sink.zig");
const quantize = @import("../encode/quantize.zig");

pub const Settings = struct {
    format: sink.Format = .mp4,
    fps: u32 = 30,
    quality: sink.Quality = .medium,
    mic: bool = false,
    system_audio: bool = false,
    clicks: bool = false,
    keys: bool = false,
    countdown: u32 = 3,
    gif_fps: u32 = 15,
    gif_width: u32 = 800,
    dither: quantize.Dither = .ordered,
    dir_buf: [512]u8 = undefined,
    dir_len: usize = 0,

    pub fn dir(self: *const Settings) ?[]const u8 {
        return if (self.dir_len > 0) self.dir_buf[0..self.dir_len] else null;
    }

    /// The frame rate for the chosen format.
    pub fn rate(self: *const Settings) u32 {
        return if (self.format == .gif) self.gif_fps else self.fps;
    }

    pub fn apply(self: *Settings, key: []const u8, v: []const u8) void {
        const eq = std.mem.eql;
        if (eq(u8, key, "record_format")) {
            self.format = std.meta.stringToEnum(sink.Format, v) orelse self.format;
        } else if (eq(u8, key, "record_fps")) {
            self.fps = std.math.clamp(std.fmt.parseInt(u32, v, 10) catch self.fps, 15, 60);
        } else if (eq(u8, key, "record_quality")) {
            self.quality = std.meta.stringToEnum(sink.Quality, v) orelse self.quality;
        } else if (eq(u8, key, "record_mic")) {
            self.mic = eq(u8, v, "true");
        } else if (eq(u8, key, "record_system_audio")) {
            self.system_audio = eq(u8, v, "true");
        } else if (eq(u8, key, "record_clicks")) {
            self.clicks = eq(u8, v, "true");
        } else if (eq(u8, key, "record_keys")) {
            self.keys = eq(u8, v, "true");
        } else if (eq(u8, key, "record_countdown")) {
            self.countdown = @min(std.fmt.parseInt(u32, v, 10) catch self.countdown, 10);
        } else if (eq(u8, key, "record_gif_fps")) {
            self.gif_fps = std.math.clamp(std.fmt.parseInt(u32, v, 10) catch self.gif_fps, 10, 30);
        } else if (eq(u8, key, "record_gif_width")) {
            self.gif_width = @min(std.fmt.parseInt(u32, v, 10) catch self.gif_width, 8192);
        } else if (eq(u8, key, "record_gif_dither")) {
            self.dither = std.meta.stringToEnum(quantize.Dither, v) orelse self.dither;
        } else if (eq(u8, key, "record_dir")) {
            self.dir_len = @min(v.len, self.dir_buf.len);
            @memcpy(self.dir_buf[0..self.dir_len], v[0..self.dir_len]);
        }
    }

    pub fn parse(data: []const u8) Settings {
        var s: Settings = .{};
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            s.apply(std.mem.trim(u8, line[0..eq], " \t"), std.mem.trim(u8, line[eq + 1 ..], " \t"));
        }
        return s;
    }
};

pub fn load(gpa: std.mem.Allocator, home: []const u8) Settings {
    var dir_buf: [1024]u8 = undefined;
    const dir = env_mod.configDir(&dir_buf, home) catch return .{};
    var path_buf: [1100]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/config", .{dir}) catch return .{};
    const data = sys.readFileAlloc(gpa, path, 64 * 1024) catch return .{};
    defer gpa.free(data);
    return Settings.parse(data);
}

/// Store one setting (the others in the file stay as they are).
pub fn save(gpa: std.mem.Allocator, home: []const u8, key: []const u8, value: []const u8) void {
    config.update(gpa, home, &.{.{ .key = key, .value = value }}) catch |err|
        std.log.warn("could not save {s}: {t}", .{ key, err });
}

/// Where recordings go: record_dir, else the Videos folder
/// (XDG_VIDEOS_DIR in user-dirs.dirs), else ~/Videos.
pub fn outputDir(gpa: std.mem.Allocator, s: *const Settings, home: []const u8, buf: []u8) ![]u8 {
    if (s.dir()) |d| return env_mod.expandHome(buf, home, d);
    var cfg_buf: [1024]u8 = undefined;
    var path_buf: [1100]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/user-dirs.dirs", .{try env_mod.configHome(&cfg_buf, home)});
    if (sys.readFileAlloc(gpa, path, 64 * 1024)) |data| {
        defer gpa.free(data);
        if (env_mod.parseUserDir(data, "XDG_VIDEOS_DIR", home, buf)) |p| return p;
    } else |_| {}
    return std.fmt.bufPrint(buf, "{s}/Videos", .{home});
}

test "recording settings parse with limits" {
    const s = Settings.parse("save_dir=~/x\nrecord_format=gif\nrecord_fps=120\nrecord_gif_fps=5\nrecord_mic=true\nrecord_quality=high\nrecord_gif_dither=floyd\nrecord_countdown=0\n# record_keys=true\n");
    try std.testing.expectEqual(sink.Format.gif, s.format);
    try std.testing.expectEqual(@as(u32, 60), s.fps);
    try std.testing.expectEqual(@as(u32, 10), s.gif_fps);
    try std.testing.expectEqual(@as(u32, 10), s.rate());
    try std.testing.expect(s.mic and !s.keys);
    try std.testing.expectEqual(sink.Quality.high, s.quality);
    try std.testing.expectEqual(quantize.Dither.floyd, s.dither);
    try std.testing.expectEqual(@as(u32, 0), s.countdown);
    const d = Settings.parse("record_format=webm\n");
    try std.testing.expectEqual(sink.Format.mp4, d.format);
}
