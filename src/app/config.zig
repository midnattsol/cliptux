//! Persistent configuration: simple key=value file at
//! $XDG_CONFIG_HOME/shotlet/config (~/.config/shotlet/config), private to
//! the user (0600). Writes merge: the file is re-read under a lock and only
//! the keys the caller changed are replaced, so two processes (the editor
//! storing a ScreenCast token, the Settings window) never undo each other.

const std = @import("std");
const sys = @import("../platform/sys.zig");
const env = @import("env.zig");

// editor actions, their key bindings and key names (binds.zig)
const binds = @import("binds.zig");
pub const Action = binds.Action;
pub const n_actions = binds.n_actions;
pub const Bind = binds.Bind;
pub const default_binds = binds.default_binds;
pub const keyCodeName = binds.keyCodeName;
pub const bindName = binds.bindName;

pub const Config = struct {
    /// desktop notification after saving
    notify: bool = true,
    /// also copy to clipboard when saving to disk
    copy_on_save: bool = false,
    /// default stroke thickness (logical px, scaled by the UI)
    default_thickness: i32 = 3,
    /// default palette color index
    default_color: u3 = 0,
    /// override save directory; empty = XDG pictures dir
    save_dir: [256]u8 = @splat(0),
    save_dir_len: usize = 0,
    /// editor keybindings, indexed by Action
    binds: [n_actions]Bind = default_binds,
    /// ScreenCast restore token (silent re-capture after first consent)
    sc_token: [512]u8 = @splat(0),
    sc_token_len: usize = 0,
    /// editor "beautify" frame, remembered across runs
    beautify: bool = false,
    beautify_background: u8 = 0,
    /// 0 none, 1 small, 2 medium, 3 large
    beautify_padding: u2 = 2,
    beautify_corners: bool = true,
    beautify_shadow: bool = true,
    /// the editor's first-run hint was shown
    hint_shown: bool = false,
    /// after Copy/Save, a floating thumbnail with more actions
    quick_access: bool = true,
    /// how long the thumbnail stays (it stays while hovered)
    quick_access_seconds: u16 = 8,
    /// keep copied and saved captures in $XDG_STATE_HOME/shotlet/history
    history: bool = true,
    /// at most this many captures...
    history_max: u16 = 50,
    /// ...taking at most this many MiB
    history_max_mb: u32 = 500,
    /// hash of every key's value as last loaded or saved; save() writes
    /// only keys whose value differs. All zero (a Config not read from
    /// disk) means every key is written.
    base: [n_keys]u64 = @splat(0),

    pub fn saveDir(self: *const Config) ?[]const u8 {
        if (self.save_dir_len == 0) return null;
        return self.save_dir[0..self.save_dir_len];
    }

    pub fn scToken(self: *const Config) ?[]const u8 {
        if (self.sc_token_len == 0) return null;
        return self.sc_token[0..self.sc_token_len];
    }

    pub fn setScToken(self: *Config, token: []const u8) void {
        const n = @min(token.len, self.sc_token.len);
        @memcpy(self.sc_token[0..n], token[0..n]);
        self.sc_token_len = n;
    }
};

// --- keys ---

const n_fixed_keys = 17;
pub const n_keys = n_fixed_keys + n_actions;

const fixed_key_names = [n_fixed_keys][]const u8{
    "notify",
    "copy_on_save",
    "default_thickness",
    "default_color",
    "save_dir",
    // tokens from before multi-monitor capture ("screencast_token") restore
    // a single-monitor selection forever, so they are not read any more
    "screencast_restore_token",
    "beautify",
    "beautify_background",
    "beautify_padding",
    "beautify_corners",
    "beautify_shadow",
    "hint_shown",
    "quick_access",
    "quick_access_seconds",
    "history",
    "history_max",
    "history_max_mb",
};

pub const padding_names = [4][]const u8{ "none", "small", "medium", "large" };

/// Keys that are no longer used and are dropped when the file is written.
const legacy_keys = [_][]const u8{"screencast_token"};

