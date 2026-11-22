//! shotlet-droptarget: a maximized window that takes drops, for the e2e
//! tests (tools/e2e.sh). Accepts the MIME types given on the command line,
//! best first (default image/png, then text/uri-list), and prints one line
//! per drop on stdout: `drop MIME BYTES HEAD`, HEAD being the first 4 bytes
//! in hex for image/png, else the text (first line). Typed keys print
//! `text CHARS`, clicks `click X Y`.
//! Refuses to run outside the private session of tools/e2e/session.sh.

const std = @import("std");
const kit = @import("shotlet");
const window = kit.window;
const sys = kit.sys;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(arena);
    const vars = init.environ_map;
    if (vars.get("HL_INNER") == null) {
        std.debug.print("shotlet-droptarget: run me inside tools/e2e/session.sh\n", .{});
        std.process.exit(2);
    }
    var mimes: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |a| try mimes.append(arena, a);
    if (mimes.items.len == 0) try mimes.appendSlice(arena, &.{ "image/png", "text/uri-list" });

    var win = try window.Window.connect(gpa, vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir, vars.get("WAYLAND_DISPLAY") orelse "wayland-0");
    defer win.deinit();
    win.accept_mimes = mimes.items;
    try win.open("drop target", .{ .fullscreen = false, .maximized = true, .width = 800, .height = 600 });
    try say("ready", .{});
    var dirty = true;
    while (true) {
        if (dirty and !win.frame_pending and win.width > 0) {
            const px = try win.backBuffer();
            @memset(px, 0xFFDDE7F0);
            try win.present();
            dirty = false;
        }
        const ev = (try win.nextEventTimeout(200)) orelse {
            try report(&win);
            continue;
        };
        switch (ev) {
            .close => break,
            .resize => dirty = true,
            .pointer_button => |b| if (b.pressed) try say("click {d} {d}", .{ @as(i32, @intFromFloat(b.x)), @as(i32, @intFromFloat(b.y)) }),
            // what a focused app would type (focus checks of the floating windows)
            .key => |k| if (k.pressed and k.text().len > 0) try say("text {s}", .{k.text()}),
            else => {},
        }
        try report(&win);
    }
}

fn report(win: *window.Window) !void {
    const d = win.dropped orelse return;
    defer {
        std.heap.smp_allocator.free(d.data);
        win.dropped = null;
    }
    if (std.mem.eql(u8, d.mime, "image/png")) {
        const n: usize = @min(4, d.data.len);
        var hex: [8]u8 = undefined;
        for (d.data[0..n], 0..) |c, i| _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{c}) catch unreachable;
        try say("drop {s} {d} {s}", .{ d.mime, d.data.len, hex[0 .. n * 2] });
    } else {
        const line = std.mem.sliceTo(d.data, '\r');
        try say("drop {s} {d} {s}", .{ d.mime, d.data.len, std.mem.trimEnd(u8, line, "\n") });
    }
}

fn say(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt ++ "\n", args);
    try sys.writeAll(1, s);
}
