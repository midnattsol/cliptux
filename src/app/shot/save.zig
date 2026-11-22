//! Saving a capture: the screenshots folder, unique names that never
//! overwrite, and Save As through the FileChooser portal.

const std = @import("std");
const clock = @import("../clock.zig");
const config = @import("../config.zig");
const dbus = @import("../../platform/linux/dbus.zig");
const env_mod = @import("../env.zig");
const portal = @import("../../platform/linux/portal.zig");
const sys = @import("../../platform/api.zig").sys;
const Env = env_mod.Env;

/// Where screenshots go: the configured save_dir (with ~ expanded), else the
/// user's XDG Pictures directory.
fn saveDir(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, buf: []u8) ![]u8 {
    if (cfg.saveDir()) |d| return env_mod.expandHome(buf, env.home, d);
    return env_mod.picturesDir(gpa, buf, env.home);
}

/// "shotlet-20260701-140501" in local time.
pub fn baseName(gpa: std.mem.Allocator, env: Env, buf: []u8) ![]u8 {
    const lt = clock.localTime(gpa, env.tz, sys.realtimeSec());
    return std.fmt.bufPrint(buf, "shotlet-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second,
    });
}

/// Save into the screenshots folder. Returns the path written (owned).
pub fn savePng(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, data: []const u8) ![]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try saveDir(gpa, env, cfg, &dir_buf);
    sys.mkdirAll(dir, 0o755); // best effort; may already exist
    var name_buf: [64]u8 = undefined;
    return writeUnique(gpa, dir, try baseName(gpa, env, &name_buf), ".png", data);
}

/// Write `<dir>/<base><ext>`, or `<base>-2<ext>`, `-3`, ... when taken.
/// Never overwrites: each attempt is an O_EXCL create.
pub fn writeUnique(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, data: []const u8) ![]u8 {
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const path = if (n == 1)
            try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, base, ext })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}-{d}{s}", .{ dir, base, n, ext });
        errdefer gpa.free(path);
        sys.writeFileExclusive(path, data, 0o644) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.TooManyCollisions;
}

/// Ask where to save with the FileChooser portal. Null when the person
/// cancelled (nothing is written). Falls back to the screenshots folder
/// when there is no FileChooser portal.
pub fn saveAs(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *const config.Config, data: []const u8) !?[]u8 {
    return saveAsWith(gpa, env, conn, cfg, data, Blocking{ .gpa = gpa, .conn = conn });
}

/// saveAs, with `waiter` waiting for the answer: its `parent_window`
/// ("wayland:HANDLE" or "") is the window the dialog belongs to, its
/// `wait(*portal.Request)` returns once the request is done.
pub fn saveAsWith(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *const config.Config, data: []const u8, waiter: anytype) !?[]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try saveDir(gpa, env, cfg, &dir_buf);
    sys.mkdirAll(dir, 0o755);
    var name_buf: [64]u8 = undefined;
    const base = try baseName(gpa, env, &name_buf);
    var file_buf: [80]u8 = undefined;
    const current_name = try std.fmt.bufPrint(&file_buf, "{s}.png", .{base});

    var req = try portal.beginSaveFile(gpa, conn, .{ .current_name = current_name, .current_folder = dir, .parent_window = waiter.parent_window });
    defer req.deinit(gpa);
    try waiter.wait(&req);
    const path = switch (try portal.savedPath(gpa, &req)) {
        .granted => |p| p,
        .cancelled, .denied, .timeout => return null,
        .unavailable => {
            std.log.warn("no file chooser portal; saving to {s}", .{dir});
            return try savePng(gpa, env, cfg, data);
        },
    };
    return try writeChosen(gpa, path, data);
}

/// Waits for the dialog with nothing else to do.
const Blocking = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    parent_window: []const u8 = "",

    pub fn wait(self: Blocking, req: *portal.Request) !void {
        try req.wait(self.gpa, self.conn, portal.timeout_file_chooser_ms);
    }
};

/// Write `data` where the chooser said (`path` is consumed); returns the
/// path written (owned).
fn writeChosen(gpa: std.mem.Allocator, path: []u8, data: []const u8) ![]u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".png")) {
        // the chooser already confirmed replacing an existing file
        sys.writeFile(path, data) catch |err| {
            gpa.free(path);
            return err;
        };
        return path;
    }
    // a name typed without extension: add one, but never replace a file
    // the chooser did not ask about
    defer gpa.free(path);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadPath;
    return try writeUnique(gpa, path[0..slash], path[slash + 1 ..], ".png", data);
}

/// What the editor says when a save failed: the file was not written,
/// the capture is still open.
pub fn failureText(buf: []u8, err: anyerror) []const u8 {
    const why = switch (err) {
        error.AccessDenied => "no permission to write there",
        error.ReadOnlyFileSystem => "the disk is read-only",
        error.NoSpaceLeft, error.DiskQuota => "the disk is full",
        error.NotFound, error.NotDir => "the folder does not exist",
        error.NameTooLong, error.BadPath => "the path is too long or invalid",
        else => @errorName(err),
    };
    return std.fmt.bufPrint(buf, "Not saved: {s}", .{why}) catch "Not saved";
}

test "a failed save says why in words" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Not saved: the disk is full", failureText(&buf, error.NoSpaceLeft));
    try std.testing.expectEqualStrings("Not saved: Unexpected", failureText(&buf, error.Unexpected));
}

test "saved names never overwrite" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-test");
    defer gpa.free(dir);
    defer sys.removeTree(dir);

    const a = try writeUnique(gpa, dir, "shot", ".png", "one");
    defer gpa.free(a);
    const b = try writeUnique(gpa, dir, "shot", ".png", "two");
    defer gpa.free(b);
    const c = try writeUnique(gpa, dir, "shot", ".png", "three");
    defer gpa.free(c);
    try std.testing.expect(std.mem.endsWith(u8, a, "/shot.png"));
    try std.testing.expect(std.mem.endsWith(u8, b, "/shot-2.png"));
    try std.testing.expect(std.mem.endsWith(u8, c, "/shot-3.png"));
    const first = try sys.readFileAlloc(gpa, a, 64);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("one", first);

    // a symlink in the way is not followed
    var link_buf: [512]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/l.png", .{dir});
    try sys.symlink("/nonexistent-target", link);
    const d = try writeUnique(gpa, dir, "l", ".png", "x");
    defer gpa.free(d);
    try std.testing.expect(std.mem.endsWith(u8, d, "/l-2.png"));
}