/// Name of key `k` ("notify", ..., "bind_pen", ...).
fn keyName(k: usize, buf: []u8) []const u8 {
    if (k < n_fixed_keys) return fixed_key_names[k];
    const names = comptime @typeInfo(Action).@"enum".field_names;
    inline for (names, 0..) |fld_name, i| {
        if (k - n_fixed_keys == i) return "bind_" ++ fld_name;
    }
    _ = buf;
    unreachable;
}

fn keyIndex(name: []const u8) ?usize {
    var buf: [32]u8 = undefined;
    for (0..n_keys) |k| {
        if (std.mem.eql(u8, keyName(k, &buf), name)) return k;
    }
    return null;
}

/// Serialized value of key `k` in `cfg`.
fn formatValue(cfg: *const Config, k: usize, buf: []u8) []const u8 {
    return switch (k) {
        0 => if (cfg.notify) "true" else "false",
        1 => if (cfg.copy_on_save) "true" else "false",
        2 => std.fmt.bufPrint(buf, "{d}", .{cfg.default_thickness}) catch unreachable,
        3 => std.fmt.bufPrint(buf, "{d}", .{cfg.default_color}) catch unreachable,
        4 => cfg.saveDir() orelse "",
        5 => cfg.scToken() orelse "",
        6 => if (cfg.beautify) "true" else "false",
        7 => std.fmt.bufPrint(buf, "{d}", .{cfg.beautify_background}) catch unreachable,
        8 => padding_names[cfg.beautify_padding],
        9 => if (cfg.beautify_corners) "true" else "false",
        10 => if (cfg.beautify_shadow) "true" else "false",
        11 => if (cfg.hint_shown) "true" else "false",
        12 => if (cfg.quick_access) "true" else "false",
        13 => std.fmt.bufPrint(buf, "{d}", .{cfg.quick_access_seconds}) catch unreachable,
        14 => if (cfg.history) "true" else "false",
        15 => std.fmt.bufPrint(buf, "{d}", .{cfg.history_max}) catch unreachable,
        16 => std.fmt.bufPrint(buf, "{d}", .{cfg.history_max_mb}) catch unreachable,
        else => blk: {
            const b = cfg.binds[k - n_fixed_keys];
            break :blk std.fmt.bufPrint(buf, "{s}{s}{d}", .{
                if (b.ctrl) "ctrl+" else "",
                if (b.shift) "shift+" else "",
                b.code,
            }) catch unreachable;
        },
    };
}

/// Apply one key=value pair to `cfg` (unknown keys are ignored).
fn applyValue(cfg: *Config, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "notify")) {
        cfg.notify = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "copy_on_save")) {
        cfg.copy_on_save = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "default_thickness")) {
        cfg.default_thickness = std.fmt.parseInt(i32, value, 10) catch cfg.default_thickness;
        cfg.default_thickness = std.math.clamp(cfg.default_thickness, 1, 32);
    } else if (std.mem.eql(u8, key, "default_color")) {
        const v = std.fmt.parseInt(u8, value, 10) catch 0;
        cfg.default_color = @intCast(@min(v, 7));
    } else if (std.mem.eql(u8, key, "save_dir")) {
        const n = @min(value.len, cfg.save_dir.len);
        @memcpy(cfg.save_dir[0..n], value[0..n]);
        cfg.save_dir_len = n;
    } else if (std.mem.eql(u8, key, "screencast_restore_token")) {
        cfg.setScToken(value);
    } else if (std.mem.eql(u8, key, "beautify")) {
        cfg.beautify = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "beautify_background")) {
        cfg.beautify_background = std.fmt.parseInt(u8, value, 10) catch 0;
    } else if (std.mem.eql(u8, key, "beautify_padding")) {
        for (padding_names, 0..) |n, i| {
            if (std.mem.eql(u8, value, n)) cfg.beautify_padding = @intCast(i);
        }
    } else if (std.mem.eql(u8, key, "beautify_corners")) {
        cfg.beautify_corners = !std.mem.eql(u8, value, "false");
    } else if (std.mem.eql(u8, key, "beautify_shadow")) {
        cfg.beautify_shadow = !std.mem.eql(u8, value, "false");
    } else if (std.mem.eql(u8, key, "hint_shown")) {
        cfg.hint_shown = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "quick_access")) {
        cfg.quick_access = !std.mem.eql(u8, value, "false");
    } else if (std.mem.eql(u8, key, "quick_access_seconds")) {
        const v = std.fmt.parseInt(u16, value, 10) catch cfg.quick_access_seconds;
        cfg.quick_access_seconds = std.math.clamp(v, 1, 3600);
    } else if (std.mem.eql(u8, key, "history")) {
        cfg.history = !std.mem.eql(u8, value, "false");
    } else if (std.mem.eql(u8, key, "history_max")) {
        cfg.history_max = std.math.clamp(std.fmt.parseInt(u16, value, 10) catch cfg.history_max, 1, 10000);
    } else if (std.mem.eql(u8, key, "history_max_mb")) {
        cfg.history_max_mb = std.math.clamp(std.fmt.parseInt(u32, value, 10) catch cfg.history_max_mb, 1, 1 << 20);
    } else if (std.mem.startsWith(u8, key, "bind_")) {
        const name = key["bind_".len..];
        inline for (@typeInfo(Action).@"enum".field_names, 0..) |fld_name, i| {
            if (std.mem.eql(u8, name, fld_name)) {
                cfg.binds[i] = parseBind(value);
            }
        }
    }
}

