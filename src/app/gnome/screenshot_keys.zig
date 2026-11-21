//! GNOME's own screenshot shortcuts (org.gnome.shell.keybindings) that
//! hold the extension's key: taking that key from them (remembered in
//! ~/.config/shotlet/gnome-moved-keys) and giving it back exactly.

const std = @import("std");
const sys = @import("../../platform/sys.zig");
const env_mod = @import("../env.zig");
const gsettings = @import("../gsettings.zig");
const custom = @import("custom.zig");
const sameAccel = @import("../accel.zig").sameAccel;
const contains = custom.contains;
const Env = env_mod.Env;

const shell_keys_schema = "org.gnome.shell.keybindings";
/// GNOME's own screenshot shortcuts (the extension yields to them)
const gnome_shot_keys = [_][]const u8{ "show-screenshot-ui", "screenshot", "screenshot-window", "show-screen-recording-ui" };
/// where GNOME's screenshot UI goes when Shotlet takes its key
const ui_moved_to = "<Shift><Super>s";
/// schemas whose keys hold keyboard shortcuts
const binding_schemas = [_][]const u8{
    "org.gnome.shell.keybindings",                  "org.gnome.desktop.wm.keybindings",
    "org.gnome.mutter.keybindings",                 "org.gnome.mutter.wayland.keybindings",
    "org.gnome.settings-daemon.plugins.media-keys",
};

/// Some GNOME shortcut (or a custom one) uses `accel`.
fn accelInUse(arena: std.mem.Allocator, env: Env, accel: []const u8) bool {
    for (binding_schemas) |schema| {
        const all = gsettings.run(arena, env, null, &.{ "list-recursively", schema }) catch continue;
        var lines = std.mem.splitScalar(u8, all, '\n');
        while (lines.next()) |line| {
            const strs = gsettings.quotedStrings(arena, line) catch continue;
            for (strs) |str| if (sameAccel(str, accel)) return true;
        }
    }
    const list = gsettings.parseStrv(arena, gsettings.get(arena, env, null, custom.media_keys, "custom-keybindings") catch return false) catch return false;
    for (list) |path| {
        const schema = custom.customPathSchema(arena, path) catch continue;
        const b = custom.getString(arena, env, schema, "binding") catch continue;
        if (sameAccel(b, accel)) return true;
    }
    return false;
}

/// Where GNOME's own shortcuts that Shotlet took are remembered.
fn keysBackupPath(buf: []u8, home: []const u8) ![]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try env_mod.configDir(&dir_buf, home);
    return std.fmt.bufPrint(buf, "{s}/gnome-moved-keys", .{dir});
}

/// A GNOME screenshot shortcut that holds one of ours: its value as it
/// was, and what it keeps without our keys.
pub const Taken = struct { key: []const u8, old: []const u8, new: [][]const u8 };

/// GNOME's screenshot shortcuts that hold one of `ours`.
pub fn keysToTake(arena: std.mem.Allocator, env: Env, ours: []const []const u8) ![]Taken {
    var out: std.ArrayList(Taken) = .empty;
    for (gnome_shot_keys) |key| {
        const old = std.mem.trim(u8, gsettings.get(arena, env, null, shell_keys_schema, key) catch continue, " \n");
        const list = gsettings.parseStrv(arena, old) catch continue;
        var keep: std.ArrayList([]const u8) = .empty;
        var hit = false;
        for (list) |a| {
            if (clashes(a, ours)) hit = true else try keep.append(arena, a);
        }
        if (!hit) continue;
        // GNOME's screenshot UI keeps a key when a free one is at hand
        if (std.mem.eql(u8, key, "show-screenshot-ui") and keep.items.len == 0 and !accelInUse(arena, env, ui_moved_to))
            try keep.append(arena, ui_moved_to);
        try out.append(arena, .{ .key = key, .old = old, .new = keep.items });
    }
    return out.toOwnedSlice(arena);
}

fn clashes(accel: []const u8, ours: []const []const u8) bool {
    for (ours) |o| if (sameAccel(accel, o)) return true;
    return false;
}

/// Take our keys from GNOME's shortcuts, remembering them first.
pub fn takeKeys(arena: std.mem.Allocator, env: Env, taken: []const Taken) !void {
    var pbuf: [1100]u8 = undefined;
    const bpath = try keysBackupPath(&pbuf, env.home);
    var records: std.ArrayList(u8) = .empty;
    for (taken) |t| try records.print(arena, "{s}\t{s}\t{s}\n", .{ shell_keys_schema, t.key, t.old });
    // remembered before anything changes
    try custom.appendBackup(arena, env, bpath, records.items);
    for (taken) |t| try gsettings.set(arena, env, null, shell_keys_schema, t.key, try gsettings.formatStrv(arena, t.new));
}

/// Give GNOME's screenshot shortcuts back exactly as they were (a key
/// that was at its default is reset, not set to the same value).
pub fn restoreKeys(arena: std.mem.Allocator, env: Env) !usize {
    var pbuf: [1100]u8 = undefined;
    const bpath = try keysBackupPath(&pbuf, env.home);
    const data = sys.readFileAlloc(arena, bpath, 1024 * 1024) catch return 0;
    var n: usize = 0;
    // the earliest record of a key is what it was before Shotlet
    var seen: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const schema = f.next() orelse continue;
        const key = f.next() orelse continue;
        const old = f.next() orelse continue;
        if (!std.mem.eql(u8, schema, shell_keys_schema) or !contains(&gnome_shot_keys, key) or contains(seen.items, key)) continue;
        try seen.append(arena, key);
        try restoreKey(arena, env, schema, key, old);
        n += 1;
    }
    sys.unlink(bpath) catch {};
    return n;
}

/// Reset `key`, then set `old` if that is not its default.
fn restoreKey(arena: std.mem.Allocator, env: Env, schema: []const u8, key: []const u8, old: []const u8) !void {
    try gsettings.reset(arena, env, null, schema, key);
    const now = std.mem.trim(u8, try gsettings.get(arena, env, null, schema, key), " \n");
    if (!std.mem.eql(u8, now, old)) try gsettings.set(arena, env, null, schema, key, old);
}
