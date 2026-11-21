//! Capture-and-edit flow: portal/PipeWire acquisition (every monitor,
//! stitched), the first-run permission dialog, and copy/save/save-as
//! handling around the editor.

const std = @import("std");
const capture = @import("capture.zig");
const direct = @import("direct.zig");
const clock = @import("clock.zig");
const config = @import("config.zig");
const dbus = @import("../platform/dbus.zig");
const env_mod = @import("env.zig");
const portal = @import("../platform/portal.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/sys.zig");
const keep_mod = @import("keep.zig");
const history = @import("history.zig");
const annot = @import("annot.zig");
const gnome = @import("gnome.zig");
const shellcap = @import("shellcap.zig");
const Env = env_mod.Env;

fn warmupPw() void {
    _ = @import("../platform/pw.zig").available();
}

pub fn nowMs() i64 {
    return sys.monoMs();
}

/// Dev sources that skip the portal.
pub const From = struct {
    /// one PNG as the whole capture
    file: ?[]const u8 = null,
    /// comma-separated PNGs, one per monitor, laid out left to right
    monitors: ?[]const u8 = null,
    /// taken by the GNOME Shell extension (not a dev source)
    shell: ?shellcap.Args = null,

    fn any(self: From) bool {
        return self.file != null or self.monitors != null or self.shell != null;
    }
};

pub fn run(gpa: std.mem.Allocator, env: Env, from: From, preset_sel: ?[4]i32, smoke_ms: i64) !void {
    const window = @import("../ui/window.zig");
    const t0 = nowMs();

    var conn = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer conn.deinit();
    const t_dbus = nowMs();

    // with the GNOME Shell extension, the shell takes the screenshot (no
    // prompt) and starts another shotlet on it
    if (!from.any() and gnome.isGnome() and gnome.extensionActive(&conn)) {
        switch (gnome.requestCapture(gpa, &conn)) {
            .started => {
                std.log.info("capture handed to the GNOME integration ({d}ms)", .{nowMs() - t0});
                return;
            },
            .declined => return,
            .unavailable => {},
        }
    }

    // dlopen(libpipewire) costs ~50-80ms; overlap it with the rest of setup
    const pw_thread = if (from.any()) null else std.Thread.spawn(.{}, warmupPw, .{}) catch null;
    portal.registerApp(gpa, &conn);
    const t_scope = nowMs();

    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    const t_config = nowMs();

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    const t_wayland = nowMs();

    if (pw_thread) |t| t.join();
    const t_pw = nowMs();
    var cap = (try acquire(gpa, env, &conn, &cfg, from)) orelse {
        std.log.info("capture cancelled", .{});
        return;
    };
    defer cap.deinit(gpa);
    const t_capture = nowMs();

    // one fullscreen surface per monitor when the layout is known
    const per_monitor = cap.monitors.len > 1 and for (cap.monitors) |m| {
        if (m.logical == null) break false;
    } else true;
    try openEditor(&win, &cap, per_monitor);
    const t_open = nowMs();
    std.log.info("startup: capture={d}ms total={d}ms", .{ t_capture - t0, t_open - t0 });
    if (from.shell) |sh| if (sh.t0_ms) |key| {
        std.log.info("GNOME integration: key press to editor {d}ms (shell capture and launch {d}ms)", .{ t_open - key, t0 - key });
    };
    std.log.debug("startup detail: dbus={d}ms scope={d}ms config={d}ms wayland={d}ms pw-wait={d}ms capture={d}ms open={d}ms", .{
        t_dbus - t0,
        t_scope - t_dbus,
        t_config - t_scope,
        t_wayland - t_config,
        t_pw - t_wayland,
        t_capture - t_pw,
        t_open - t_capture,
    });
    try editAndFinish(gpa, env, &conn, &cfg, &win, &cap, per_monitor, preset_sel, smoke_ms, null);
}

/// The editor's fullscreen surfaces: one per monitor when the capture has
/// several; for a capture of one monitor (a portal that shares one, like
/// xdg-desktop-portal-wlr), on that monitor rather than wherever the
/// compositor puts a new window.
fn openEditor(win: anytype, cap: *const capture.Capture, per_monitor: bool) !void {
    defer std.log.debug("editor: {d} surfaces", .{win.n_surfaces});
    if (per_monitor) return win.openOutputs("Shotlet");
    if (cap.monitors.len == 1) if (cap.monitors[0].logical) |l| {
        return win.openOnOutputAt("Shotlet", l.x, l.y);
    };
    try win.open("Shotlet", .{ .fullscreen = true });
}

