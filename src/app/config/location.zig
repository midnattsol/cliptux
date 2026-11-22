//! Where the config file lives, and the one-time move of a configuration
//! left by Shotlet's former name, cliptux.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const env = @import("../env.zig");

/// The config file in the config directory `dir`.
pub fn configFile(dir: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/config", .{dir});
}

/// Shotlet was called cliptux. Carry an old cliptux config directory (in
/// $XDG_CONFIG_HOME or ~/.config) over to the new place once, so settings,
/// shortcuts and the screencast token survive the rename. Never overwrites
/// an existing Shotlet configuration.
pub fn migrateLegacy(home: []const u8, new_dir: []const u8) void {
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

/// Move (or, failing that, copy) the first of `olds` that holds a config
/// file to `new_dir`.
pub fn migrateFrom(olds: []const []const u8, new_dir: []const u8) void {
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
        copyConfig(old_cfg, new_dir, new_cfg) catch continue;
        std.log.info("copied settings from {s} to {s}", .{ old_cfg, new_cfg });
        return;
    }
}

/// Copy the config file alone into `new_dir`, never over an existing one.
fn copyConfig(old_cfg: []const u8, new_dir: []const u8, new_cfg: []const u8) !void {
    var arena_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const data = try sys.readFileAlloc(fba.allocator(), old_cfg, arena_buf.len);
    sys.mkdirAll(new_dir, 0o700);
    try sys.writeFileExclusive(new_cfg, data, 0o600);
}
