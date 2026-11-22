//! Reading the config file: key=value lines into a Config. Unknown keys
//! and malformed values never fail; they keep the default.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const binds = @import("../binds.zig");
const model = @import("model.zig");
const location = @import("location.zig");
const Config = model.Config;
const Action = binds.Action;
const Bind = binds.Bind;

/// Apply every key=value line of `dir`'s config file to `cfg` (a missing
/// or unreadable file changes nothing).
pub fn readInto(alloc: std.mem.Allocator, dir: []const u8, cfg: *Config) void {
    var path_buf: [1024]u8 = undefined;
    const path = location.configFile(dir, &path_buf) catch return;
    const data = sys.readFileAlloc(alloc, path, 64 * 1024) catch return;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const kv = parseLine(line) orelse continue;
        applyValue(cfg, kv.key, kv.value);
    }
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
    if (std.mem.startsWith(u8, key, "bind_")) applyBind(cfg, key["bind_".len..], value);
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

/// "bind_<action>": the binding of that editor action.
fn applyBind(cfg: *Config, name: []const u8, value: []const u8) void {
    inline for (@typeInfo(Action).@"enum".field_names, 0..) |fld_name, i| {
        if (std.mem.eql(u8, name, fld_name)) {
            cfg.binds[i] = parseBind(value);
        }
    }
}

pub fn parseBind(value: []const u8) Bind {
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

test "bind parse and format roundtrip" {
    const b = parseBind("ctrl+shift+44");
    try std.testing.expect(b.ctrl and b.shift and b.code == 44);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", binds.bindName(b, &buf));
    try std.testing.expectEqualStrings("unset", binds.bindName(.{}, &buf));
    const plain = parseBind("25");
    try std.testing.expect(!plain.ctrl and plain.code == 25);
    // malformed input degrades to unbound, never crashes
    try std.testing.expect(parseBind("ctrl+banana").code == 0);
    try std.testing.expect(parseBind("").code == 0);
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
