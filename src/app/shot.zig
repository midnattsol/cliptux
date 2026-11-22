//! Capture-and-edit flow: acquisition (direct, ScreenCast in
//! shot/screencast.zig, the Screenshot portal with the first-run
//! permission dialog), then copy/save/save-as handling around the editor
//! (files in shot/save.zig).

const std = @import("std");
const capture = @import("capture.zig");
const direct = @import("../platform/linux/capture/direct.zig");
const capture_path = @import("../platform/linux/capture/path.zig");
const config = @import("config.zig");
const dbus = @import("../platform/linux/dbus.zig");
const env_mod = @import("env.zig");
const portal = @import("../platform/linux/portal.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/linux/sys.zig");
const keep_mod = @import("keep.zig");
const history = @import("history.zig");
const annot = @import("annot.zig");
const gnome = @import("../platform/linux/gnome.zig");
const shellcap = @import("../platform/linux/gnome/shellcap.zig");
const modes = @import("modes/mode.zig");
const mode_flow = @import("modes/flow.zig");
const shell_bus = @import("../platform/linux/gnome/shell_bus.zig");
const last_area = @import("modes/last_area.zig");
const save = @import("shot/save.zig");
const handoff = @import("shot/handoff.zig");
const dialog = @import("shot/dialog.zig");
const next = @import("shot/next.zig");
const winrects = @import("../platform/linux/capture/winrects.zig");
const screencast = @import("../platform/linux/capture/screencast.zig").screencast;
const window = @import("../platform/linux/window.zig");
const editor_mod = @import("../ui/editor.zig");
const Env = env_mod.Env;

pub const baseName = save.baseName;
pub const savePng = save.savePng;
pub const writeUnique = save.writeUnique;
pub const saveAs = save.saveAs;

comptime {
    _ = save;
}

fn warmupPw() void {
    _ = @import("../platform/linux/pw.zig").available();
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
    /// the capture mode (app/modes/), and its self-timer
    req: modes.Request = .{},
    /// already taken (a window KWin captured); owned by the capture
    image: ?png.Image = null,

    fn any(self: From) bool {
        return self.file != null or self.monitors != null or self.shell != null or self.image != null;
    }
};

pub fn run(gpa: std.mem.Allocator, env: Env, from: From, preset_sel: ?[4]i32, smoke_ms: i64) !void {
    var t: Startup = .{ .t0 = nowMs() };
    var conn = try dbus.Connection.connectSession(gpa, env.bus_addr);
    defer conn.deinit();
    t.dbus = nowMs();
    if (!from.any() and handedToShell(gpa, env, &conn, from.req, t.t0)) return;

    // dlopen(libpipewire) costs ~50-80ms; overlap it with the rest of setup
    const pw_thread = if (from.any()) null else std.Thread.spawn(.{}, warmupPw, .{}) catch null;
    portal.registerApp(gpa, &conn);
    t.scope = nowMs();

    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    t.config = nowMs();

    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    t.wayland = nowMs();

    if (pw_thread) |th| th.join();
    t.pw = nowMs();
    // the self-timer, where the GNOME extension did not count down
    if (from.req.delay_s > 0 and !from.any() and !try @import("../ui/countdown.zig").run(&win, from.req.delay_s)) return;
    var cap = (try acquire(gpa, env, &conn, &cfg, from)) orelse {
        std.log.info("capture cancelled", .{});
        return;
    };
    defer cap.deinit(gpa);
    if (from.req.delay_s > 0) win.closeWindow();
    t.capture = nowMs();
    var edit = switch (try mode_flow.afterCapture(.{ .gpa = gpa, .env = env, .conn = &conn, .cfg = &cfg, .win = &win }, &cap, from.req)) {
        .done => return,
        .edit => |e| e,
    };
    // where the windows were, for clicking one (an area to pick)
    if (edit.modes) edit.windows = winrects.fetch(gpa, env, &conn, &cap, if (from.shell) |s| s.id else null);
    defer gpa.free(edit.windows);
    edit.from_shell = from.shell != null;
    if (edit.modes) edit.window_ok = winrects.windowCapture(&conn);

    try openEditor(&win, &cap, perMonitor(&cap));
    t.open = nowMs();
    t.log(from.shell);
    try editAndFinish(gpa, env, &conn, &cfg, &win, &cap, preset_sel, smoke_ms, null, edit);
}