/// A kept capture opened again in the editor ("Annotate").
const Reopen = struct {
    kept: keep_mod.Kept,
    doc: *const annot.Doc,
};

/// The editor, then whatever its result asks for: copy, save, save as;
/// keeping the capture for quick access and the history.
fn editAndFinish(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config, win: anytype, cap: *capture.Capture, per_monitor: bool, preset_sel: ?[4]i32, smoke_ms: i64, reopen: ?Reopen) !void {
    const editor_mod = @import("../ui/editor.zig");
    var ed = editor_mod.Editor.init(gpa, win, &cap.image);
    ed.monitors = cap.monitors;
    // the desktop's light/dark preference, accent and reduced motion
    const theme = @import("../ui/theme.zig");
    ed.setPrefs(theme.readPrefs(conn, 1500));
    theme.watch(conn) catch {};
    ed.bus = conn;
    if (smoke_ms > 0) ed.smoke_deadline_ms = nowMs() + smoke_ms;
    ed.cfg_thickness = cfg.default_thickness;
    ed.color_idx = cfg.default_color;
    ed.binds = cfg.binds;
    ed.beautify = .{
        .enabled = cfg.beautify,
        .bg = cfg.beautify_background,
        .padding = cfg.beautify_padding,
        .rounded = cfg.beautify_corners,
        .shadow = cfg.beautify_shadow,
    };
    ed.show_hint = !cfg.hint_shown;
    ed.presetSelection(preset_sel);
    defer ed.deinit();
    if (reopen) |r| {
        // the shapes as they were, still editable
        ed.show_hint = false;
        ed.beautify = r.doc.beautify;
        ed.doc.sel = r.doc.sel orelse ed.doc.imageRect();
        for (r.doc.shapes.items) |*s| {
            var c = try s.clone(gpa);
            ed.doc.shapes.append(gpa, c) catch |err| {
                c.deinit(gpa);
                return err;
            };
        }
    }
    while (true) {
        const result = try ed.run();
        if (reopen == null) rememberEditorPrefs(gpa, env, cfg, &ed);
        defer if (result.png_data) |d| gpa.free(d);
        const replace: ?keep_mod.Kept = if (reopen) |r| r.kept else null;

        switch (result.action) {
            .cancel, .copied => {
                win.closeWindow();
                ed.releaseCaches(); // serving may outlive the session; drop ~140MB
                if (result.action == .copied) {
                    if (win.clipboardPng()) |data| {
                        if (keep_mod.keep(gpa, env, cfg, .{ .image_png = data, .source = ed.img, .doc = &ed.doc, .beautify = ed.beautify, .replace = replace })) |k| {
                            if (cfg.quick_access) keep_mod.spawnQuick(gpa, env, &k);
                        }
                    }
                }
                if (win.hasClipboard()) try win.serveClipboard();
            },
            .save, .save_as => {
                const data = result.png_data.?;
                if (cfg.copy_on_save) {
                    const copy = try gpa.dupe(u8, data);
                    win.setClipboardPng(copy) catch |err| {
                        gpa.free(copy);
                        std.log.warn("copy-on-save failed: {t}", .{err});
                    };
                }
                win.closeWindow();
                ed.releaseCaches();
                const saved: ?[]u8 = if (result.action == .save)
                    try savePng(gpa, env, cfg, data)
                else
                    try saveAs(gpa, env, conn, cfg, data);
                const path = saved orelse {
                    // the file chooser was cancelled: back to the editor,
                    // annotations intact, rather than losing the work
                    try openEditor(win, cap, per_monitor);
                    ed.running = true;
                    ed.action = .cancel;
                    continue;
                };
                defer gpa.free(path);
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Saved to {s}", .{path}) catch "Saved";
                if (cfg.notify) portal.notify(gpa, conn, "Shotlet", msg);
                if (keep_mod.keep(gpa, env, cfg, .{ .image_png = data, .source = ed.img, .doc = &ed.doc, .beautify = ed.beautify, .saved = path, .replace = replace })) |k| {
                    if (cfg.quick_access) keep_mod.spawnQuick(gpa, env, &k);
                }
                if (win.hasClipboard()) try win.serveClipboard();
            },
        }
        return;
    }
}

