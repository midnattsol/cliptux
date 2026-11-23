//! Reading the config file: key=value lines into a Config. Unknown keys
//! and malformed values never fail; they keep the default.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const binds = @import("../binds.zig");
const model = @import("model.zig");
const location = @import("location.zig");
const legacy_keys = @import("legacy_keys.zig");
const accel = @import("../accel.zig");
const KeyCode = @import("../../platform/api/keys.zig").Code;
const Config = model.Config;
const Action = binds.Action;
const Bind = binds.Bind;
const n_actions = binds.n_actions;

/// The keys (model.keyName's numbering) whose value came from an older
/// file's spelling: an editor action's `bind_<action>` line
/// (legacy_keys.zig), `loupe=selecting` or `loupe=auto`. The next save
/// writes them anew (`shortcut_<action>`, dropping the old line;
/// `loupe=hold`).
pub const Migrated = [model.n_keys]bool;

/// Apply every key=value line of `dir`'s config file to `cfg` (a missing
/// or unreadable file changes nothing).
pub fn readInto(alloc: std.mem.Allocator, dir: []const u8, cfg: *Config) Migrated {
    var path_buf: [1024]u8 = undefined;
    const path = location.configFile(dir, &path_buf) catch return @splat(false);
    const data = sys.readFileAlloc(alloc, path, 64 * 1024) catch return @splat(false);
    defer alloc.free(data);
    return applyText(cfg, data);
}

/// Apply a config file's text; a `shortcut_<action>` line wins over the
/// same action's `bind_<action>` wherever either is.
pub fn applyText(cfg: *Config, data: []const u8) Migrated {
    var old: [n_actions]?Bind = @splat(null);
    var current: [n_actions]bool = @splat(false);
    var migrated: Migrated = @splat(false);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const kv = parseLine(line) orelse continue;
        if (actionOf(kv.key, legacy_prefix)) |i| {
            old[i] = parseLegacyBind(kv.value);
            continue;
        }
        if (actionOf(kv.key, model.bind_prefix)) |i| current[i] = true;
        if (std.mem.eql(u8, kv.key, "loupe")) migrated[model.loupe_key] = model.Loupe.isLegacy(kv.value);
        applyValue(cfg, kv.key, kv.value);
    }
    for (old, current, 0..) |o, c, i| if (o != null and !c) {
        cfg.binds[i] = o.?;
        migrated[model.n_fixed_keys + i] = true;
    };
    return migrated;
}

pub fn parseLine(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], " \t"),
        .value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t"),
    };
}

/// Apply one key=value pair to `cfg` (unknown keys are ignored).
pub fn applyValue(cfg: *Config, key: []const u8, value: []const u8) void {
    if (applyGeneral(cfg, key, value)) return;
    if (applyBeautify(cfg, key, value)) return;
    if (applyQuickAndHistory(cfg, key, value)) return;
    if (applyLoupe(cfg, key, value)) return;
    if (actionOf(key, model.bind_prefix)) |i| cfg.binds[i] = parseBind(value);
}

fn isTrue(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

/// Options that default to on: anything but "false" keeps them on.
fn notFalse(value: []const u8) bool {
    return !std.mem.eql(u8, value, "false");
}

/// Saving, drawing defaults and the ScreenCast token.
fn applyGeneral(cfg: *Config, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "notify")) {
        cfg.notify = isTrue(value);
    } else if (std.mem.eql(u8, key, "copy_on_save")) {
        cfg.copy_on_save = isTrue(value);
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
    } else return false;
    return true;
}

/// The editor's "beautify" frame.
fn applyBeautify(cfg: *Config, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "beautify_always")) {
        cfg.beautify_always = isTrue(value);
    } else if (std.mem.eql(u8, key, "beautify_background")) {
        cfg.beautify_background = std.fmt.parseInt(u8, value, 10) catch 0;
    } else if (std.mem.eql(u8, key, "beautify_padding")) {
        for (model.padding_names, 0..) |n, i| {
            if (std.mem.eql(u8, value, n)) cfg.beautify_padding = @intCast(i);
        }
    } else if (std.mem.eql(u8, key, "beautify_corners")) {
        cfg.beautify_corners = notFalse(value);
    } else if (std.mem.eql(u8, key, "beautify_shadow")) {
        cfg.beautify_shadow = notFalse(value);
    } else return false;
    return true;
}

/// The first-run hint, the quick-access thumbnail and capture history.
fn applyQuickAndHistory(cfg: *Config, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "hint_shown")) {
        cfg.hint_shown = isTrue(value);
    } else if (std.mem.eql(u8, key, "thumbnail")) {
        cfg.thumbnail = std.meta.stringToEnum(model.Thumbnail, value) orelse cfg.thumbnail;
    } else if (std.mem.eql(u8, key, "quick_access")) {
        // the switch before there was a choice: off is never
        if (!notFalse(value)) cfg.thumbnail = .never;
    } else if (std.mem.eql(u8, key, "quick_access_seconds")) {
        const v = std.fmt.parseInt(u16, value, 10) catch cfg.quick_access_seconds;
        cfg.quick_access_seconds = std.math.clamp(v, 1, 3600);
    } else if (std.mem.eql(u8, key, "history")) {
        cfg.history = notFalse(value);
    } else if (std.mem.eql(u8, key, "history_max")) {
        cfg.history_max = std.math.clamp(std.fmt.parseInt(u16, value, 10) catch cfg.history_max, 1, 10000);
    } else if (std.mem.eql(u8, key, "history_max_mb")) {
        cfg.history_max_mb = std.math.clamp(std.fmt.parseInt(u32, value, 10) catch cfg.history_max_mb, 1, 1 << 20);
    } else return false;
    return true;
}