fn valueHash(v: []const u8) u64 {
    // never 0, so an all-zero `base` unambiguously means "nothing loaded"
    return std.hash.Wyhash.hash(0x5107, v) | 1;
}

fn rememberBase(cfg: *Config) void {
    var buf: [64]u8 = undefined;
    for (0..n_keys) |k| cfg.base[k] = valueHash(formatValue(cfg, k, &buf));
}

// --- locations ---

fn configFile(dir: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/config", .{dir});
}

/// Shotlet was called cliptux. Carry an old cliptux config directory (in
/// $XDG_CONFIG_HOME or ~/.config) over to the new place once, so settings,
/// shortcuts and the screencast token survive the rename. Never overwrites
/// an existing Shotlet configuration.
fn migrateLegacy(home: []const u8, new_dir: []const u8) void {
    var new_buf: [1024]u8 = undefined;
    const new_cfg = configFile(new_dir, &new_buf) catch return;
    if (sys.fileSize(new_cfg)) |_| return else |_| {}

    var cands: [2][1024]u8 = undefined;
    var olds: [2][]const u8 = undefined;
    var n: usize = 0;
    if (env.xdg.config_home) |ch| {
        olds[n] = std.fmt.bufPrint(&cands[n], "{s}/cliptux", .{ch}) catch return;
        n += 1;
    }
    olds[n] = std.fmt.bufPrint(&cands[n], "{s}/.config/cliptux", .{home}) catch return;
    n += 1;
    migrateFrom(olds[0..n], new_dir);
}

fn migrateFrom(olds: []const []const u8, new_dir: []const u8) void {
    var new_buf: [1024]u8 = undefined;
    const new_cfg = configFile(new_dir, &new_buf) catch return;
    for (olds) |old_dir| {
        var old_buf: [1024]u8 = undefined;
        const old_cfg = configFile(old_dir, &old_buf) catch continue;
        if (sys.fileSize(old_cfg)) |_| {} else |_| continue;
        if (std.fs.path.dirname(new_dir)) |parent| sys.mkdirAll(parent, 0o700);
        // a rename keeps everything; it fails when the new directory already
        // exists with files, or across filesystems; then copy the file alone
        if (sys.rename(old_dir, new_dir)) |_| {
            std.log.info("moved settings from {s} to {s}", .{ old_dir, new_dir });
            return;
        } else |_| {}
        var arena_buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
        const data = sys.readFileAlloc(fba.allocator(), old_cfg, arena_buf.len) catch continue;
        sys.mkdirAll(new_dir, 0o700);
        sys.writeFileExclusive(new_cfg, data, 0o600) catch continue;
        std.log.info("copied settings from {s} to {s}", .{ old_cfg, new_cfg });
        return;
    }
}

// --- load ---

pub fn load(alloc: std.mem.Allocator, home: []const u8) Config {
    var dir_buf: [1024]u8 = undefined;
    const dir = env.configDir(&dir_buf, home) catch return .{};
    migrateLegacy(home, dir);
    return loadDir(alloc, dir);
}

