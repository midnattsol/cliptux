//! Capture-and-edit flow: portal/PipeWire acquisition, the first-run
//! permission dialog, and copy/save handling around the editor.

const std = @import("std");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/sys.zig");
const Env = @import("env.zig").Env;

fn warmupPw() void {
    _ = @import("../platform/pw.zig").available();
}

pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn run(gpa: std.mem.Allocator, env: Env, from_file: ?[]const u8, preset_sel: ?[4]i32, smoke_ms: i64) !void {
    const editor_mod = @import("../ui/editor.zig");
    const window = @import("../ui/window.zig");
    const config = @import("config.zig");
    const t0 = nowMs();

    // dlopen(libpipewire) costs ~50-80ms; overlap it with the rest of setup
    const pw_thread = std.Thread.spawn(.{}, warmupPw, .{}) catch null;

    var conn = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer conn.deinit();
    portal.ensureAppScope(gpa, &conn);

    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();

    if (pw_thread) |t| t.join();
    var img = try acquireImage(gpa, env, &conn, &cfg, from_file);
    defer img.deinit(gpa);
    const t_capture = nowMs();

    try win.open("cliptux", .{ .fullscreen = true });
    std.log.info("startup: capture={d}ms total={d}ms", .{ t_capture - t0, nowMs() - t0 });
    var ed = editor_mod.Editor.init(gpa, &win, &img);
    if (smoke_ms > 0) ed.smoke_deadline_ms = nowMs() + smoke_ms;
    ed.cfg_thickness = cfg.default_thickness;
    ed.color_idx = cfg.default_color;
    ed.binds = cfg.binds;
    ed.presetSelection(preset_sel);
    defer ed.deinit();
    const result = try ed.run();
    defer if (result.png_data) |d| gpa.free(d);

    switch (result.action) {
        .cancel => win.closeWindow(),
        .copy => {
            const source = try win.claimClipboardPng();
            win.closeWindow();
            ed.releaseCaches(); // serving may outlive the session; drop ~140MB
            if (cfg.notify) portal.notify(gpa, &conn, "cliptux", "Screenshot copied to clipboard");
            // keep serving paste requests until another app owns the clipboard
            try win.serveClipboard(source, result.png_data.?);
        },
        .save => {
            const source: ?u32 = if (cfg.copy_on_save) try win.claimClipboardPng() else null;
            win.closeWindow();
            ed.releaseCaches();
            const path = try savePng(gpa, env, &cfg, result.png_data.?);
            defer gpa.free(path);
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Saved to {s}", .{path}) catch "Saved";
            if (cfg.notify) portal.notify(gpa, &conn, "cliptux", msg);
            if (source) |src| try win.serveClipboard(src, result.png_data.?);
        },
    }
}

fn acquireImage(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *@import("config.zig").Config, from_file: ?[]const u8) !png.Image {
    const pw = @import("../platform/pw.zig");
    const config = @import("config.zig");

    if (from_file) |path| {
        const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
        defer gpa.free(data);
        return png.decode(gpa, data);
    }

    if (pw.available()) fast: {
        const ts0 = nowMs();
        const session_path = portal.scCreateSession(gpa, conn) catch |err| {
            std.log.info("screencast unavailable ({t}); falling back to screenshot portal", .{err});
            break :fast;
        };
        defer gpa.free(session_path);

        const started = portal.scSelectAndStart(gpa, conn, session_path, cfg.scToken()) catch |err| {
            std.log.info("screencast denied ({t}); falling back to screenshot portal", .{err});
            portal.closeSession(gpa, conn, session_path);
            break :fast;
        };
        defer if (started.restore_token) |t| gpa.free(t);
        if (started.restore_token) |t| {
            cfg.setScToken(t);
            config.save(gpa, env.home, cfg) catch {};
        }

        const fd = portal.scOpenRemote(gpa, conn, session_path) catch |err| {
            std.log.info("OpenPipeWireRemote failed ({t}); falling back", .{err});
            portal.closeSession(gpa, conn, session_path);
            break :fast;
        };

        const ts1 = nowMs();
        var frame = pw.grabFrame(fd, started.node_id, 5) catch |err| {
            std.log.info("pipewire grab failed ({t}); falling back to screenshot portal", .{err});
            portal.closeSession(gpa, conn, session_path);
            break :fast;
        };
        defer frame.deinit();
        const ts2 = nowMs();
        // close the session immediately: GNOME's screen-sharing indicator
        // must only blink during the actual grab, never while editing
        portal.closeSession(gpa, conn, session_path);
        const px = try gpa.dupe(u32, frame.pixels);
        std.log.info("  capture detail: session={d} grab={d} close+dup={d}ms", .{ ts1 - ts0, ts2 - ts1, nowMs() - ts2 });
        return .{ .width = frame.width, .height = frame.height, .pixels = px };
    }

    const png_data = portal.screenshot(gpa, conn, false) catch |err| switch (err) {
        error.PermissionDenied, error.CaptureCancelled => blk: {
            // GNOME only shows its consent dialog to the focused app, so a
            // headless first run is denied; ask again from a focused window.
            break :blk try firstRunPermissionFlow(gpa, env, conn);
        },
        else => return err,
    };
    defer gpa.free(png_data);
    return png.decode(gpa, png_data);
}