/// The magnifier while choosing an area: when it shows, its zoom.
fn applyLoupe(cfg: *Config, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "loupe")) {
        cfg.loupe = model.Loupe.parse(value) orelse cfg.loupe;
    } else if (std.mem.eql(u8, key, "loupe_zoom")) {
        cfg.loupe_zoom = model.nearestZoom(std.fmt.parseInt(i64, value, 10) catch cfg.loupe_zoom);
    } else return false;
    return true;
}

/// what older files called an editor action's key
pub const legacy_prefix = "bind_";

/// The action `key` names after `prefix` ("shortcut_pen": pen).
fn actionOf(key: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const name = key[prefix.len..];
    inline for (@typeInfo(Action).@"enum".field_names, 0..) |fld_name, i| {
        if (std.mem.eql(u8, name, fld_name)) return i;
    }
    return null;
}

/// "Ctrl+Shift+Z"; anything else ("none", malformed) is unbound.
pub fn parseBind(value: []const u8) Bind {
    const a = accel.parse(value) orelse return .{};
    return Bind.fromAccel(a) orelse .{};
}

/// An older file's "ctrl+shift+44": modifiers, then the key's number.
fn parseLegacyBind(value: []const u8) Bind {
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
    b.code = legacy_keys.key(std.fmt.parseInt(u32, rest, 10) catch 0);
    return b;
}

test "bind parse and format roundtrip" {
    const b = parseBind("Ctrl+Shift+Z");
    try std.testing.expect(b.ctrl and b.shift and b.code == .z);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", binds.bindName(b, &buf));
    try std.testing.expectEqualStrings("unset", binds.bindName(.{}, &buf));
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", b.toAccel().?.format(&buf).?);
    const plain = parseBind("p");
    try std.testing.expect(!plain.ctrl and plain.code == .p);
    try std.testing.expect(parseBind("1").code == .digit_1);
    // malformed input, and what binds cannot hold, degrade to unbound
    try std.testing.expect(parseBind("Ctrl+Banana").code == .none);
    try std.testing.expect(parseBind("Alt+P").code == .none);
    try std.testing.expect(parseBind("none").code == .none);
    try std.testing.expect(parseBind("").code == .none);
}

test "older files' key numbers migrate, and never win over the new keys" {
    var cfg: Config = .{};
    const migrated = applyText(&cfg,
        \\bind_redo=ctrl+shift+44
        \\shortcut_pen=Ctrl+F
        \\bind_pen=25
        \\bind_line=2
        \\bind_text=ctrl+banana
        \\
    );
    const at = struct {
        fn f(c: *const Config, a: Action) Bind {
            return c.binds[@backingInt(a)];
        }
    }.f;
    try std.testing.expect(at(&cfg, .redo).matches(.z, true, true));
    try std.testing.expect(at(&cfg, .pen).matches(.f, true, false));
    // an old number is the key it was (2: the digit 1), not a digit
    try std.testing.expect(at(&cfg, .line).matches(.digit_1, false, false));
    try std.testing.expectEqual(KeyCode.none, at(&cfg, .text).code);
    const bind = struct {
        fn f(a: Action) usize {
            return model.n_fixed_keys + @as(usize, @backingInt(a));
        }
    }.f;
    try std.testing.expect(migrated[bind(.redo)] and migrated[bind(.line)]);
    try std.testing.expect(!migrated[bind(.pen)] and !migrated[bind(.undo)]);
}

test "the thumbnail setting, and the switch it replaced" {
    var cfg: Config = .{};
    try std.testing.expect(cfg.showsThumbnail(true) and !cfg.showsThumbnail(false));
    applyValue(&cfg, "thumbnail", "after_copy_and_save");
    try std.testing.expect(cfg.showsThumbnail(false));
    applyValue(&cfg, "thumbnail", "sometimes");
    try std.testing.expectEqual(model.Thumbnail.after_copy_and_save, cfg.thumbnail);
    applyValue(&cfg, "quick_access", "true");
    try std.testing.expectEqual(model.Thumbnail.after_copy_and_save, cfg.thumbnail);
    applyValue(&cfg, "quick_access", "false");
    try std.testing.expect(!cfg.thumbnails() and !cfg.showsThumbnail(true));
}

test "the magnifier's settings" {
    var cfg = Config{};
    try std.testing.expectEqual(model.Loupe.hold, cfg.loupe);
    applyValue(&cfg, "loupe", "never");
    try std.testing.expectEqual(model.Loupe.never, cfg.loupe);
    applyValue(&cfg, "loupe", "sometimes");
    try std.testing.expectEqual(model.Loupe.never, cfg.loupe);
    applyValue(&cfg, "loupe_zoom", "11");
    try std.testing.expectEqual(@as(u8, 12), cfg.loupe_zoom);
    applyValue(&cfg, "loupe_zoom", "big");
    try std.testing.expectEqual(@as(u8, 12), cfg.loupe_zoom);
}

test "an older file's loupe=selecting or auto reads as hold, to be written anew" {
    for ([_][]const u8{ "loupe=selecting\n", "loupe=auto\n" }) |text| {
        var cfg = Config{ .loupe = .never };
        const migrated = applyText(&cfg, text);
        try std.testing.expectEqual(model.Loupe.hold, cfg.loupe);
        try std.testing.expect(migrated[model.loupe_key]);
    }
    var current = Config{};
    try std.testing.expect(!applyText(&current, "loupe=always\n")[model.loupe_key]);
    try std.testing.expectEqual(model.Loupe.always, current.loupe);
}
