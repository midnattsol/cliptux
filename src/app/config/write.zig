//! Writing the config file: given key=value changes are merged into the
//! current file under a directory lock and the result replaces it
//! atomically (a private temp file renamed over it).

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const parse = @import("parse.zig");
const location = @import("location.zig");
const model = @import("model.zig");
const Config = model.Config;

pub const Change = struct { key: []const u8, value: []const u8 };

/// Keys that are no longer used and are dropped when the file is written.
const legacy_keys = [_][]const u8{"screencast_token"};

/// Set `changes` in `dir`'s config file, leaving every other line as it is.
pub fn updateDir(alloc: std.mem.Allocator, dir: []const u8, changes: []const Change) !void {
    sys.mkdirAll(dir, 0o700);
    // serialize writers (shot, settings, daemon) on the directory
    const dfd = try sys.openDir(dir);
    defer sys.close(dfd);
    try sys.lockExclusive(dfd);

    var path_buf: [1024]u8 = undefined;
    const path = try location.configFile(dir, &path_buf);
    const old: []u8 = sys.readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.NotFound => try alloc.dupe(u8, "# shotlet configuration\n"),
        else => return err,
    };
    defer alloc.free(old);

    const content = try mergeContent(alloc, old, changes);
    defer alloc.free(content);
    try replaceFile(dir, path, content);
}

/// Write `content` to a fresh temp file in `dir` and rename it to `path`.
fn replaceFile(dir: []const u8, path: []const u8, content: []const u8) !void {
    var tmp_buf: [1100]u8 = undefined;
    var tmp: []u8 = undefined;
    const fd = try createTemp(dir, &tmp_buf, &tmp);
    {
        errdefer sys.unlink(tmp) catch {};
        defer sys.close(fd);
        try sys.writeAll(fd, content);
        sys.fsync(fd);
    }
    sys.rename(tmp, path) catch |err| {
        sys.unlink(tmp) catch {};
        return err;
    };
}

/// A unique temp file in `dir`, private to the user; O_EXCL so a planted
/// file or symlink is never followed or reused. Its path goes to `tmp`.
fn createTemp(dir: []const u8, tmp_buf: []u8, tmp: *[]u8) !sys.fd_t {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var rnd: [6]u8 = undefined;
        sys.getRandom(&rnd);
        tmp.* = try std.fmt.bufPrint(tmp_buf, "{s}/.config.{d}.{x}.tmp", .{ dir, sys.processId(), std.mem.readInt(u48, &rnd, .little) });
        return sys.createExclusive(tmp.*, 0o600) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 8) continue else return err,
            else => return err,
        };
    }
}

/// Rewrite `old` with `changes` applied: matching lines get the new value
/// (later duplicates are dropped), untouched lines and comments are kept
/// byte for byte, and keys not present yet are appended.
pub fn mergeContent(alloc: std.mem.Allocator, old: []const u8, changes: []const Change) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var done: [64]bool = @splat(false);
    if (changes.len > done.len) return error.TooManyChanges;

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        if (parse.parseLine(line)) |kv| {
            if (isLegacyKey(kv.key) or replaced(kv.key, changes)) continue;
            if (findChange(changes, kv.key)) |ci| {
                if (!done[ci]) {
                    try appendKv(alloc, &out, changes[ci]);
                    done[ci] = true;
                }
                continue;
            }
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    for (changes, 0..) |ch, ci| {
        if (!done[ci] and findChange(changes[0..ci], ch.key) == null) try appendKv(alloc, &out, ch);
    }
    return out.toOwnedSlice(alloc);
}

fn isLegacyKey(key: []const u8) bool {
    for (legacy_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// An older file's `bind_<action>` whose `shortcut_<action>` is being
/// written (config/parse.zig reads the old one only without the new).
fn replaced(key: []const u8, changes: []const Change) bool {
    if (!std.mem.startsWith(u8, key, parse.legacy_prefix)) return false;
    const action = key[parse.legacy_prefix.len..];
    for (changes) |ch| {
        if (std.mem.startsWith(u8, ch.key, model.bind_prefix) and std.mem.eql(u8, ch.key[model.bind_prefix.len..], action)) return true;
    }
    return false;
}

fn findChange(changes: []const Change, key: []const u8) ?usize {
    // the last change for a key wins
    var i = changes.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, changes[i].key, key)) return i;
    }
    return null;
}

/// "key=value\n", with CR/LF dropped from the value.
fn appendKv(alloc: std.mem.Allocator, out: *std.ArrayList(u8), ch: Change) !void {
    try out.appendSlice(alloc, ch.key);
    try out.append(alloc, '=');
    for (ch.value) |c| {
        if (c != '\n' and c != '\r') try out.append(alloc, c);
    }
    try out.append(alloc, '\n');
}

test "merge keeps comments, replaces in place, drops duplicates" {
    const alloc = std.testing.allocator;
    const out = try mergeContent(alloc, "# c\nnotify=true\nx=1\nnotify=false\n", &.{
        .{ .key = "notify", .value = "false" },
        .{ .key = "save_dir", .value = "/a\nb" },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("# c\nnotify=false\nx=1\nsave_dir=/ab\n", out);
}

test "single-monitor restore tokens are dropped" {
    const alloc = std.testing.allocator;
    const out = try mergeContent(alloc, "screencast_token=old\nnotify=true\n", &.{
        .{ .key = "screencast_restore_token", .value = "new" },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("notify=true\nscreencast_restore_token=new\n", out);
    var cfg = Config{};
    parse.applyValue(&cfg, "screencast_token", "old");
    try std.testing.expect(cfg.scToken() == null);
}

test "a bind written anew drops the older file's line for it" {
    const alloc = std.testing.allocator;
    const out = try mergeContent(alloc, "bind_pen=33\nbind_line=38\nnotify=true\n", &.{
        .{ .key = "shortcut_pen", .value = "Ctrl+F" },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("bind_line=38\nnotify=true\nshortcut_pen=Ctrl+F\n", out);
}
