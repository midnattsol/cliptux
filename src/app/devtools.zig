//! Internal development commands (not part of the user-facing CLI):
//! test-window, test-capture, test-grab, test-font, test-decode.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/sys.zig");
const Env = @import("env.zig").Env;
const nowMs = @import("shot.zig").nowMs;

/// Returns true when `cmd` was a recognized dev command.
pub fn run(gpa: std.mem.Allocator, env: Env, cmd: []const u8, args: []const [:0]const u8) !bool {
    if (std.mem.eql(u8, cmd, "test-window")) {

        // internal development tool: fullscreen gradient for ~3s, Esc to close
        const window = @import("../ui/window.zig");
        var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
        defer win.deinit();
        try win.open("cliptux test", .{});
        var elapsed_ms: i64 = 0;
        var frames: u32 = 0;
        outer: while (elapsed_ms < 3000) {
            while (try win.nextEventTimeout(100)) |ev| {
                switch (ev) {
                    .resize => {
                        const px = try win.backBuffer();
                        for (px, 0..) |*p, i| {
                            const x: u32 = @intCast(i % win.width);
                            const y: u32 = @intCast(i / win.width);
                            p.* = 0xFF000000 | ((x * 255 / win.width) << 16) | ((y * 255 / win.height) << 8) | 0x40;
                        }
                        try win.present();
                        frames += 1;
                    },
                    .key => |k| if (k.pressed and k.code == window.KEY_ESC) break :outer,
                    .close => break :outer,
                    else => {},
                }
            }
            elapsed_ms += 100;
        }
        std.debug.print("window ok: {d}x{d}, {d} frames presented\n", .{ win.width, win.height, frames });
        return true;
    }
    if (std.mem.eql(u8, cmd, "test-grab")) {

        // internal development tool: ScreenCast + PipeWire single frame
        const pw = @import("../platform/pw.zig");
        var cfg = @import("config.zig").load(gpa, env.home);
        var conn = try dbus.Connection.connectSession(gpa, env.bus_addr);
        defer conn.deinit();
        portal.ensureAppScope(gpa, &conn);
        const t0 = nowMs();
        var sc = try portal.openScreenCast(gpa, &conn, cfg.scToken());
        defer sc.deinit(gpa);
        const t1 = nowMs();
        if (sc.restore_token) |t| {
            cfg.setScToken(t);
            @import("config.zig").save(gpa, env.home, &cfg) catch {};
        }
        std.debug.print("session: node={d} fd={d} portal={d}ms token={s}\n", .{
            sc.node_id, sc.pw_fd, t1 - t0, if (sc.restore_token != null) "new" else "reused",
        });
        var frame = try pw.grabFrame(sc.pw_fd, sc.node_id, 5);
        defer frame.deinit();
        const t2 = nowMs();
        std.debug.print("frame: {d}x{d} grab={d}ms total={d}ms\n", .{ frame.width, frame.height, t2 - t1, t2 - t0 });
        const out = try png.encode(gpa, frame.pixels, frame.width, frame.height);
        defer gpa.free(out);
        try sys.writeFile("/tmp/cliptux-grab.png", out);
        std.debug.print("wrote /tmp/cliptux-grab.png\n", .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "test-font")) {

        // internal development tool: render sample text to a PNG
        const text = @import("../gfx/text.zig");
        const render = @import("../gfx/render.zig");
        text.init(gpa);
        defer text.deinit();
        const W = 900;
        const H = 240;
        const px = try gpa.alloc(u32, W * H);
        defer gpa.free(px);
        @memset(px, 0xFF1B1F23);
        var canvas = render.Canvas.init(px, W, H);
        text.draw(&canvas, 20, 16, 34.0, 0xFFE9ECEF, "cliptux Settings — AaBbGg 0123");
        text.draw(&canvas, 20, 70, 22.0, 0xFF4DABF7, "Notification after saving");
        text.draw(&canvas, 20, 105, 16.0, 0xFF8B939B, "Bind a key to \"cliptux\" — áéíóú ñ ç ü");
        text.draw(&canvas, 20, 140, 13.0, 0xFFE9ECEF, "Small 13px: The quick brown fox jumps over the lazy dog");
        text.draw(&canvas, 20, 170, 11.0, 0xFFE9ECEF, "Tiny 11px: The quick brown fox jumps over the lazy dog");
        const out = try png.encode(gpa, px, W, H);
        defer gpa.free(out);
        try sys.writeFile("/tmp/cliptux-font.png", out);
        std.debug.print("wrote /tmp/cliptux-font.png\n", .{});
        return true;
    }
    if (std.mem.eql(u8, cmd, "test-decode")) {

        // internal development tool
        if (args.len < 3) return error.MissingArg;
        const data = try sys.readFileAlloc(gpa, args[2], 256 * 1024 * 1024);
        defer gpa.free(data);
        var img = try png.decode(gpa, data);
        defer img.deinit(gpa);
        std.debug.print("decoded {d}x{d}, pixel[0]=0x{x:0>8}\n", .{ img.width, img.height, img.pixels[0] });
        const out = try png.encode(gpa, img.pixels, img.width, img.height);
        defer gpa.free(out);
        try sys.writeFile("/tmp/cliptux-reencoded.png", out);
        return true;
    }
    return false;
}
