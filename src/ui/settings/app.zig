//! The Settings window's session and event loop: the session bus
//! (appearance changes, the folder chooser's answer), keyboard and pointer
//! input, and redrawing when something changed.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const window = @import("../../platform/api.zig").window;
const config = @import("../../app/config.zig");
const text = @import("../../gfx/text.zig");
const theme_mod = @import("../theme.zig");
const icons = @import("../icons.zig");
const sys = @import("../../platform/api.zig").sys;
const env_mod = @import("../../app/env.zig");
const shell = @import("../../platform/api.zig").shell;
const platform_capture = @import("../../platform/api.zig").capture;
const settings_modes = @import("../settings_modes.zig");
const model = @import("model.zig");
const focus = @import("focus.zig");
const actions = @import("actions.zig");
const draw_mod = @import("draw.zig");
const frame_mod = @import("../frame.zig");

const Window = window.Window;
const Region = model.Region;

/// What the loop does after an event.
const Next = enum {
    keep,
    /// leave the loop (the config is saved once more)
    close,
    /// return at once (the close button saved already)
    quit,
};

pub const App = struct {
    alloc: std.mem.Allocator,
    env: env_mod.Env,
    cfg: config.Config,
    st: model.State,
    win: *Window,
    bus: *?desktop.Session,
    regions: std.ArrayList(Region) = .empty,
    folder_req: ?desktop.Dialog = null,
    frame: frame_mod.Frame = .{},

    /// The content's height and scale, for scrolling.
    fn viewport(self: *const App) model.Viewport {
        return .{ .h = @intCast(self.frame.ch), .f = @as(f64, @floatFromInt(self.win.scale120)) / 120.0 };
    }

    pub fn busPtr(self: *App) ?*desktop.Session {
        return if (self.bus.*) |*b| b else null;
    }

    pub fn saveConfig(self: *App) void {
        config.save(self.alloc, self.env.home, &self.cfg) catch |err|
            std.log.warn("could not save config: {t}", .{err});
    }

    /// Appearance changes and the folder chooser's answer.
    fn pollBus(self: *App, b: *desktop.Session) void {
        if (desktop.pump(b, self.alloc, &self.st.prefs, if (self.folder_req) |*r| r else null)) {
            self.st.theme = theme_mod.of(self.st.prefs);
            self.st.dirty = true;
        }
        if (self.folder_req) |*r| if (r.done()) {
            switch (desktop.dialogChoice(self.alloc, r)) {
                .chosen => |p| self.takeChosenFolder(p),
                .cancelled, .unavailable => {},
            }
            r.deinit(self.alloc);
            self.folder_req = null;
            self.st.dirty = true;
        };
    }

    /// Save into the folder the chooser gave (`p` is consumed).
    fn takeChosenFolder(self: *App, p: []u8) void {
        defer self.alloc.free(p);
        if (p.len <= self.cfg.save_dir.len) {
            @memcpy(self.cfg.save_dir[0..p.len], p);
            self.cfg.save_dir_len = p.len;
            self.saveConfig();
        } else std.log.warn("folder path too long: {s}", .{p});
    }

    fn onEvent(self: *App, ev: window.InputEvent) !Next {
        switch (ev) {
            .resize => {
                // keep the focused control in view at the new size
                self.st.dirty = true;
                self.st.reveal_focus = true;
            },
            .frame_done => {},
            .close => return .close,
            .key => |k| return self.onKey(k),
            .pointer_axis => |a| {
                var step: i32 = @intFromFloat(a.value * 12.0 * @as(f64, @floatFromInt(self.win.scale120)) / 120.0);
                if (step == 0 and a.value != 0) step = if (a.value > 0) 1 else -1;
                self.st.scrollBy(step, self.viewport());
            },
            .pointer_motion => |m| self.onMotion(@intFromFloat(frame_mod.Frame.toContent(self.win, m.x)), @intFromFloat(frame_mod.Frame.toContent(self.win, m.y))),
            .pointer_button => |b| {
                if (b.button != .left or !b.pressed) return .keep;
                return self.onClick(@intFromFloat(frame_mod.Frame.toContent(self.win, b.x)), @intFromFloat(frame_mod.Frame.toContent(self.win, b.y)));
            },
        }
        return .keep;
    }

    fn onKey(self: *App, k: window.Key) Next {
        const st = &self.st;
        if (!k.pressed or k.code == .none) return .keep;
        if (!k.repeat and settings_modes.onKey(&st.modes, k, self.alloc, self.env)) {
            st.dirty = true;
            return .keep;
        }
        if (st.recording) |action| {
            if (!k.repeat) self.recordBind(action, k);
            return .keep;
        }
        switch (focus.keyCommand(k)) {
            .close => return .close,
            .next => st.moveFocus(self.regions.items, self.viewport(), true),
            .prev => st.moveFocus(self.regions.items, self.viewport(), false),
            .activate => if (st.focus) |hit| {
                if (k.repeat) return .keep;
                if (actions.activate(self, hit)) return .quit;
            },
            .none => {},
        }
        return .keep;
    }

    /// The key combination pressed while a shortcut row is listening
    /// becomes that action's binding (Esc cancels).
    fn recordBind(self: *App, action: config.Action, k: window.Key) void {
        const st = &self.st;
        if (k.code == .escape) {
            st.recording = null;
            st.dirty = true;
            return;
        }
        // ignore bare modifiers, wait for the real key; keys with no
        // name (media keys) cannot be bound
        if (k.code.isModifier() or k.code == .other) return;
        const new_bind = config.Bind{ .code = k.code, .ctrl = k.ctrl, .shift = k.shift };
        // clear any other action using the same combo
        for (&self.cfg.binds, 0..) |*b, i| {
            if (i != @backingInt(action) and b.matches(k.code, k.ctrl, k.shift)) {
                b.* = .{};
            }
        }
        self.cfg.binds[@backingInt(action)] = new_bind;
        st.recording = null;
        self.saveConfig();
        st.dirty = true;
    }

    fn onMotion(self: *App, x: i32, y: i32) void {
        self.st.mouse_x = x;
        self.st.mouse_y = y;
        // redraw only when the hovered control changes
        var hover: i32 = -1;
        for (self.regions.items, 0..) |r, ri| {
            if (r.contains(x, y)) {
                hover = @intCast(ri);
                break;
            }
        }
        if (hover != self.st.hover_idx) {
            self.st.hover_idx = hover;
            self.st.dirty = true;
        }
    }

    fn onClick(self: *App, px: i32, py: i32) !Next {
        const hh = model.headerHeight(self.viewport().f);
        for (self.regions.items) |r| {
            if (!r.contains(px, py)) continue;
            // content scrolled under the fixed header must not
            // swallow clicks meant for the header's controls
            if (py < hh and !focus.isHeader(r.hit)) continue;
            // clicking moves keyboard focus there too
            if (focus.isFocusable(r.hit)) self.st.focus = r.hit;
            return if (actions.activate(self, r.hit)) .quit else .keep;
        }
        if (self.st.recording != null) {
            self.st.recording = null;
            self.st.dirty = true;
        } else if (py < hh) {
            // drag the window by its header bar
            try self.win.startMove();
        }
        return .keep;
    }

    fn redraw(self: *App) !void {
        const st = &self.st;
        if (!st.dirty or self.win.frame_pending or self.win.width == 0) return;
        st.content_h = try draw_mod.draw(self.win, &self.frame, &self.cfg, &self.regions, self.alloc, st, self.folder_req != null);
        st.dirty = false;
        st.applyPendingFocus(self.regions.items);
        st.revealFocus(self.regions.items, self.viewport());
    }
};