/// First-run consent: open a small focused window, re-request the screenshot
/// so GNOME can show its permission dialog, then recapture once granted.
fn firstRunPermissionFlow(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) ![]u8 {
    const window = @import("../ui/window.zig");
    const render = @import("../gfx/render.zig");

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("cliptux", .{ .fullscreen = false, .width = 640, .height = 220 });

    var pending: ?portal.Pending = null;
    defer if (pending) |*p| p.deinit(gpa);
    var status: []const u8 = "Press Enter to request it";
    var hint_logged = false;

    var uri: ?[]u8 = null;
    defer if (uri) |u| gpa.free(u);

    outer: while (uri == null) {
        // draw the dialog
        if (!win.frame_pending and win.width > 0) {
            const px = try win.backBuffer();
            @memset(px, 0xFF1D2125);
            var canvas = render.Canvas.init(px, win.width, win.height);
            const w: i32 = @intCast(win.width);
            canvas.rectOutline(0, 0, w, @intCast(win.height), 1, 0xFF3A3F44);
            const title = "cliptux needs screenshot permission";
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, title), 2), 42, 2, 0xFFE9ECEF, title);
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, status), 2), 96, 2, 0xFF74B3F2, status);
            const hint = "GNOME remembers this choice    Esc: cancel";
            canvas.text(@divTrunc(w - render.Canvas.textWidth(1, hint), 2), 156, 1, 0xFF868E96, hint);
            try win.present();
        }

        // pump both wayland and dbus
        try win.conn.flush();
        var fds = [_]sys.pollfd{
            .{ .fd = win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = conn.fd, .events = sys.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&fds, 200);

        if (fds[0].revents != 0 or win.queue.items.len > 0) {
            while (try win.nextEventTimeout(0)) |ev| switch (ev) {
                .key => |k| {
                    if (!k.pressed) continue;
                    if (k.code == window.KEY_ESC) return error.CaptureCancelled;
                    if (k.code == window.KEY_ENTER and pending == null) {
                        pending = try portal.begin(gpa, conn, false);
                        status = "Waiting for the system dialog...";
                    }
                },
                .close => return error.CaptureCancelled,
                else => {},
            };
        }
        if (fds[1].revents != 0 or conn.hasPending()) {
            var msg = try conn.nextMessage();
            defer msg.deinit(gpa);
            // without an in-flight request, unrelated bus traffic is drained
            // and discarded so poll() never spins on an unread socket
            if (pending == null) continue;
            try pending.?.handleMessage(gpa, &msg);
            if (pending.?.done()) {
                if (pending.?.err != null) {
                    // stay open and let the user retry
                    status = "Denied by the portal - Enter to retry";
                    if (!hint_logged) {
                        hint_logged = true;
                        std.log.warn("portal denied the request; manual grant (plain DBus):", .{});
                        std.log.warn("  busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission sbssas screenshot true screenshot cliptux 1 yes", .{});
                    }
                    pending.?.deinit(gpa);
                    pending = null;
                    continue :outer;
                }
                uri = try gpa.dupe(u8, pending.?.uri.?);
                break :outer;
            }
        }
    }

    // this capture contains our dialog; discard and retake without it
    const tainted = try portal.readAndUnlink(gpa, uri.?);
    gpa.free(tainted);
    win.closeWindow();
    // give the compositor a moment to unmap our window
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 400 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    return portal.screenshot(gpa, conn, false);
}

/// Resolve the XDG pictures dir from ~/.config/user-dirs.dirs (it is
/// localized, e.g. "Imágenes" on Spanish systems). Falls back to ~/Pictures.
fn picturesDir(gpa: std.mem.Allocator, env: Env, buf: []u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&path_buf, "{s}/.config/user-dirs.dirs", .{env.home});
    const cfg = try sys.readFileAlloc(gpa, cfg_path, 64 * 1024);
    defer gpa.free(cfg);

    var lines = std.mem.splitScalar(u8, cfg, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const prefix = "XDG_PICTURES_DIR=\"";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        var value = trimmed[prefix.len..];
        if (std.mem.lastIndexOfScalar(u8, value, '"')) |q| value = value[0..q];
        if (std.mem.startsWith(u8, value, "$HOME/")) {
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ env.home, value["$HOME/".len..] });
        }
        if (std.mem.startsWith(u8, value, "/")) {
            return std.fmt.bufPrint(buf, "{s}", .{value});
        }
    }
    return error.NotFound;
}

fn savePng(gpa: std.mem.Allocator, env: Env, cfg: *const @import("config.zig").Config, data: []const u8) ![]u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = if (cfg.saveDir()) |d|
        try std.fmt.bufPrint(&dir_buf, "{s}", .{d})
    else
        picturesDir(gpa, env, &dir_buf) catch
            try std.fmt.bufPrint(&dir_buf, "{s}/Pictures", .{env.home});
    sys.mkdir(dir); // best effort; may already exist

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();

    const path = try std.fmt.allocPrint(gpa, "{s}/cliptux-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.png", .{
        dir,
        day.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
    errdefer gpa.free(path);
    try sys.writeFile(path, data);
    return path;
}