/// With the GNOME Shell extension, the shell takes the screenshot (no
/// prompt) and starts another shotlet on it. True when it took over (or
/// declined): this process has nothing left to do.
fn handedToShell(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, req: modes.Request, t0: i64) bool {
    if (!gnome.isGnome() or !gnome.extensionActive(conn)) return false;
    @import("../ui/tools/launch.zig").handOff(env.runtime_dir);
    switch (shell_bus.requestMode(gpa, conn, req)) {
        .started => {
            std.log.info("capture handed to the GNOME integration ({d}ms)", .{nowMs() - t0});
            return true;
        },
        .declined => return true,
        .unavailable => return false,
    }
}

/// One fullscreen surface per monitor when the layout is known.
fn perMonitor(cap: *const capture.Capture) bool {
    return cap.monitors.len > 1 and for (cap.monitors) |m| {
        if (m.logical == null) break false;
    } else true;
}

/// Startup timestamps (ms), logged once the editor is open.
const Startup = struct {
    t0: i64,
    dbus: i64 = 0,
    scope: i64 = 0,
    config: i64 = 0,
    wayland: i64 = 0,
    pw: i64 = 0,
    capture: i64 = 0,
    open: i64 = 0,

    fn log(t: Startup, shell: ?shellcap.Args) void {
        std.log.info("startup: capture={d}ms total={d}ms", .{ t.capture - t.t0, t.open - t.t0 });
        if (shell) |sh| if (sh.t0_ms) |key| {
            std.log.info("GNOME integration: key press to editor {d}ms (shell capture and launch {d}ms)", .{ t.open - key, t.t0 - key });
        };
        std.log.debug("startup detail: dbus={d}ms scope={d}ms config={d}ms wayland={d}ms pw-wait={d}ms capture={d}ms open={d}ms", .{
            t.dbus - t.t0,
            t.scope - t.dbus,
            t.config - t.scope,
            t.wayland - t.config,
            t.pw - t.wayland,
            t.capture - t.pw,
            t.open - t.capture,
        });
    }
};

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
pub fn editAndFinish(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config, win: anytype, cap: *capture.Capture, preset_sel: ?[4]i32, smoke_ms: i64, reopen: ?Reopen, edit: mode_flow.Edit) !void {
    var ed = editor_mod.Editor.init(gpa, win, &cap.image);
    ed.monitors = cap.monitors;
    configureEditor(&ed, conn, cfg, smoke_ms);
    ed.presetSelection(preset_sel);
    if (edit.sel) |r| ed.doc.sel = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    ed.keep_alpha = edit.keep_alpha;
    const ctx: mode_flow.Ctx = .{ .gpa = gpa, .env = env, .conn = conn, .cfg = cfg, .win = win };
    ed.capmode = .{ .on = edit.modes, .windows = edit.windows, .window_ok = edit.window_ok, .screen_in_place = edit.modes and mode_flow.screenOpensEditor(ctx) };
    defer ed.deinit();
    if (reopen) |r| try restoreReopened(gpa, &ed, r);
    while (true) {
        const result = try ed.run();
        if (reopen == null) @import("editor_prefs.zig").remember(gpa, env, cfg, &ed);
        defer if (result.png_data) |d| gpa.free(d);
        if (reopen == null and (result.action == .copied or result.action == .save or result.action == .save_as)) if (ed.doc.sel) |r|
            last_area.remember(gpa, env.home, cap, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });

        const f: Finish = .{ .gpa = gpa, .env = env, .conn = conn, .cfg = cfg, .win = win, .ed = &ed, .replace = if (reopen) |r| r.kept else null };
        switch (result.action) {
            // the mode strip's other capture modes (shot/next.zig)
            .new_capture => next.restart(ctx, &ed),
            .screen => try next.screen(ctx, &ed, cap),
            .record => try next.record(ctx, &ed, cap, edit.from_shell),
            .cancel, .copied => try f.closed(result.action == .copied),
            .save, .save_as => if (!try f.saved(result.action == .save, result.png_data.?)) {
                // the file chooser (over the editor) was cancelled or the
                // file could not be written: back to the editor,
                // annotations intact, rather than losing the work
                ed.running = true;
                ed.action = .cancel;
                continue;
            },
        }
        return;
    }
}