fn loadDir(alloc: std.mem.Allocator, dir: []const u8) Config {
    var cfg = Config{};
    readInto(alloc, dir, &cfg);
    // missing keys get their defaults as baseline: unchanged, never written
    rememberBase(&cfg);
    return cfg;
}

fn readInto(alloc: std.mem.Allocator, dir: []const u8, cfg: *Config) void {
    var path_buf: [1024]u8 = undefined;
    const path = configFile(dir, &path_buf) catch return;
    const data = sys.readFileAlloc(alloc, path, 64 * 1024) catch return;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const kv = parseLine(line) orelse continue;
        applyValue(cfg, kv.key, kv.value);
    }
}

fn parseLine(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], " \t"),
        .value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t"),
    };
}

fn parseBind(value: []const u8) Bind {
    var b = Bind{};
    var rest = value;
    while (true) {
        if (std.mem.startsWith(u8, rest, "ctrl+")) {
            b.ctrl = true;
            rest = rest["ctrl+".len..];
        } else if (std.mem.startsWith(u8, rest, "shift+")) {
            b.shift = true;
            rest = rest["shift+".len..];
        } else break;
    }
    b.code = std.fmt.parseInt(u32, rest, 10) catch 0;
    return b;
}

// --- save ---

pub const Change = struct { key: []const u8, value: []const u8 };

/// Persist the keys of `cfg` that changed since it was loaded (or saved),
/// merged into the current file: keys changed meanwhile by another process
/// are kept. A Config that was never loaded writes every key.
pub fn save(alloc: std.mem.Allocator, home: []const u8, cfg: *Config) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir = try env.configDir(&dir_buf, home);
    try saveDir(alloc, dir, cfg);
}

fn saveDir(alloc: std.mem.Allocator, dir: []const u8, cfg: *Config) !void {
    const fresh = std.mem.allEqual(u64, &cfg.base, 0);
    var changes: [n_keys]Change = undefined;
    var vbufs: [n_keys][64]u8 = undefined;
    var kbufs: [n_keys][32]u8 = undefined;
    var n: usize = 0;
    for (0..n_keys) |k| {
        const v = formatValue(cfg, k, &vbufs[k]);
        if (!fresh and valueHash(v) == cfg.base[k]) continue;
        changes[n] = .{ .key = keyName(k, &kbufs[k]), .value = v };
        n += 1;
    }
    if (n > 0) try updateDir(alloc, dir, changes[0..n]);
    rememberBase(cfg);
}

/// Set the given keys in the config file, leaving every other line as it
/// is. Values must be single-line; CR/LF are dropped.
pub fn update(alloc: std.mem.Allocator, home: []const u8, changes: []const Change) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir = try env.configDir(&dir_buf, home);
    try updateDir(alloc, dir, changes);
}

/// Persist a new ScreenCast restore token without touching other settings.
pub fn saveScreencastToken(alloc: std.mem.Allocator, home: []const u8, token: []const u8) !void {
    try update(alloc, home, &.{.{ .key = "screencast_restore_token", .value = token }});
}

fn updateDir(alloc: std.mem.Allocator, dir: []const u8, changes: []const Change) !void {
    sys.mkdirAll(dir, 0o700);
    // serialize writers (shot, settings, daemon) on the directory
    const dfd = try sys.openDir(dir);
    defer sys.close(dfd);
    try sys.lockExclusive(dfd);

    var path_buf: [1024]u8 = undefined;
    const path = try configFile(dir, &path_buf);
    const old: []u8 = sys.readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.NotFound => try alloc.dupe(u8, "# shotlet configuration\n"),
        else => return err,
    };
    defer alloc.free(old);

    const content = try mergeContent(alloc, old, changes);
    defer alloc.free(content);

    // unique temp name; O_EXCL so a planted file or symlink is never
    // followed or reused
    var tmp_buf: [1100]u8 = undefined;
    var fd: sys.fd_t = -1;
    var tmp: []u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var rnd: [6]u8 = undefined;
        sys.getRandom(&rnd);
        tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/.config.{d}.{x}.tmp", .{ dir, std.os.linux.getpid(), std.mem.readInt(u48, &rnd, .little) });
        fd = sys.createExclusive(tmp, 0o600) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 8) continue else return err,
            else => return err,
        };
        break;
    }
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