/// The window's state from the desktop: appearance, GNOME integration,
/// capture modes, and the headless test overrides.
fn initState(alloc: std.mem.Allocator, env: env_mod.Env, bus: ?*desktop.Session) model.State {
    const last = platform_capture.lastPath(env.home);
    var st: model.State = .{ .direct = last == .direct, .last_path = last };
    if (bus) |b| {
        st.prefs = theme_mod.readPrefs(b, 1500);
        theme_mod.watch(b) catch {};
    }
    st.theme = theme_mod.of(st.prefs);
    st.env = env;
    st.gnome = model.gnomeState(alloc, env, bus);
    if (st.gnome == .active) st.capture = shell.captureInfo(alloc, bus.?);
    st.modes = settings_modes.load(alloc, env, bus);
    // SHOTLET_SETTINGS_FOCUS=n starts with the n-th control focused, and
    // SHOTLET_SETTINGS_VIEW=general|editor|shortcuts on that view, so
    // headless runs (which cannot type) can check them
    if (std.c.getenv("SHOTLET_SETTINGS_FOCUS")) |v| {
        st.pending_focus = std.fmt.parseInt(usize, std.mem.span(v), 10) catch null;
    }
    if (std.c.getenv("SHOTLET_SETTINGS_VIEW")) |v| {
        st.view = std.meta.stringToEnum(model.View, std.mem.span(v)) orelse .general;
    }
    return st;
}

pub fn run(alloc: std.mem.Allocator, env: env_mod.Env, smoke_ms: i64) !void {
    var smoke_deadline: i64 = 0;
    if (smoke_ms > 0) smoke_deadline = sys.monoMs() + smoke_ms;
    const cfg = config.load(alloc, env.home);
    text.init(alloc);
    defer text.deinit();
    defer icons.deinit();

    // the session bus: appearance (and its changes) and the folder chooser
    var bus: ?desktop.Session = desktop.connect(alloc, env) catch null;
    defer if (bus) |*b| b.deinit();
    const st = initState(alloc, env, if (bus) |*b| b else null);

    var win = try Window.init(alloc, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    win.current_cursor = .arrow;
    const size = frame_mod.outer(720, 780);
    try win.open("Shotlet settings", .{ .fullscreen = false, .transparent = true, .width = size[0], .height = size[1] });

    var app: App = .{ .alloc = alloc, .env = env, .cfg = cfg, .st = st, .win = &win, .bus = &bus };
    defer app.regions.deinit(alloc);
    defer app.frame.deinit(alloc);
    defer if (app.folder_req) |*r| r.deinit(alloc);

    while (true) {
        if (smoke_deadline != 0 and sys.monoMs() > smoke_deadline) break;
        if (app.busPtr()) |b| app.pollBus(b);
        if (try win.nextEventTimeout(if (app.folder_req != null) 50 else 100)) |ev| switch (try app.onEvent(ev)) {
            .keep => {},
            .close => break,
            .quit => return,
        };
        try app.redraw();
    }
    config.save(alloc, env.home, &app.cfg) catch {};
}