/// `shotlet edit ROOT ID`: open a kept capture in the editor again, with
/// its annotations; Copy or Save update the same entry.
pub fn runEdit(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    const window = @import("../ui/window.zig");
    if (!history.Id.valid(id)) return error.BadId;
    var path_buf: [1200]u8 = undefined;
    const src_data = try sys.readFileAlloc(gpa, try history.entryPath(&path_buf, root, id, "source.png"), 256 * 1024 * 1024);
    defer gpa.free(src_data);
    const doc_data = try sys.readFileAlloc(gpa, try history.entryPath(&path_buf, root, id, "doc"), 64 * 1024 * 1024);
    defer gpa.free(doc_data);
    var doc = try annot.parse(gpa, doc_data);
    defer doc.deinit(gpa);
    var img = try png.decode(gpa, src_data);
    var cap = capture.Capture.single(gpa, img) catch |err| {
        img.deinit(gpa);
        return err;
    };
    defer cap.deinit(gpa);

    var conn = try portal.connectApp(gpa, env.bus_addr);
    defer conn.deinit();
    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = true });
    std.log.info("editing {s} again", .{id});
    var kept: keep_mod.Kept = .{ .id = history.Id.fromSlice(id).? };
    if (root.len > kept.root_buf.len) return error.PathTooLong;
    @memcpy(kept.root_buf[0..root.len], root);
    kept.root_len = root.len;
    try editAndFinish(gpa, env, &conn, &cfg, &win, &cap, false, null, 0, .{ .kept = kept, .doc = &doc });
}

/// Get the image to edit. Null means the person cancelled a dialog: the
/// caller exits quietly, with no fallback and no further dialogs.
fn acquire(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config, from: From) !?capture.Capture {
    const pw = @import("../platform/pw.zig");

    if (from.shell) |args| {
        const t_load = nowMs();
        const cap = try shellcap.load(gpa, env.runtime_dir, args);
        std.log.info("  capture detail: monitors={d} through the GNOME integration (decode+stitch {d}ms)", .{ cap.monitors.len, nowMs() - t_load });
        return cap;
    }
    if (from.monitors) |list| return try fromMonitorFiles(gpa, list);
    if (from.file) |path| {
        const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
        defer gpa.free(data);
        var img = try png.decode(gpa, data);
        errdefer img.deinit(gpa);
        return try capture.Capture.single(gpa, img);
    }

    // the desktop's own capture interface: no consent dialog
    if (std.c.getenv("SHOTLET_NO_DIRECT") == null) {
        if (direct.captureAll(gpa, env.runtime_dir, env.wayland_display, conn)) |res| switch (res) {
            .captured => |c| {
                std.log.info("capture path: direct ({s})", .{c.method.label()});
                direct.remember(env.home, .direct);
                return c.cap;
            },
            .unavailable => |why| std.log.info("capture path: no direct capture ({s}); the portal", .{why}),
        } else |err| std.log.info("capture path: direct capture failed ({t}); the portal", .{err});
    }

    if (pw.available()) {
        switch (screencast(gpa, env, conn, cfg)) {
            .granted => |cap| {
                std.log.info("capture path: portal (ScreenCast)", .{});
                direct.remember(env.home, .portal);
                return cap;
            },
            .cancelled => return null,
            .timeout => return dialogTimedOut(),
            .denied => std.log.info("screencast denied; trying the screenshot portal", .{}),
            .unavailable => std.log.info("screencast unavailable; trying the screenshot portal", .{}),
        }
    }

    std.log.info("capture path: portal (Screenshot)", .{});
    direct.remember(env.home, .portal);
    const png_data = switch (try portal.screenshot(gpa, conn, false, portal.timeout_unfocused_screenshot_ms)) {
        .granted => |d| d,
        .cancelled => return null,
        // GNOME only shows its consent dialog to the focused app, so a
        // windowless first run is denied (or, with no app focused, never
        // answered); ask again from a focused window
        .denied, .timeout => (try firstRunPermissionFlow(gpa, env, conn)) orelse return null,
        .unavailable => return error.NoScreenshotPortal,
    };
    defer gpa.free(png_data);
    var img = try png.decode(gpa, png_data);
    errdefer img.deinit(gpa);
    return try capture.Capture.single(gpa, img);
}

