//! What each Settings control does when clicked or activated with
//! Space / Enter. Config changes are saved at once.

const std = @import("std");
const config = @import("../../app/config.zig");
const portal = @import("../../platform/linux/portal.zig");
const gnome = @import("../../app/gnome.zig");
const history = @import("../../app/history.zig");
const keep = @import("../../app/keep.zig");
const settings_modes = @import("../settings_modes.zig");
const settings_rec = @import("../recui/settings_rec.zig");
const steps = @import("../settings_steps.zig");
const model = @import("model.zig");
const App = @import("app.zig").App;

const Hit = model.Hit;

/// Perform a control's action. Returns true when the window should close.
pub fn activate(app: *App, hit: Hit) bool {
    const st = &app.st;
    // anything else backs out of Clear history's question
    if (st.history_clear == .asking and hit != .clear_history) {
        st.history_clear = .idle;
        st.dirty = true;
    }
    switch (hit) {
        .view => |v| showView(st, v),
        .forget_monitors => forgetMonitors(app),
        .reset_permissions => @import("permissions.zig").resetAll(app),
        .choose_folder => chooseFolder(app),
        .bind => |action| {
            st.recording = if (st.recording == action) null else action;
            st.dirty = true;
        },
        .open_history => keep.spawnSelf(st.env, &.{"history"}),
        .clear_history => clearHistory(app),
        .gnome_enable => enableGnome(app),
        .mode => |h| {
            settings_modes.activate(h, &st.modes, app.alloc, st.env);
            st.dirty = true;
        },
        .win_close => {
            app.saveConfig();
            return true;
        },
        else => {
            applyConfig(app, hit);
            app.saveConfig();
            st.dirty = true;
        },
    }
    return false;
}

fn showView(st: *model.State, v: model.View) void {
    if (st.view != v) {
        st.view = v;
        st.scroll_y = 0;
        st.recording = null;
    }
    st.dirty = true;
}

/// The controls that only change a config value (saved by the caller).
fn applyConfig(app: *App, hit: Hit) void {
    const cfg = &app.cfg;
    switch (hit) {
        .rec => |r| settings_rec.activate(app.alloc, app.env.home, r),
        .toggle_notify => cfg.notify = !cfg.notify,
        .toggle_copy_on_save => cfg.copy_on_save = !cfg.copy_on_save,
        .th_minus => cfg.default_thickness = @max(1, cfg.default_thickness - 1),
        .th_plus => cfg.default_thickness = @min(32, cfg.default_thickness + 1),
        .color => |c| cfg.default_color = c,
        .reset_binds => cfg.binds = config.default_binds,
        .cycle_thumbnail => cfg.thumbnail = @fromBackingInt(@intCast((@backingInt(cfg.thumbnail) + 1) % 3)),
        .quick_minus, .quick_plus => cfg.quick_access_seconds = steps.stepSeconds(cfg.quick_access_seconds, hit == .quick_plus),
        .toggle_history => cfg.history = !cfg.history,
        .hist_minus, .hist_plus => cfg.history_max = steps.stepCount(cfg.history_max, hit == .hist_plus),
        .hist_mb_minus, .hist_mb_plus => cfg.history_max_mb = steps.stepMb(cfg.history_max_mb, hit == .hist_mb_plus),
        else => unreachable,
    }
}

fn forgetMonitors(app: *App) void {
    // only this key changes; the next capture shows the picker
    app.cfg.setScToken("");
    config.saveScreencastToken(app.alloc, app.env.home, "") catch |err|
        std.log.warn("could not save config: {t}", .{err});
    app.st.dirty = true;
}

/// Open the portal's folder chooser (its answer arrives on the bus).
fn chooseFolder(app: *App) void {
    app.st.dirty = true;
    if (app.folder_req != null) return;
    const conn = app.busPtr() orelse {
        std.log.warn("no session bus: cannot show the folder chooser", .{});
        return;
    };
    app.folder_req = portal.beginChooseFolder(app.alloc, conn, .{ .current_folder = app.cfg.saveDir() }) catch |err| blk: {
        std.log.warn("folder chooser: {t}", .{err});
        break :blk null;
    };
}

/// The first click asks, the second clears.
fn clearHistory(app: *App) void {
    app.st.dirty = true;
    if (app.st.history_clear != .asking) {
        app.st.history_clear = .asking;
        return;
    }
    var buf: [1024]u8 = undefined;
    if (history.historyRoot(&buf, app.env.home)) |root| history.clear(root) else |_| {}
    std.log.info("history cleared from Settings", .{});
    app.st.history_clear = .cleared;
}

fn enableGnome(app: *App) void {
    const st = &app.st;
    const bus = app.busPtr();
    st.gnome = switch (gnome.install(app.alloc, st.env, bus, .yes)) {
        .active => .active,
        .installed_relogin => .installed,
        .failed => .failed,
    };
    if (st.gnome == .active) if (bus) |b| {
        st.capture = gnome.captureInfo(app.alloc, b);
    };
    st.dirty = true;
}
