//! `shotlet edit FILE`: any PNG, JPEG or WebP in the editor, all of it
//! selected, then copied or saved like a capture.

const std = @import("std");
const env_mod = @import("env.zig");
const config = @import("config.zig");
const capture = @import("capture.zig");
const shot = @import("shot.zig");
const portal = @import("../platform/portal.zig");
const imgload = @import("../gfx/imgload.zig");
const launch = @import("../ui/tools/launch.zig");
const Env = env_mod.Env;

pub fn run(gpa: std.mem.Allocator, env: Env, path: []const u8) !void {
    const window = @import("../ui/window.zig");
    var img = imgload.loadFile(gpa, path) catch |err| {
        std.log.err("edit: cannot open {s}: {t}", .{ path, err });
        return err;
    };
    var cap = capture.Capture.single(gpa, img) catch |err| {
        img.deinit(gpa);
        return err;
    };
    defer cap.deinit(gpa);
    launch.select_all = true;

    var conn = try portal.connectApp(gpa, env.bus_addr);
    defer conn.deinit();
    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = true });
    std.log.info("edit: showing {s} ({d}x{d})", .{ path, cap.image.width, cap.image.height });
    try shot.editAndFinish(gpa, env, &conn, &cfg, &win, &cap, null, 0, null, .{});
}