/// Nobody answered a consent dialog for timeout_dialog_ms: it was closed;
/// end quietly, like a cancel.
fn dialogTimedOut() ?capture.Capture {
    std.log.info("the permission dialog got no answer; closed it and stopped", .{});
    return null;
}

/// ScreenCast + PipeWire: one frame from every monitor, stitched. Errors
/// after the portal said yes count as "unavailable" so the caller can fall
/// back to the Screenshot portal.
fn screencast(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config) portal.Result(capture.Capture) {
    return screencastInner(gpa, env, conn, cfg) catch |err| {
        std.log.info("screencast capture failed ({t})", .{err});
        return .unavailable;
    };
}

fn screencastInner(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config) !portal.Result(capture.Capture) {
    const pw = @import("../platform/pw.zig");
    const Res = portal.Result(capture.Capture);
    const ts0 = nowMs();

    const session_path = switch (try portal.scCreateSession(gpa, conn)) {
        .granted => |p| p,
        else => |o| return passOn(Res, o),
    };
    defer gpa.free(session_path);
    // the session must be closed on every path, and as early as possible:
    // GNOME's screen-sharing indicator must only blink during the grab
    var open = true;
    defer if (open) portal.closeSession(gpa, conn, session_path);

    var started = switch (try portal.scSelectAndStart(gpa, conn, session_path, cfg.scToken())) {
        .granted => |st| st,
        else => |o| return passOn(Res, o),
    };
    defer started.deinit(gpa);
    if (started.restore_token) |t| {
        cfg.setScToken(t);
        // only this key: never write back a stale snapshot of the rest
        config.saveScreencastToken(gpa, env.home, t) catch |err|
            std.log.warn("could not store the screencast token: {t}", .{err});
    }

    for (started.streams) |st| std.log.debug("screencast stream: node {d} position {?any} size {?any}", .{ st.node_id, st.position, st.size });
    const fd = try portal.scOpenRemote(gpa, conn, session_path);
    const streams = started.streams[0..@min(started.streams.len, pw.max_nodes)];
    var node_ids: [pw.max_nodes]u32 = undefined;
    for (streams, 0..) |st, i| node_ids[i] = st.node_id;

    const ts1 = nowMs();
    var frames: [pw.max_nodes]pw.Frame = undefined;
    try pw.grabFrames(fd, node_ids[0..streams.len], frames[0..streams.len], 5000);
    defer for (frames[0..streams.len]) |*f| f.deinit();
    const ts2 = nowMs();
    portal.closeSession(gpa, conn, session_path);
    open = false;

    var parts: [pw.max_nodes]capture.Part = undefined;
    for (streams, frames[0..streams.len], 0..) |st, f, i| {
        parts[i] = .{ .pixels = f.pixels, .width = f.width, .height = f.height };
        if (st.position != null and st.size != null) {
            parts[i].logical = .{
                .x = st.position.?[0],
                .y = st.position.?[1],
                .w = @intCast(st.size.?[0]),
                .h = @intCast(st.size.?[1]),
            };
        }
    }
    const cap = try capture.stitch(gpa, parts[0..streams.len]);
    std.log.info("  capture detail: monitors={d} session={d} grab={d} close+stitch={d}ms", .{
        streams.len, ts1 - ts0, ts2 - ts1, nowMs() - ts2,
    });
    return .{ .granted = cap };
}

fn passOn(comptime R: type, o: anytype) R {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}