/// The editor's settings from the config and the desktop's light/dark
/// preference, accent and reduced motion.
fn configureEditor(ed: *editor_mod.Editor, conn: *dbus.Connection, cfg: *const config.Config, smoke_ms: i64) void {
    const theme = @import("../ui/theme.zig");
    ed.setPrefs(theme.readPrefs(conn, 1500));
    theme.watch(conn) catch {};
    ed.bus = conn;
    if (smoke_ms > 0) ed.smoke_deadline_ms = nowMs() + smoke_ms;
    ed.cfg_thickness = cfg.default_thickness;
    ed.color_idx = cfg.default_color;
    ed.binds = cfg.binds;
    ed.beautify = .{
        .enabled = cfg.beautify_always,
        .bg = cfg.beautify_background,
        .padding = cfg.beautify_padding,
        .rounded = cfg.beautify_corners,
        .shadow = cfg.beautify_shadow,
    };
    ed.beautify_always = cfg.beautify_always;
    ed.show_hint = !cfg.hint_shown;
}

/// A reopened capture: the shapes as they were, still editable.
fn restoreReopened(gpa: std.mem.Allocator, ed: *editor_mod.Editor, r: Reopen) !void {
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

/// What happens after the editor closed with a result.
const Finish = struct {
    gpa: std.mem.Allocator,
    env: Env,
    conn: *dbus.Connection,
    cfg: *config.Config,
    win: *window.Window,
    ed: *editor_mod.Editor,
    /// the history entry a reopened capture updates
    replace: ?keep_mod.Kept,

    /// Cancel or Copy: the window closes; a copy is kept and served.
    fn closed(f: Finish, copied: bool) !void {
        // the clipboard's copy may be dropped while the editor fades
        const data: ?[]u8 = if (!copied) null else if (f.win.clipboardPng()) |d| f.gpa.dupe(u8, d) catch null else null;
        defer if (data) |d| f.gpa.free(d);
        f.close(data, "");
        if (f.win.hasClipboard()) try f.win.serveClipboard();
    }

    /// Save (`quick`: to the screenshots folder) or Save As. False when
    /// the file chooser was cancelled or writing failed (the editor says
    /// why). Save writes before the editor closes, so a failure keeps it.
    fn saved(f: Finish, quick: bool, data: []const u8) !bool {
        const gpa = f.gpa;
        if (f.cfg.copy_on_save) {
            const copy = try gpa.dupe(u8, data);
            f.win.setClipboardPng(copy) catch |err| {
                gpa.free(copy);
                std.log.warn("copy-on-save failed: {t}", .{err});
            };
        }
        const path = f.write(quick, data) orelse return false;
        defer gpa.free(path);
        // the thumbnail says it already
        if (f.cfg.notify and !f.cfg.showsThumbnail(true)) {
            var buf: [512]u8 = undefined;
            portal.notify(gpa, f.conn, "Shotlet", std.fmt.bufPrint(&buf, "Saved to {s}", .{path}) catch "Saved");
        }
        f.close(data, path);
        if (f.win.hasClipboard()) try f.win.serveClipboard();
        return true;
    }

    /// The file written (owned); null when the chooser was cancelled or
    /// writing failed, which the editor (still open) shows.
    fn write(f: Finish, quick: bool, data: []const u8) ?[]u8 {
        return f.writeFile(quick, data) catch |err| {
            std.log.warn("could not save: {t}", .{err});
            var buf: [160]u8 = undefined;
            f.ed.tools.toast.show(.problem, save.failureText(&buf, err), 6000);
            f.ed.needs_render = true;
            return null;
        };
    }

    fn writeFile(f: Finish, quick: bool, data: []const u8) !?[]u8 {
        if (quick) return try savePng(f.gpa, f.env, f.cfg, data);
        return dialog.saveAs(f.gpa, f.env, f.conn, f.cfg, f.win, data);
    }

    /// The editor fades out and closes; `data` (what was copied or
    /// saved) is kept for the history and the thumbnail meanwhile.
    fn close(f: Finish, data: ?[]const u8, saved_path: []const u8) void {
        const ed = f.ed;
        const what: ?keep_mod.What = if (data) |d| .{ .image_png = d, .source = ed.img, .doc = &ed.doc, .beautify = ed.beautify, .saved = saved_path, .replace = f.replace } else null;
        handoff.close(.{ .gpa = f.gpa, .env = f.env, .cfg = f.cfg, .win = f.win, .ed = ed }, what, f.cfg.showsThumbnail(saved_path.len > 0));
        ed.releaseCaches(); // serving may outlive the session; drop ~140MB
    }
};

/// `shotlet edit ROOT ID`: open a kept capture in the editor again, with
/// its annotations; Copy or Save update the same entry.
pub fn runEdit(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
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
    try editAndFinish(gpa, env, &conn, &cfg, &win, &cap, null, 0, .{ .kept = kept, .doc = &doc }, .{});
}

/// Get the image to edit. Null means the person cancelled a dialog: the
/// caller exits quietly, with no fallback and no further dialogs.
pub fn acquire(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection, cfg: *config.Config, from: From) !?capture.Capture {
    if (from.any()) return try fromGiven(gpa, env, from);
    // the desktop's own capture interface: no consent dialog
    if (std.c.getenv("SHOTLET_NO_DIRECT") == null) {
        if (tryDirect(gpa, env, conn)) |cap| return cap;
    }
    if (@import("../platform/linux/pw.zig").available()) {
        switch (screencast(gpa, env, conn, cfg)) {
            .granted => |cap| {
                std.log.info("capture path: portal (ScreenCast)", .{});
                capture_path.remember(env.home, .portal);
                return cap;
            },
            .cancelled => return null,
            .timeout => return dialogTimedOut(),
            .denied => std.log.info("screencast denied; trying the screenshot portal", .{}),
            .unavailable => std.log.info("screencast unavailable; trying the screenshot portal", .{}),
        }
    }
    return screenshotPortal(gpa, env, conn);
}

/// A capture that is already taken: by the GNOME extension, KWin, or a
/// dev source.
fn fromGiven(gpa: std.mem.Allocator, env: Env, from: From) !capture.Capture {
    if (from.shell) |args| {
        const t_load = nowMs();
        const cap = try shellcap.load(gpa, env.runtime_dir, args);
        capture_path.remember(env.home, .gnome);
        std.log.info("  capture detail: monitors={d} through the GNOME integration (decode+stitch {d}ms)", .{ cap.monitors.len, nowMs() - t_load });
        return cap;
    }
    if (from.image) |img| return try capture.Capture.single(gpa, img);
    if (from.monitors) |list| return try fromMonitorFiles(gpa, list);
    const data = try sys.readFileAlloc(gpa, from.file.?, 256 * 1024 * 1024);
    defer gpa.free(data);
    var img = try png.decode(gpa, data);
    errdefer img.deinit(gpa);
    return try capture.Capture.single(gpa, img);
}

/// The compositor's own capture interface; null (logged) when there is
/// none or it failed, for the portal to take over.
fn tryDirect(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) ?capture.Capture {
    const res = direct.captureAll(gpa, env.runtime_dir, env.wayland_display, conn) catch |err| {
        std.log.info("capture path: direct capture failed ({t}); the portal", .{err});
        return null;
    };
    switch (res) {
        .captured => |c| {
            std.log.info("capture path: direct ({s})", .{c.method.label()});
            capture_path.remember(env.home, .direct);
            return c.cap;
        },
        .unavailable => |why| {
            std.log.info("capture path: no direct capture ({s}); the portal", .{why});
            return null;
        },
    }
}

/// The Screenshot portal, the last resort; null when cancelled.
fn screenshotPortal(gpa: std.mem.Allocator, env: Env, conn: *dbus.Connection) !?capture.Capture {
    std.log.info("capture path: portal (Screenshot)", .{});
    capture_path.remember(env.home, .portal);
    const png_data = switch (try portal.screenshot(gpa, conn, false, portal.timeout_unfocused_screenshot_ms)) {
        .granted => |d| d,
        .cancelled => return null,
        // GNOME only shows its consent dialog to the focused app, so a
        // windowless first run is denied (or, with no app focused, never
        // answered); ask again from a focused window
        .denied, .timeout => (try @import("../platform/linux/capture/first_run.zig").permissionFlow(gpa, env, conn)) orelse return null,
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
