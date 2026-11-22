//! Quick access: the floating thumbnails shown after Copy or Save
//! (`shotlet quick ROOT ID`). One process shows every thumbnail: a later
//! capture hands its entry to the running one over a unix socket in the
//! runtime directory, and the thumbnails stack in the bottom-left corner,
//! newest nearest the corner.
//!
//! Placement:
//! - with zwlr_layer_shell_v1 (KDE, wlroots): an overlay layer surface
//!   anchored bottom-left, exclusive zone 0, keyboard focus on demand
//!   only while the pointer is over it (some compositors focus on-demand
//!   surfaces as they map);
//! - on GNOME (no layer shell in mutter): a small transparent toplevel
//!   titled "shotlet:quick". The Shotlet GNOME Shell extension
//!   (gnome-extension/, `shotlet gnome-integration install`) places it
//!   bottom-left, keeps it above other windows on every workspace and
//!   gives keyboard focus back to the app the person was in. Without the
//!   extension it is an ordinary window wherever mutter puts it, with a
//!   one-line hint to enable the integration.
//!
//! In both cases only the cards take input: the shadow around them is
//! outside the input region, so clicks there reach the window below.
//!
//! Facade over quick/: layout (the stack and hit testing), stack (state,
//! hand-off socket, window), actions, input (and the cards' timing) and
//! card (drawing).

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const shell = @import("../platform/api.zig").shell;
const clipimg = @import("clipimg.zig");
const quick_ipc = @import("quick_ipc.zig");
const sys = @import("../platform/api.zig").sys;
const text = @import("../gfx/text.zig");
const window = @import("../platform/api.zig").window;
const theme_mod = @import("../ui/theme.zig");
const layout = @import("quick/layout.zig");
const Quick = @import("quick/stack.zig").Quick;
const Env = env_mod.Env;

pub const card_w = layout.card_w;
pub const card_h = layout.card_h;
pub const Control = layout.Control;
pub const menu_items = layout.menu_items;
pub const Action = layout.Action;
pub const Hit = layout.Hit;
pub const cardRect = layout.cardRect;
pub const windowSize = layout.windowSize;
pub const controlRect = layout.controlRect;
pub const hitTest = layout.hitTest;
pub const parseAdd = quick_ipc.parseAdd;

/// `ready`: a pipe to write to once the first frame is committed (the
/// editor stays until then); handing off to a running stack, or failing,
/// closes it as this process ends.
pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8, ready: ?sys.fd_t) !void {
    if (!history.Id.valid(id)) return error.BadId;
    // another thumbnail stack is up: join it
    if (quick_ipc.handOff(env, root, id)) return;

    text.init(gpa);
    defer text.deinit();
    var q: Quick = .{
        .gpa = gpa,
        .env = env,
        .cfg = config.load(gpa, env.home),
        .win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display),
        .ready_fd = ready orelse -1,
    };
    defer q.deinit();
    if (!q.listen()) {
        // lost a race with another newcomer: it shows ours too
        if (quick_ipc.handOff(env, root, id)) return;
    }
    if (!q.cfg.history) pruneCache(gpa, env);
    setup(&q);
    try q.add(root, id);
    std.log.info("quick access: showing {s} ({s})", .{ id, if (q.layer) "layer shell" else if (q.hint) "plain window" else "window placed by the GNOME extension" });
    try loop(&q);
    // newcomers start their own stack from here on
    q.stopListening();
    q.win.closeWindow();
    if (q.win.hasClipboard()) {
        std.log.info("quick access: serving the clipboard", .{});
        try q.win.serveClipboard();
    }
}

/// Without history the captures live in the cache: keep it small.
fn pruneCache(gpa: std.mem.Allocator, env: Env) void {
    var cb: [1024]u8 = undefined;
    if (history.cacheRoot(&cb, env.home)) |cache| {
        _ = history.prune(gpa, cache, 30, 512 * 1024 * 1024) catch 0;
    } else |_| {}
}

/// The desktop's accent, the GNOME hint, and dropping images.
fn setup(q: *Quick) void {
    if (q.bus_()) |b| q.accent = theme_mod.of(theme_mod.readPrefs(b, 500)).accent_fill;
    if (!q.win.hasLayerShell() and shell.applies()) {
        q.hint = if (q.bus_()) |b| !shell.active(b) else true;
        if (q.hint) std.log.info("quick access: no Shotlet GNOME Shell extension; the thumbnail is an ordinary window", .{});
    }
    // an image dropped on a thumbnail opens in the editor
    q.win.accept_mimes = &clipimg.drop_mimes;
}

/// Wayland events, newcomers on the socket and the cards' timers, until
/// the last card is gone.
fn loop(q: *Quick) !void {
    while (q.cards.items.len > 0) {
        try q.win.conn.flush();
        var fds = [_]sys.pollfd{
            .{ .fd = q.win.conn.fd, .events = sys.POLL.IN, .revents = 0 },
            .{ .fd = q.listen_fd, .events = sys.POLL.IN, .revents = 0 },
        };
        const nfds: usize = if (q.listen_fd >= 0) 2 else 1;
        _ = try sys.poll(fds[0..nfds], q.win.pollTimeoutMs(q.nextWakeMs()));
        while (try q.win.nextEventTimeout(0)) |ev| q.onEvent(ev);
        if (nfds == 2 and fds[1].revents != 0) q.acceptClients();
        q.checkDrag();
        clipimg.takeDrop(q.gpa, q.env, &q.win);
        q.tick();
        if (q.cards.items.len == 0) break;
        try q.render();
    }
}

comptime {
    _ = layout;
}