/// First-run consent: open a small focused window, re-request the screenshot
/// so GNOME can show its permission dialog, then recapture once granted.
/// Null when the person closes the window.
fn firstRunPermissionFlow(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) !?[]u8 {
    const window = @import("../ui/window.zig");
    const render = @import("../gfx/render.zig");

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = false, .width = 640, .height = 220 });

    var pending: ?portal.Request = null;
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
            const title = "Shotlet needs screenshot permission";
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, title), 2), 42, 2, 0xFFE9ECEF, title);
            canvas.text(@divTrunc(w - render.Canvas.textWidth(2, status), 2), 96, 2, 0xFF74B3F2, status);
            const hint = "GNOME remembers it (once more after an update)   Esc: cancel";
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
                    if (k.code == window.KEY_ESC) return null;
                    if (k.code == window.KEY_ENTER and pending == null) {
                        pending = try portal.beginScreenshot(gpa, conn, false);
                        status = "Waiting for the system dialog...";
                    }
                },
                .close => return null,
                else => {},
            };
        }
        if (fds[1].revents != 0 or conn.hasPending()) {
            var msg = conn.nextMessage() catch |err| {
                if (dbus.isFatal(err)) return err;
                continue;
            };
            // without an in-flight request, unrelated bus traffic is drained
            // and discarded so poll() never spins on an unread socket
            const req = if (pending) |*p| p else {
                msg.deinit(gpa);
                continue;
            };
            const kept = req.handle(gpa, &msg) catch false;
            if (!kept) msg.deinit(gpa);
            const outcome = req.outcome orelse continue;
            switch (outcome) {
                .granted => {
                    uri = try gpa.dupe(u8, try portal.screenshotUri(req));
                    break :outer;
                },
                .cancelled => return null,
                .unavailable, .timeout => return error.NoScreenshotPortal,
                .denied => {
                    // stay open and let the user retry
                    status = "Denied by the portal - Enter to retry";
                    if (!hint_logged) {
                        hint_logged = true;
                        std.log.warn("portal denied the request; manual grant (plain DBus):", .{});
                        std.log.warn("  busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore SetPermission sbssas screenshot true screenshot shotlet 1 yes", .{});
                    }
                    req.deinit(gpa);
                    pending = null;
                    continue :outer;
                },
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
    return switch (try portal.screenshot(gpa, conn, false, portal.timeout_dialog_ms)) {
        .granted => |d| d,
        .cancelled => null,
        else => error.NoScreenshotPortal,
    };
}

// --- saving ---

/// Where screenshots go: the configured save_dir (with ~ expanded), else the
/// user's XDG Pictures directory.
fn saveDir(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, buf: []u8) ![]u8 {
    if (cfg.saveDir()) |d| return env_mod.expandHome(buf, env.home, d);
    return env_mod.picturesDir(gpa, buf, env.home);
}

/// "shotlet-20260701-140501" in local time.
pub fn baseName(gpa: std.mem.Allocator, env: Env, buf: []u8) ![]u8 {
    const lt = clock.localTime(gpa, env.tz, sys.realtimeSec());
    return std.fmt.bufPrint(buf, "shotlet-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second,
    });
}

/// Save into the screenshots folder. Returns the path written (owned).
pub fn savePng(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, data: []const u8) ![]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try saveDir(gpa, env, cfg, &dir_buf);
    sys.mkdirAll(dir, 0o755); // best effort; may already exist
    var name_buf: [64]u8 = undefined;
    return writeUnique(gpa, dir, try baseName(gpa, env, &name_buf), ".png", data);
}