/// Rewrite `old` with `changes` applied: matching lines get the new value
/// (later duplicates are dropped), untouched lines and comments are kept
/// byte for byte, and keys not present yet are appended.
fn mergeContent(alloc: std.mem.Allocator, old: []const u8, changes: []const Change) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var done: [64]bool = @splat(false);
    if (changes.len > done.len) return error.TooManyChanges;

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        if (parseLine(line)) |kv| {
            if (isLegacyKey(kv.key)) continue;
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

fn findChange(changes: []const Change, key: []const u8) ?usize {
    // the last change for a key wins
    var i = changes.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, changes[i].key, key)) return i;
    }
    return null;
}

fn appendKv(alloc: std.mem.Allocator, out: *std.ArrayList(u8), ch: Change) !void {
    try out.appendSlice(alloc, ch.key);
    try out.append(alloc, '=');
    for (ch.value) |c| {
        if (c != '\n' and c != '\r') try out.append(alloc, c);
    }
    try out.append(alloc, '\n');
}

test "bind parse and format roundtrip" {
    const b = parseBind("ctrl+shift+44");
    try std.testing.expect(b.ctrl and b.shift and b.code == 44);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", bindName(b, &buf));
    try std.testing.expectEqualStrings("unset", bindName(.{}, &buf));
    const plain = parseBind("25");
    try std.testing.expect(!plain.ctrl and plain.code == 25);
    // malformed input degrades to unbound, never crashes
    try std.testing.expect(parseBind("ctrl+banana").code == 0);
    try std.testing.expect(parseBind("").code == 0);
}

fn testDir() ![]u8 {
    return sys.makeTempDir(std.testing.allocator, "/tmp", "shotlet-test");
}

test "config save/load roundtrip" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/shotlet", .{root});

    var cfg = Config{};
    cfg.notify = false;
    cfg.copy_on_save = true;
    cfg.default_thickness = 9;
    cfg.default_color = 5;
    cfg.binds[@backingInt(Action.pen)] = .{ .code = 33, .ctrl = true };
    cfg.setScToken("tok-123");
    cfg.quick_access = false;
    cfg.quick_access_seconds = 12;
    cfg.history = false;
    cfg.history_max = 7;
    cfg.history_max_mb = 64;
    try saveDir(alloc, dir, &cfg);

    const loaded = loadDir(alloc, dir);
    try std.testing.expectEqual(false, loaded.notify);
    try std.testing.expectEqual(true, loaded.copy_on_save);
    try std.testing.expectEqual(@as(i32, 9), loaded.default_thickness);
    try std.testing.expectEqual(@as(u3, 5), loaded.default_color);
    try std.testing.expect(loaded.binds[@backingInt(Action.pen)].matches(33, true, false));
    try std.testing.expectEqualStrings("tok-123", loaded.scToken().?);
    try std.testing.expectEqual(false, loaded.quick_access);
    try std.testing.expectEqual(@as(u16, 12), loaded.quick_access_seconds);
    try std.testing.expectEqual(false, loaded.history);
    try std.testing.expectEqual(@as(u16, 7), loaded.history_max);
    try std.testing.expectEqual(@as(u32, 64), loaded.history_max_mb);

    // private to the user
    var path_buf: [600]u8 = undefined;
    const path = try configFile(dir, &path_buf);
    var stx: std.os.linux.Statx = undefined;
    var pz: [600:0]u8 = @splat(0);
    @memcpy(pz[0..path.len], path);
    _ = std.os.linux.statx(std.os.linux.AT.FDCWD, &pz, 0, .{ .MODE = true }, &stx);
    try std.testing.expectEqual(@as(u16, 0o600), stx.mode & 0o777);
}

