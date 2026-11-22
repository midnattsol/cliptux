//! Persistent configuration: simple key=value file at
//! $XDG_CONFIG_HOME/shotlet/config (~/.config/shotlet/config), private to
//! the user (0600). Writes merge: the file is re-read under a lock and only
//! the keys the caller changed are replaced, so two processes (the editor
//! storing a ScreenCast token, the Settings window) never undo each other.
//!
//! Facade over config/: model (the Config struct and its keys), parse
//! (reading the file), write (merging changes into it), location (the
//! file's path and the move from cliptux).

const std = @import("std");
const sys = @import("../platform/api.zig").sys;
const env = @import("env.zig");
const model = @import("config/model.zig");
const parse = @import("config/parse.zig");
const write = @import("config/write.zig");
const location = @import("config/location.zig");

// editor actions, their key bindings and key names (binds.zig)
const binds = @import("binds.zig");
pub const Action = binds.Action;
pub const n_actions = binds.n_actions;
pub const Bind = binds.Bind;
pub const default_binds = binds.default_binds;
pub const bindName = binds.bindName;

pub const Config = model.Config;
pub const Thumbnail = model.Thumbnail;
pub const n_keys = model.n_keys;
pub const padding_names = model.padding_names;
pub const parseLine = parse.parseLine;
pub const Change = write.Change;

const configFile = location.configFile;
const migrateFrom = location.migrateFrom;
const updateDir = write.updateDir;

comptime {
    _ = model;
    _ = parse;
    _ = write;
    _ = location;
    _ = @import("config/legacy_keys.zig");
}

// --- load ---

pub fn load(alloc: std.mem.Allocator, home: []const u8) Config {
    var dir_buf: [1024]u8 = undefined;
    const dir = env.configDir(&dir_buf, home) catch return .{};
    location.migrateLegacy(home, dir);
    return loadDir(alloc, dir);
}

fn loadDir(alloc: std.mem.Allocator, dir: []const u8) Config {
    var cfg = Config{};
    const migrated = parse.readInto(alloc, dir, &cfg);
    // missing keys get their defaults as baseline: unchanged, never written
    model.rememberBase(&cfg);
    // binds read from an older file's lines are written anew at the next save
    for (migrated, 0..) |m, i| if (m) {
        cfg.base[model.n_fixed_keys + i] = 0;
    };
    return cfg;
}

// --- save ---

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
        const v = model.formatValue(cfg, k, &vbufs[k]);
        if (!fresh and model.valueHash(v) == cfg.base[k]) continue;
        changes[n] = .{ .key = model.keyName(k, &kbufs[k]), .value = v };
        n += 1;
    }
    if (n > 0) try updateDir(alloc, dir, changes[0..n]);
    model.rememberBase(cfg);
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
    cfg.binds[@backingInt(Action.pen)] = .{ .code = .f, .ctrl = true };
    cfg.setScToken("tok-123");
    cfg.thumbnail = .after_copy_and_save;
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
    try std.testing.expect(loaded.binds[@backingInt(Action.pen)].matches(.f, true, false));
    try std.testing.expectEqualStrings("tok-123", loaded.scToken().?);
    try std.testing.expectEqual(Thumbnail.after_copy_and_save, loaded.thumbnail);
    try std.testing.expectEqual(@as(u16, 12), loaded.quick_access_seconds);
    try std.testing.expectEqual(false, loaded.history);
    try std.testing.expectEqual(@as(u16, 7), loaded.history_max);
    try std.testing.expectEqual(@as(u32, 64), loaded.history_max_mb);

    // private to the user
    var path_buf: [600]u8 = undefined;
    const path = try configFile(dir, &path_buf);
    try std.testing.expectEqual(@as(?u32, 0o600), sys.fileMode(path));
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

test "binds of an older file are written anew in the neutral notation" {
    const alloc = std.testing.allocator;
    const root = try testDir();
    defer alloc.free(root);
    defer sys.removeTree(root);
    var b1: [512]u8 = undefined;
    var b2: [600]u8 = undefined;
    const dir = try std.fmt.bufPrint(&b1, "{s}/shotlet", .{root});
    sys.mkdirAll(dir, 0o700);
    const path = try configFile(dir, &b2);
    try sys.writeFile(path, "bind_pen=ctrl+33\nnotify=false\n");

    var cfg = loadDir(alloc, dir);
    try std.testing.expect(cfg.binds[@backingInt(Action.pen)].matches(.f, true, false));
    // a save of anything else carries the migrated bind along
    cfg.copy_on_save = true;
    try saveDir(alloc, dir, &cfg);
    const data = try sys.readFileAlloc(alloc, path, 4096);
    defer alloc.free(data);
    try std.testing.expectEqualStrings("notify=false\ncopy_on_save=true\nshortcut_pen=Ctrl+F\n", data);
    try std.testing.expect(loadDir(alloc, dir).binds[@backingInt(Action.pen)].matches(.f, true, false));
}