/// Write `<dir>/<base><ext>`, or `<base>-2<ext>`, `-3`, ... when taken.
/// Never overwrites: each attempt is an O_EXCL create.
pub fn writeUnique(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, data: []const u8) ![]u8 {
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const path = if (n == 1)
            try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, base, ext })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}-{d}{s}", .{ dir, base, n, ext });
        errdefer gpa.free(path);
        sys.writeFileExclusive(path, data, 0o644) catch |err| switch (err) {
            error.PathAlreadyExists => {
                gpa.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.TooManyCollisions;
}

/// Ask where to save with the FileChooser portal. Null when the person
/// cancelled (nothing is written). Falls back to the screenshots folder
/// when there is no FileChooser portal.
pub fn saveAs(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *const config.Config, data: []const u8) !?[]u8 {
    var dir_buf: [1024]u8 = undefined;
    const dir = try saveDir(gpa, env, cfg, &dir_buf);
    sys.mkdirAll(dir, 0o755);
    var name_buf: [64]u8 = undefined;
    const base = try baseName(gpa, env, &name_buf);
    var file_buf: [80]u8 = undefined;
    const current_name = try std.fmt.bufPrint(&file_buf, "{s}.png", .{base});

    const path = switch (try portal.saveFile(gpa, conn, .{ .current_name = current_name, .current_folder = dir })) {
        .granted => |p| p,
        .cancelled, .denied, .timeout => return null,
        .unavailable => {
            std.log.warn("no file chooser portal; saving to {s}", .{dir});
            return try savePng(gpa, env, cfg, data);
        },
    };
    errdefer gpa.free(path);
    if (std.ascii.endsWithIgnoreCase(path, ".png")) {
        // the chooser already confirmed replacing an existing file
        try sys.writeFile(path, data);
        return path;
    }
    // a name typed without extension: add one, but never replace a file
    // the chooser did not ask about
    defer gpa.free(path);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.BadPath;
    return try writeUnique(gpa, path[0..slash], path[slash + 1 ..], ".png", data);
}

test "saved names never overwrite" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-test");
    defer gpa.free(dir);
    defer sys.removeTree(dir);

    const a = try writeUnique(gpa, dir, "shot", ".png", "one");
    defer gpa.free(a);
    const b = try writeUnique(gpa, dir, "shot", ".png", "two");
    defer gpa.free(b);
    const c = try writeUnique(gpa, dir, "shot", ".png", "three");
    defer gpa.free(c);
    try std.testing.expect(std.mem.endsWith(u8, a, "/shot.png"));
    try std.testing.expect(std.mem.endsWith(u8, b, "/shot-2.png"));
    try std.testing.expect(std.mem.endsWith(u8, c, "/shot-3.png"));
    const first = try sys.readFileAlloc(gpa, a, 64);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("one", first);

    // a symlink in the way is not followed
    var link_buf: [512]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/l.png\x00", .{dir});
    _ = std.os.linux.symlinkat("/nonexistent-target", std.os.linux.AT.FDCWD, @ptrCast(link.ptr));
    const d = try writeUnique(gpa, dir, "l", ".png", "x");
    defer gpa.free(d);
    try std.testing.expect(std.mem.endsWith(u8, d, "/l-2.png"));
}

/// Dev: stitch one PNG per monitor, placed left to right in a logical
/// layout of their pixel sizes (as monitors at scale 1 would be).
fn fromMonitorFiles(gpa: std.mem.Allocator, list: []const u8) !capture.Capture {
    var imgs: [8]png.Image = undefined;
    var parts: [8]capture.Part = undefined;
    var n: usize = 0;
    defer for (imgs[0..n]) |*im| im.deinit(gpa);
    var x: i32 = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |path| {
        if (n == imgs.len) return error.TooManyMonitors;
        const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
        defer gpa.free(data);
        imgs[n] = try png.decode(gpa, data);
        const im = &imgs[n];
        parts[n] = .{ .pixels = im.pixels, .width = im.width, .height = im.height, .logical = .{ .x = x, .y = 0, .w = im.width, .h = im.height } };
        x += @intCast(im.width);
        n += 1;
    }
    return capture.stitch(gpa, parts[0..n]);
}

/// Store the editor's beautify settings and the first-run hint flag, only
/// the keys that changed (other settings in the file are left alone).
fn rememberEditorPrefs(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, ed: anytype) void {
    const b = ed.beautify;
    var bg_buf: [8]u8 = undefined;
    var changes: [6]config.Change = undefined;
    var n: usize = 0;
    const tf = struct {
        fn s(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.s;
    if (b.enabled != cfg.beautify) {
        changes[n] = .{ .key = "beautify", .value = tf(b.enabled) };
        n += 1;
    }
    if (b.bg != cfg.beautify_background) {
        changes[n] = .{ .key = "beautify_background", .value = std.fmt.bufPrint(&bg_buf, "{d}", .{b.bg}) catch "0" };
        n += 1;
    }
    if (b.padding != cfg.beautify_padding) {
        changes[n] = .{ .key = "beautify_padding", .value = config.padding_names[b.padding] };
        n += 1;
    }
    if (b.rounded != cfg.beautify_corners) {
        changes[n] = .{ .key = "beautify_corners", .value = tf(b.rounded) };
        n += 1;
    }
    if (b.shadow != cfg.beautify_shadow) {
        changes[n] = .{ .key = "beautify_shadow", .value = tf(b.shadow) };
        n += 1;
    }
    if (ed.hint_seen and !cfg.hint_shown) {
        changes[n] = .{ .key = "hint_shown", .value = "true" };
        n += 1;
    }
    if (n == 0) return;
    config.update(gpa, env.home, changes[0..n]) catch |err|
        std.log.warn("could not save editor settings: {t}", .{err});
}