test "saving merges: a stale snapshot never reverts other keys" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/shotlet", .{root});

    var first = Config{};
    first.setScToken("old-token");
    try saveDir(alloc, dir, &first);
    // also keep lines we do not understand
    try updateDir(alloc, dir, &.{.{ .key = "future_option", .value = "42" }});

    // the Settings window opens and holds a snapshot
    var settings = loadDir(alloc, dir);
    // meanwhile a capture stores a fresh token
    try updateDir(alloc, dir, &.{.{ .key = "screencast_restore_token", .value = "new-token" }});
    // the user toggles one option; Settings saves its whole snapshot
    settings.notify = false;
    try saveDir(alloc, dir, &settings);

    var now = loadDir(alloc, dir);
    try std.testing.expectEqualStrings("new-token", now.scToken().?);
    try std.testing.expectEqual(false, now.notify);

    // toggling back is saved too (the baseline follows each save)
    settings.notify = true;
    try saveDir(alloc, dir, &settings);
    now = loadDir(alloc, dir);
    try std.testing.expectEqual(true, now.notify);

    var path_buf: [600]u8 = undefined;
    const data = try sys.readFileAlloc(alloc, try configFile(dir, &path_buf), 64 * 1024);
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "future_option=42\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, data, "notify="));
}

test "forgetting the restore token asks again and survives a settings save" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/shotlet", .{root});
    try updateDir(alloc, dir, &.{.{ .key = "screencast_restore_token", .value = "tok" }});
    var settings = loadDir(alloc, dir);
    try std.testing.expectEqualStrings("tok", settings.scToken().?);
    // "Choose monitors again"
    settings.setScToken("");
    try updateDir(alloc, dir, &.{.{ .key = "screencast_restore_token", .value = "" }});
    try std.testing.expectEqual(@as(?[]const u8, null), loadDir(alloc, dir).scToken());
    // a later save of the same window keeps it forgotten
    settings.notify = !settings.notify;
    try saveDir(alloc, dir, &settings);
    try std.testing.expectEqual(@as(?[]const u8, null), loadDir(alloc, dir).scToken());
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

test "settings from cliptux are carried over once, also from XDG_CONFIG_HOME" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);

    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    const xdg_home = try std.fmt.bufPrint(&b1, "{s}/xdgcfg", .{root});
    const old_dir = try std.fmt.bufPrint(&b2, "{s}/xdgcfg/cliptux", .{root});
    sys.mkdirAll(old_dir, 0o700);
    var b3: [512]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&b3, "{s}/config", .{old_dir}), "default_thickness=11\n");

    const saved = env.xdg;
    defer env.xdg = saved;
    env.xdg.config_home = xdg_home;

    const migrated = load(alloc, root);
    try std.testing.expectEqual(@as(i32, 11), migrated.default_thickness);
    try std.testing.expect(if (sys.fileSize(old_dir)) |_| false else |_| true);

    // an existing Shotlet configuration always wins over a leftover cliptux one
    sys.mkdirAll(old_dir, 0o700);
    try sys.writeFile(try std.fmt.bufPrint(&b3, "{s}/config", .{old_dir}), "default_thickness=3\n");
    const again = load(alloc, root);
    try std.testing.expectEqual(@as(i32, 11), again.default_thickness);
}

test "single-monitor restore tokens are dropped" {
    const alloc = std.testing.allocator;
    const out = try mergeContent(alloc, "screencast_token=old\nnotify=true\n", &.{
        .{ .key = "screencast_restore_token", .value = "new" },
    });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("notify=true\nscreencast_restore_token=new\n", out);
    var cfg = Config{};
    applyValue(&cfg, "screencast_token", "old");
    try std.testing.expect(cfg.scToken() == null);
}

test "migration copies when the new directory already exists" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    var b3: [512]u8 = undefined;
    const old_dir = try std.fmt.bufPrint(&b1, "{s}/cliptux", .{root});
    const new_dir = try std.fmt.bufPrint(&b2, "{s}/shotlet", .{root});
    sys.mkdirAll(old_dir, 0o700);
    sys.mkdirAll(new_dir, 0o700);
    try sys.writeFile(try std.fmt.bufPrint(&b3, "{s}/other", .{new_dir}), "x");
    try sys.writeFile(try std.fmt.bufPrint(&b3, "{s}/config", .{old_dir}), "default_color=4\n");
    migrateFrom(&.{old_dir}, new_dir);
    try std.testing.expectEqual(@as(u3, 4), loadDir(alloc, new_dir).default_color);
}
