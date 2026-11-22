//! Pin to screen (`shotlet pin FILE`): a small frameless window showing a
//! capture at 1:1 (one image pixel per screen pixel). Scroll to zoom, drag
//! to move, Esc or the close button to close; several pins can be open.
//!
//! Its menu (right-click, the ⋯ button on hover, or the Menu key) copies,
//! saves or annotates the picture, sets its opacity, locks it in place
//! (clicks go through it but for a badge that unlocks it) and closes it
//! or every pin; a focused pin takes the menu's shortcuts.
//!
//! With zwlr_layer_shell_v1 (KDE, wlroots) the pin is a top-layer surface,
//! above normal windows, moved by changing its margins. On GNOME it is a
//! regular toplevel titled "shotlet:pin": the Shotlet GNOME Shell
//! extension keeps it above other windows; without the extension GNOME
//! cannot keep a Wayland window on top unless the person chooses "Always
//! on Top" in the window menu (the pin's menu has Keep on Top for it, and
//! the pin says so when it appears).
//!
//! Pinned from the editor, the thumbnail or Recent captures it opens where
//! the capture was (`--at`, the centre in logical pixels: the margins of
//! a layer surface, or the extension places a toplevel titled
//! "shotlet:pin:X:Y" with the picture's top-left there), and it fades in
//! rather than zooming from nowhere.
//!
//! Facade over pin/: state (the window), view (zoom, opacity), draw and
//! chrome, menu and menu_draw, input and keys, actions, annotate, ipc.

const std = @import("std");
const shell = @import("../platform/api.zig").shell;
const desktop = @import("../platform/api.zig").desktop;
const sys = @import("../platform/api.zig").sys;
const window = @import("../platform/api.zig").window;
const env_mod = @import("env.zig");
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const theme = @import("../ui/theme.zig");
const motion = @import("../ui/motion.zig");
const state = @import("pin/state.zig");
const view = @import("pin/view.zig");
const draw = @import("pin/draw.zig");
const input = @import("pin/input.zig");
const annotate = @import("pin/annotate.zig");
const ipc = @import("pin/ipc.zig");
const Env = env_mod.Env;
const Pin = state.Pin;

pub const zoom_min = view.zoom_min;
pub const zoom_max = view.zoom_max;
pub const zoomStep = view.zoomStep;

/// "X,Y" as `--at` takes it.
pub const parseAt = @import("history.zig").parsePoint;

/// `shotlet pin FILE [--at X,Y]`: PNG, JPEG or WebP
/// (src/gfx/imgload.zig), centred on X,Y when given.
pub fn run(gpa: std.mem.Allocator, env: Env, path: []const u8, at: ?[2]i32) !void {
    var img = try @import("../gfx/imgload.zig").loadFile(gpa, path);
    defer img.deinit(gpa);
    return show(gpa, env, &img, path, at);
}

/// Pin `img` (`what` names it in the log) until the pin is closed;
/// centred on `at` (logical pixels) when given. Annotate may replace
/// `img` (the caller still frees it).
pub fn show(gpa: std.mem.Allocator, env: Env, img: *png.Image, what: []const u8, at: ?[2]i32) !void {
    text.init(gpa);
    defer text.deinit();

    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    var pin: Pin = .{ .gpa = gpa, .env = env, .win = &win, .img = img, .th = theme.Theme.get(false, null), .layer = win.hasLayerShell(), .born = sys.monoMs(), .at = at };
    defer pin.deinit();
    askDesktop(&pin);
    pin.ipc = ipc.Listener.open(env);
    try pin.open();
    std.log.info("pin: showing {s} ({d}x{d}, {s})", .{ what, img.width, img.height, if (pin.layer) "layer shell" else if (pin.plain) "plain window" else "kept above by the GNOME extension" });
    try loop(&pin);
    std.log.info("pin: closed", .{});
    pin.ipc.close();
    win.closeWindow();
    if (win.hasClipboard()) {
        std.log.info("pin: serving the clipboard", .{});
        try win.serveClipboard();
    }
}

/// The desktop's appearance for the menu, and whether anything keeps the
/// pin above (GNOME without the Shotlet extension cannot): one short
/// session connection.
fn askDesktop(p: *Pin) void {
    const toplevel = !p.layer and shell.applies();
    var bus = desktop.connectBrief(p.gpa, p.env) catch {
        p.plain = toplevel;
        p.hint = toplevel;
        return;
    };
    defer bus.deinit();
    const prefs = theme.readPrefs(&bus, 300);
    p.th = theme.of(prefs);
    motion.enabled = prefs.animations;
    p.plain = toplevel and !shell.active(&bus);
    p.hint = p.plain;
}

/// The window's events, Close All Pins from another pin and the editor's
/// answer, until the pin is closed.
fn loop(p: *Pin) !void {
    while (!p.quit) {
        const k = p.scale();
        const now = sys.monoMs();
        if (p.menu.close_at != 0 and now >= p.menu.close_at) p.closeMenu(now);
        p.settleMenu(now);
        try p.fitWindow(k);
        const moving = draw.animating(p, now);
        if (moving) p.dirty = true;
        if (p.hint and !draw.hintShown(p, now)) {
            // its time is up: once more without it
            p.hint = false;
            p.dirty = true;
        }
        if (p.dirty and !p.win.frame_pending and p.win.width > 0) {
            p.dirty = false;
            try draw.frame(p, k);
        }
        try p.win.flush();
        var fds = [_]sys.pollfd{
            .{ .fd = p.win.pollFd(), .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = p.ipc.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = if (p.edit) |e| e.fd else -1, .events = sys.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&fds, p.win.pollTimeoutMs(wakeMs(p, now, moving)));
        while (try p.win.nextEventTimeout(0)) |ev| try input.handle(p, ev);
        if (fds[1].revents != 0 and p.ipc.closeAsked()) {
            std.log.info("pin: closing, as another pin asked", .{});
            p.quit = true;
        }
        if (fds[2].revents != 0) annotate.pump(p);
    }
}

/// How long the loop may sleep: a frame while something moves, until the
/// hint goes or the menu closes, else a while.
fn wakeMs(p: *const Pin, now: i64, moving: bool) i32 {
    if (moving) return 16;
    var ms: i64 = 1000;
    if (p.hint) ms = @max(0, p.born + draw.hint_ms - now);
    if (p.menu.close_at != 0) ms = @min(ms, @max(0, p.menu.close_at - now));
    return @intCast(ms);
}

comptime {
    _ = state;
    _ = view;
    _ = draw;
    _ = @import("pin/menu.zig");
    _ = @import("pin/chrome.zig");
    _ = @import("pin/keys.zig");
    _ = ipc;
}
