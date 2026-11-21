//! Settings window: a header bar with a view switcher (General, Editor,
//! Shortcuts) over boxed-list cards, in the system's light or dark look
//! (theme.zig). Persisted to ~/.config/shotlet/config. Keyboard: Tab /
//! Shift+Tab and arrows move focus, Space / Enter activate, Esc closes.

const std = @import("std");
const window = @import("window.zig");
const render = @import("../gfx/render.zig");
const config = @import("../app/config.zig");
const text = @import("../gfx/text.zig");
const theme_mod = @import("theme.zig");
const icons = @import("icons.zig");
const shapes = @import("shapes.zig");
const dbus = @import("../platform/dbus.zig");
const portal = @import("../platform/portal.zig");
const sys = @import("../platform/sys.zig");
const env_mod = @import("../app/env.zig");
const gnome = @import("../app/gnome.zig");
const history = @import("../app/history.zig");
const keep = @import("../app/keep.zig");

const Canvas = render.Canvas;
const Window = window.Window;
const Theme = theme_mod.Theme;

const View = enum { general, editor, shortcuts };

const Hit = union(enum) {
    view: View,
    toggle_notify,
    toggle_copy_on_save,
    /// forget the ScreenCast restore token so the next capture asks again
    forget_monitors,
    /// pick the folder Ctrl+S saves to (FileChooser portal)
    choose_folder,
    th_minus,
    th_plus,
    color: u3,
    bind: config.Action,
    reset_binds,
    win_close,
    toggle_quick,
    quick_minus,
    quick_plus,
    toggle_history,
    hist_minus,
    hist_plus,
    hist_mb_minus,
    hist_mb_plus,
    open_history,
    clear_history,
    gnome_enable,
};

/// The GNOME Shell integration as the Settings window shows it.
const GnomeState = enum { not_gnome, active, installed, missing, failed };

fn gnomeState(alloc: std.mem.Allocator, bus: ?*dbus.Connection) GnomeState {
    if (!gnome.isGnome()) return .not_gnome;
    const b = bus orelse return .missing;
    if (gnome.extensionActive(b)) return .active;
    const st = gnome.shellState(alloc, b) orelse return .missing;
    return if (st == 99) .missing else .installed;
}

/// Steps of the numeric settings: seconds, captures, MiB.
pub fn stepSeconds(v: u16, up: bool) u16 {
    const steps = [_]u16{ 3, 5, 8, 10, 15, 20, 30, 45, 60, 120, 300 };
    return stepIn(u16, &steps, v, up);
}
pub fn stepCount(v: u16, up: bool) u16 {
    const steps = [_]u16{ 5, 10, 20, 30, 50, 100, 200, 500, 1000 };
    return stepIn(u16, &steps, v, up);
}
pub fn stepMb(v: u32, up: bool) u32 {
    const steps = [_]u32{ 50, 100, 200, 500, 1000, 2000, 5000 };
    return stepIn(u32, &steps, v, up);
}

/// The next value of `steps` above (or below) v; off-list values snap in.
fn stepIn(comptime T: type, steps: []const T, v: T, up: bool) T {
    if (up) {
        for (steps) |x| if (x > v) return x;
        return steps[steps.len - 1];
    }
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        if (steps[i] < v) return steps[i];
    }
    return steps[0];
}

test "numeric settings step along their scales" {
    try std.testing.expectEqual(@as(u16, 10), stepSeconds(8, true));
    try std.testing.expectEqual(@as(u16, 5), stepSeconds(8, false));
    try std.testing.expectEqual(@as(u16, 3), stepSeconds(3, false));
    try std.testing.expectEqual(@as(u16, 300), stepSeconds(300, true));
    try std.testing.expectEqual(@as(u16, 50), stepCount(42, true));
    try std.testing.expectEqual(@as(u16, 30), stepCount(42, false));
    try std.testing.expectEqual(@as(u32, 1000), stepMb(500, true));
}

fn headerHeight(win: *const Window) i32 {
    return @intFromFloat(@round(52.0 * @as(f64, @floatFromInt(win.scale120)) / 120.0));
}

const Region = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hit: Hit,
    /// corner radius of the control, for its focus ring
    radius: f64 = 8,

    fn contains(self: Region, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

pub fn run(alloc: std.mem.Allocator, env: env_mod.Env, smoke_ms: i64) !void {
    const home = env.home;
    var smoke_deadline: i64 = 0;
    if (smoke_ms > 0) smoke_deadline = sys.monoMs() + smoke_ms;
    var cfg = config.load(alloc, home);
    text.init(alloc);
    defer text.deinit();
    defer icons.deinit();

    // the session bus: appearance (and its changes) and the folder chooser
    var bus: ?dbus.Connection = portal.connectApp(alloc, env.bus_addr) catch null;
    defer if (bus) |*b| b.deinit();
    var st: State = .{};
    if (bus) |*b| {
        st.prefs = theme_mod.readPrefs(b, 1500);
        theme_mod.watch(b) catch {};
    }
    st.theme = st.prefs.theme();
    st.env = env;
    st.gnome = gnomeState(alloc, if (bus) |*b| b else null);
    if (st.gnome == .active) st.capture = gnome.captureInfo(alloc, &bus.?);

    var win = try Window.init(alloc, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    win.current_cursor = .arrow;
    try win.open("Shotlet settings", .{ .fullscreen = false, .width = 720, .height = 780 });

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(alloc);
    var folder_req: ?portal.Request = null;
    defer if (folder_req) |*r| r.deinit(alloc);

    // SHOTLET_SETTINGS_FOCUS=n starts with the n-th control focused, and
    // SHOTLET_SETTINGS_VIEW=general|editor|shortcuts on that view, so
    // headless runs (which cannot type) can check them
    if (std.c.getenv("SHOTLET_SETTINGS_FOCUS")) |v| {
        st.pending_focus = std.fmt.parseInt(usize, std.mem.span(v), 10) catch null;
    }
    if (std.c.getenv("SHOTLET_SETTINGS_VIEW")) |v| {
        st.view = std.meta.stringToEnum(View, std.mem.span(v)) orelse .general;
    }

    while (true) {
        if (smoke_deadline != 0 and sys.monoMs() > smoke_deadline) break;
        if (bus) |*b| {
            // appearance changes and the folder chooser's answer
            var n: usize = 0;
            while (n < 16) : (n += 1) {
                var msg = (b.nextMessageDeadline(sys.monoMs()) catch break) orelse break;
                if (theme_mod.applySignal(&st.prefs, &msg)) {
                    st.theme = st.prefs.theme();
                    st.dirty = true;
                }
                const kept = if (folder_req) |*r| r.handle(alloc, &msg) catch false else false;
                if (!kept) msg.deinit(alloc);
            }
            if (folder_req) |*r| if (r.done()) {
                if (r.outcome.? == .granted) {
                    if (portal.chosenPath(alloc, r)) |p| {
                        defer alloc.free(p);
                        if (p.len <= cfg.save_dir.len) {
                            @memcpy(cfg.save_dir[0..p.len], p);
                            cfg.save_dir_len = p.len;
                            config.save(alloc, home, &cfg) catch |err|
                                std.log.warn("could not save config: {t}", .{err});
                        } else std.log.warn("folder path too long: {s}", .{p});
                    } else |err| std.log.warn("folder chooser: {t}", .{err});
                }
                r.deinit(alloc);
                folder_req = null;
                st.dirty = true;
            };
        }
        if (try win.nextEventTimeout(if (folder_req != null) 50 else 100)) |ev| switch (ev) {
            .resize => {
                // keep the focused control in view at the new size
                st.dirty = true;
                st.reveal_focus = true;
            },
            .frame_done => {},
            .close => break,
            .key => |k| key: {
                if (!k.pressed or k.code == 0) break :key;
                if (st.recording) |action| {
                    if (k.repeat) break :key;
                    if (k.code == window.KEY_ESC) {
                        st.recording = null;
                        st.dirty = true;
                        break :key;
                    }
                    // ignore bare modifiers; wait for the real key
                    if (isModifier(k.code)) break :key;
                    const new_bind = config.Bind{ .code = k.code, .ctrl = k.ctrl, .shift = k.shift };
                    // clear any other action using the same combo
                    for (&cfg.binds, 0..) |*b, i| {
                        if (i != @backingInt(action) and b.matches(k.code, k.ctrl, k.shift)) {
                            b.* = .{};
                        }
                    }
                    cfg.binds[@backingInt(action)] = new_bind;
                    st.recording = null;
                    config.save(alloc, home, &cfg) catch |err|
                        std.log.warn("could not save config: {t}", .{err});
                    st.dirty = true;
                    break :key;
                }
                switch (keyCommand(k)) {
                    .close => break,
                    .next => st.moveFocus(regions.items, &win, true),
                    .prev => st.moveFocus(regions.items, &win, false),
                    .activate => if (st.focus) |hit| {
                        if (k.repeat) break :key;
                        if (try activate(hit, &cfg, &st, &win, alloc, home, if (bus) |*b| b else null, &folder_req)) return;
                    },
                    .none => {},
                }
            },
            .pointer_axis => |a| {
                var step: i32 = @intFromFloat(a.value * 12.0 * @as(f64, @floatFromInt(win.scale120)) / 120.0);
                if (step == 0 and a.value != 0) step = if (a.value > 0) 1 else -1;
                st.scrollBy(step, &win);
            },
            .pointer_motion => |m| {
                st.mouse_x = @intFromFloat(m.x);
                st.mouse_y = @intFromFloat(m.y);
                // redraw only when the hovered control changes
                var hover: i32 = -1;
                for (regions.items, 0..) |r, ri| {
                    if (r.contains(st.mouse_x, st.mouse_y)) {
                        hover = @intCast(ri);
                        break;
                    }
                }
                if (hover != st.hover_idx) {
                    st.hover_idx = hover;
                    st.dirty = true;
                }
            },
            .pointer_button => |b| btn: {
                if (b.button != window.BTN_LEFT or !b.pressed) break :btn;
                const px: i32 = @intFromFloat(b.x);
                const py: i32 = @intFromFloat(b.y);
                var hit_something = false;
                const hh_click = headerHeight(&win);
                for (regions.items) |r| {
                    if (!r.contains(px, py)) continue;
                    // content scrolled under the fixed header must not
                    // swallow clicks meant for the header's controls
                    if (py < hh_click and !isHeader(r.hit)) continue;
                    hit_something = true;
                    // clicking moves keyboard focus there too
                    if (isFocusable(r.hit)) st.focus = r.hit;
                    if (try activate(r.hit, &cfg, &st, &win, alloc, home, if (bus) |*bb| bb else null, &folder_req)) return;
                    break;
                }
                if (!hit_something) {
                    if (st.recording != null) {
                        st.recording = null;
                        st.dirty = true;
                    } else if (py < headerHeight(&win)) {
                        // drag the window by its header bar
                        try win.startMove();
                    }
                }
            },
        };

        if (st.dirty and !win.frame_pending and win.width > 0) {
            st.content_h = try draw(&win, &cfg, &regions, alloc, &st, folder_req != null);
            st.dirty = false;
            if (st.pending_focus) |n| {
                st.pending_focus = null;
                var i: usize = 0;
                for (regions.items) |r| if (isFocusable(r.hit)) {
                    if (i == n) {
                        st.focus = r.hit;
                        st.reveal_focus = true;
                        break;
                    }
                    i += 1;
                };
            }
            if (st.reveal_focus) {
                // positions are only known after a draw at the current size
                st.reveal_focus = false;
                const before = st.scroll_y;
                st.scrollBy(0, &win); // clamp to the new size
                st.ensureVisible(regions.items, &win);
                st.dirty = st.scroll_y != before or st.focus != null;
            }
        }
    }
    config.save(alloc, home, &cfg) catch {};
}

/// Mutable UI state of the settings window.
const State = struct {
    view: View = .general,
    prefs: theme_mod.Prefs = .{},
    theme: Theme = Theme.get(true, null),
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    dirty: bool = true,
    scroll_y: i32 = 0,
    content_h: i32 = 0,
    recording: ?config.Action = null,
    hover_idx: i32 = -1,
    /// keyboard focus (Tab / Shift+Tab); null until the first Tab
    focus: ?Hit = null,
    pending_focus: ?usize = null,
    /// scroll the focused control into view after the next draw
    reveal_focus: bool = false,
    env: env_mod.Env = undefined,
    gnome: GnomeState = .not_gnome,
    capture: gnome.CaptureInfo = .{},
    history_cleared: bool = false,

    fn scrollBy(self: *State, step: i32, win: *const Window) void {
        const max_scroll = @max(0, self.content_h - @as(i32, @intCast(win.height)));
        const new = std.math.clamp(self.scroll_y + step, 0, max_scroll);
        if (new != self.scroll_y) self.dirty = true;
        self.scroll_y = new;
    }

    fn moveFocus(self: *State, regions: []const Region, win: *const Window, forward: bool) void {
        self.focus = nextFocus(regions, self.focus, forward);
        self.ensureVisible(regions, win);
        self.dirty = true;
    }

    /// Scroll so the focused control is not hidden under the header or
    /// below the bottom edge.
    fn ensureVisible(self: *State, regions: []const Region, win: *const Window) void {
        const hit = self.focus orelse return;
        const r = findRegion(regions, hit) orelse return;
        if (isHeader(hit)) return;
        const f = @as(f64, @floatFromInt(win.scale120)) / 120.0;
        const pad: i32 = @intFromFloat(@round(12.0 * f));
        const top = headerHeight(win) + pad;
        const bottom = @as(i32, @intCast(win.height)) - pad;
        if (r.y < top) {
            self.scrollBy(r.y - top, win);
        } else if (r.y + r.h > bottom) {
            self.scrollBy(r.y + r.h - bottom, win);
        }
    }
};

const KeyCommand = enum { none, close, next, prev, activate };

/// Keyboard map of the settings window: Tab/Shift+Tab and arrows move
/// focus, Space/Enter activate, Esc (or Q) closes.
fn keyCommand(k: window.Key) KeyCommand {
    return switch (k.code) {
        window.KEY_ESC => .close,
        window.KEY_TAB => if (k.shift) .prev else .next,
        window.KEY_DOWN, window.KEY_RIGHT => .next,
        window.KEY_UP, window.KEY_LEFT => .prev,
        window.KEY_SPACE, window.KEY_ENTER, window.KEY_KPENTER => .activate,
        else => if (!k.ctrl and (k.keysym == 'q' or k.keysym == 'Q')) .close else .none,
    };
}

fn isModifier(code: u32) bool {
    return switch (code) {
        29, 97, 42, 54, 56, 100, 125, 126 => true, // ctrl/shift/alt/super
        else => false,
    };
}

/// Controls in the fixed header bar (not scrolled with the content).
fn isHeader(hit: Hit) bool {
    return hit == .win_close or hit == .view;
}

/// The close button is mouse-only (Esc closes); everything else takes focus.
fn isFocusable(hit: Hit) bool {
    return hit != .win_close;
}

fn findRegion(regions: []const Region, hit: Hit) ?Region {
    for (regions) |r| if (std.meta.eql(r.hit, hit)) return r;
    return null;
}

/// Next (or previous) focusable control after `current`, wrapping around.
fn nextFocus(regions: []const Region, current: ?Hit, forward: bool) ?Hit {
    // the header's view switcher first, then the content in reading order
    var list: [64]Hit = undefined;
    var n: usize = 0;
    for ([_]bool{ true, false }) |header| {
        for (regions) |r| {
            if (!isFocusable(r.hit) or isHeader(r.hit) != header or n == list.len) continue;
            list[n] = r.hit;
            n += 1;
        }
    }
    if (n == 0) return null;
    const cur = current orelse return if (forward) list[0] else list[n - 1];
    for (list[0..n], 0..) |h, i| {
        if (std.meta.eql(h, cur)) {
            return if (forward) list[(i + 1) % n] else list[(i + n - 1) % n];
        }
    }
    return if (forward) list[0] else list[n - 1];
}

/// Perform a control's action (mouse click or Space/Enter). Returns true
/// when the window should close.
fn activate(hit: Hit, cfg: *config.Config, st: *State, win: *Window, alloc: std.mem.Allocator, home: []const u8, bus: ?*dbus.Connection, folder_req: *?portal.Request) !bool {
    _ = win;
    switch (hit) {
        .view => |v| {
            if (st.view != v) {
                st.view = v;
                st.scroll_y = 0;
                st.recording = null;
            }
            st.dirty = true;
            return false;
        },
        .toggle_notify => cfg.notify = !cfg.notify,
        .toggle_copy_on_save => cfg.copy_on_save = !cfg.copy_on_save,
        .forget_monitors => {
            // only this key changes; the next capture shows the picker
            cfg.setScToken("");
            config.saveScreencastToken(alloc, home, "") catch |err|
                std.log.warn("could not save config: {t}", .{err});
            st.dirty = true;
            return false;
        },
        .choose_folder => {
            st.dirty = true;
            if (folder_req.* != null) return false;
            const conn = bus orelse {
                std.log.warn("no session bus: cannot show the folder chooser", .{});
                return false;
            };
            folder_req.* = portal.beginChooseFolder(alloc, conn, .{ .current_folder = cfg.saveDir() }) catch |err| blk: {
                std.log.warn("folder chooser: {t}", .{err});
                break :blk null;
            };
            return false;
        },
        .th_minus => cfg.default_thickness = @max(1, cfg.default_thickness - 1),
        .th_plus => cfg.default_thickness = @min(32, cfg.default_thickness + 1),
        .color => |c| cfg.default_color = c,
        .bind => |action| {
            st.recording = if (st.recording == action) null else action;
            st.dirty = true;
            return false;
        },
        .reset_binds => cfg.binds = config.default_binds,
        .toggle_quick => cfg.quick_access = !cfg.quick_access,
        .quick_minus, .quick_plus => cfg.quick_access_seconds = stepSeconds(cfg.quick_access_seconds, hit == .quick_plus),
        .toggle_history => cfg.history = !cfg.history,
        .hist_minus, .hist_plus => cfg.history_max = stepCount(cfg.history_max, hit == .hist_plus),
        .hist_mb_minus, .hist_mb_plus => cfg.history_max_mb = stepMb(cfg.history_max_mb, hit == .hist_mb_plus),
        .open_history => {
            keep.spawnSelf(st.env, &.{"history"});
            return false;
        },
        .clear_history => {
            var buf: [1024]u8 = undefined;
            if (history.historyRoot(&buf, home)) |root| history.clear(root) else |_| {}
            std.log.info("history cleared from Settings", .{});
            st.history_cleared = true;
            st.dirty = true;
            return false;
        },
        .gnome_enable => {
            st.gnome = switch (gnome.install(alloc, st.env, bus, .yes)) {
                .active => .active,
                .installed_relogin => .installed,
                .failed => .failed,
            };
            if (st.gnome == .active) if (bus) |b| {
                st.capture = gnome.captureInfo(alloc, b);
            };
            st.dirty = true;
            return false;
        },
        .win_close => {
            config.save(alloc, home, cfg) catch |err|
                std.log.warn("could not save config: {t}", .{err});
            return true;
        },
    }
    config.save(alloc, home, cfg) catch |err|
        std.log.warn("could not save config: {t}", .{err});
    st.dirty = true;
    return false;
}

const Ui = struct {
    win: *Window,
    c: Canvas,
    f: f64, // display scale
    th: Theme,
    regions: *std.ArrayList(Region),
    alloc: std.mem.Allocator,
    mx: i32,
    my: i32,

    fn sc(self: *const Ui, v: f64) i32 {
        return @intFromFloat(@round(v * self.f));
    }
    fn fs(self: *const Ui, v: f64) f64 {
        return v * self.f; // font size in px
    }
    fn hovered(self: *const Ui, x: i32, y: i32, w: i32, h: i32) bool {
        return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h;
    }
    fn add(self: *Ui, r: Region) !void {
        try self.regions.append(self.alloc, r);
    }
    /// Text vertically centred in [y, y + h).
    fn label(self: *Ui, x: i32, y: i32, h: i32, size: f64, color: u32, style: text.Style, s: []const u8) void {
        const px = self.fs(size);
        text.drawStyled(&self.c, x, y + @divTrunc(h - text.heightStyled(px, style), 2), px, color, style, s);
    }
    fn width(self: *const Ui, size: f64, style: text.Style, s: []const u8) i32 {
        return text.widthStyled(self.fs(size), style, s);
    }
};

/// Layout of a boxed list: rows stacked inside one card.
const Card = struct {
    x: i32,
    y: i32,
    w: i32,
    n: usize = 0,
    h: i32 = 0,
};

fn draw(win: *Window, cfg: *const config.Config, regions: *std.ArrayList(Region), alloc: std.mem.Allocator, st: *const State, choosing: bool) !i32 {
    const px = try win.backBuffer();
    var ui = Ui{
        .win = win,
        .c = Canvas.init(px, win.width, win.height),
        .f = @as(f64, @floatFromInt(win.scale120)) / 120.0,
        .th = st.theme,
        .regions = regions,
        .alloc = alloc,
        .mx = st.mouse_x,
        .my = st.mouse_y,
    };
    const th = st.theme;
    const c = &ui.c;
    @memset(px, th.window_bg | 0xFF000000);
    regions.clearRetainingCapacity();

    const w: i32 = @intCast(win.width);
    const vh: i32 = @intCast(win.height);
    const hh = headerHeight(win);
    // a centred column, at most 640 wide
    const col_w = @min(w - 2 * ui.sc(24), ui.sc(640));
    const cx = @divTrunc(w - col_w, 2);
    var y: i32 = hh + ui.sc(28) - st.scroll_y;

    switch (st.view) {
        .general => {
            const rh = ui.sc(theme_mod.row_h);
            y = try groupTitle(&ui, cx, y, col_w, "After capture", null);
            var card = beginCard(&ui, cx, y, col_w, 3 * rh);
            try switchRow(&ui, &card, "Notification after saving", "Shows where the file went", cfg.notify, .toggle_notify);
            try switchRow(&ui, &card, "Also copy when saving", "Ctrl+S puts the image on the clipboard too", cfg.copy_on_save, .toggle_copy_on_save);
            {
                const r = rowBegin(&ui, &card, ui.sc(theme_mod.row_h));
                rowTitle(&ui, r, "Save to", if (choosing) "Choosing a folder\u{2026}" else null);
                var buf: [300]u8 = undefined;
                const shown = folderLabel(cfg.saveDir(), &buf);
                try chipButton(&ui, r, .choose_folder, .folder, shown, false);
            }
            y = endCard(&card) + ui.sc(26);

            y = try groupTitle(&ui, cx, y, col_w, "Capture", null);
            card = beginCard(&ui, cx, y, col_w, 2 * rh);
            {
                const r = rowBegin(&ui, &card, rh);
                rowTitle(&ui, r, "Capture", if (st.capture.capture)
                    "Through the GNOME integration (no prompts)"
                else
                    "Through the screen-sharing portal");
            }
            {
                const r = rowBegin(&ui, &card, ui.sc(theme_mod.row_h));
                const remembered = cfg.scToken() != null;
                rowTitle(&ui, r, "Monitors", if (remembered) "Your choice is remembered" else "Asks on the next capture");
                if (remembered) try chipButton(&ui, r, .forget_monitors, null, "Choose again", true);
            }
            y = endCard(&card) + ui.sc(26);

            y = try groupTitle(&ui, cx, y, col_w, "Quick access", null);
            card = beginCard(&ui, cx, y, col_w, 2 * rh);
            try switchRow(&ui, &card, "Thumbnail after Copy and Save", "Copy again, save, drag into apps, annotate or pin it", cfg.quick_access, .toggle_quick);
            {
                const r = rowBegin(&ui, &card, rh);
                rowTitle(&ui, r, "Stays for", "Longer while the pointer is on it");
                var buf: [16]u8 = undefined;
                try valueStepper(&ui, r, std.fmt.bufPrint(&buf, "{d} s", .{cfg.quick_access_seconds}) catch "?", .quick_minus, .quick_plus);
            }
            y = endCard(&card) + ui.sc(26);

            y = try groupTitle(&ui, cx, y, col_w, "Recent captures", null);
            card = beginCard(&ui, cx, y, col_w, 4 * rh);
            try switchRow(&ui, &card, "Keep copied and saved captures", "Private to you, in ~/.local/state/shotlet", cfg.history, .toggle_history);
            {
                const r = rowBegin(&ui, &card, rh);
                rowTitle(&ui, r, "Keep at most", null);
                var buf: [24]u8 = undefined;
                try valueStepper(&ui, r, std.fmt.bufPrint(&buf, "{d} captures", .{cfg.history_max}) catch "?", .hist_minus, .hist_plus);
            }
            {
                const r = rowBegin(&ui, &card, rh);
                rowTitle(&ui, r, "Using at most", null);
                var buf: [24]u8 = undefined;
                try valueStepper(&ui, r, std.fmt.bufPrint(&buf, "{d} MB", .{cfg.history_max_mb}) catch "?", .hist_mb_minus, .hist_mb_plus);
            }
            {
                const r = rowBegin(&ui, &card, rh);
                rowTitle(&ui, r, "Captures kept so far", if (st.history_cleared) "Cleared" else null);
                try chipButton(&ui, r, .clear_history, null, "Clear history", false);
                try chipButtonAt(&ui, r, .open_history, "Open\u{2026}", ui.sc(150));
            }
            y = endCard(&card) + ui.sc(26);

            if (st.gnome != .not_gnome) {
                y = try groupTitle(&ui, cx, y, col_w, "GNOME integration", null);
                card = beginCard(&ui, cx, y, col_w, ui.sc(64));
                {
                    const r = rowBegin(&ui, &card, ui.sc(64));
                    rowTitle(&ui, r, "Shell extension", switch (st.gnome) {
                        .active => "On: thumbnails and pins stay above other windows",
                        .installed => "Installed; log out and in once to finish",
                        .failed => "Could not install it; see shotlet gnome-integration",
                        else => "Off: the thumbnail is an ordinary window",
                    });
                    if (st.gnome == .missing or st.gnome == .failed) try chipButton(&ui, r, .gnome_enable, null, "Enable", true);
                }
                y = endCard(&card) + ui.sc(26);
            }

            y = try groupTitle(&ui, cx, y, col_w, "Global shortcut", null);
            card = beginCard(&ui, cx, y, col_w, ui.sc(64));
            {
                const r = rowBegin(&ui, &card, ui.sc(64));
                var buf: [128]u8 = undefined;
                if (st.capture.capture) {
                    if (st.capture.shortcut()) |k| {
                        const t = std.fmt.bufPrint(&buf, "{s}", .{k}) catch "";
                        rowTitle(&ui, r, t, if (st.capture.blocked)
                            "GNOME\u{2019}s screenshot key: pick another with shotlet gnome-integration shortcut"
                        else
                            "Set by the GNOME integration: shotlet gnome-integration shortcut");
                    } else rowTitle(&ui, r, "No shortcut", "Pick one with shotlet gnome-integration shortcut KEY");
                } else rowTitle(&ui, r, "Bind a key to \u{201C}shotlet\u{201D}", "GNOME Settings \u{203A} Keyboard \u{203A} Custom Shortcuts");
            }
            y = endCard(&card) + ui.sc(26);
        },
        .editor => {
            y = try groupTitle(&ui, cx, y, col_w, "New annotations", null);
            var card = beginCard(&ui, cx, y, col_w, 2 * ui.sc(theme_mod.row_h));
            {
                const r = rowBegin(&ui, &card, ui.sc(theme_mod.row_h));
                rowTitle(&ui, r, "Default colour", null);
                try swatchRow(&ui, r, cfg.default_color);
            }
            {
                const r = rowBegin(&ui, &card, ui.sc(theme_mod.row_h));
                rowTitle(&ui, r, "Default size", "Stroke width and text size; the wheel changes it while drawing");
                try sizeStepper(&ui, r, cfg.default_thickness, shapes.palette[cfg.default_color]);
            }
            y = endCard(&card) + ui.sc(26);
        },
        .shortcuts => {
            y = try groupTitle(&ui, cx, y, col_w, "Editor shortcuts", "Reset to defaults");
            var card = beginCard(&ui, cx, y, col_w, @as(i32, config.n_actions) * ui.sc(48));
            inline for (0..config.n_actions) |i| {
                const action: config.Action = @fromBackingInt(@intCast(i));
                try shortcutRow(&ui, &card, action.label(), win, cfg.binds[i], st.recording == action, .{ .bind = action });
            }
            y = endCard(&card) + ui.sc(26);

            y = try groupTitle(&ui, cx, y, col_w, "Fixed keys", null);
            const fixed = [_]struct { []const u8, []const []const u8 }{
                .{ "Copy and close", &.{"Enter"} },
                .{ "Cancel, then close", &.{"Esc"} },
                .{ "Preset colours", &.{ "1", "\u{2013}", "8" } },
                .{ "Size", &.{ "-", "=" } },
                .{ "All shortcuts", &.{"?"} },
            };
            card = beginCard(&ui, cx, y, col_w, @as(i32, fixed.len) * ui.sc(48));
            for (fixed) |row| {
                const r = rowBegin(&ui, &card, ui.sc(48));
                rowTitle(&ui, r, row[0], null);
                _ = keyCaps(&ui, r, row[1], null);
            }
            y = endCard(&card) + ui.sc(14);
            ui.label(cx + ui.sc(4), y, ui.sc(20), 13, th.text_muted, .regular, "Click a shortcut (or focus it and press Enter), then press the new keys; Esc cancels.");
            y += ui.sc(20) + ui.sc(26);
        },
    }

    const content_h = y + st.scroll_y;

    // keyboard focus ring on scrolled content (the header draws its own)
    if (st.focus) |hit| if (!isHeader(hit)) if (findRegion(regions.items, hit)) |r| focusRing(&ui, r);

    try drawHeader(&ui, st);
    if (st.focus) |hit| if (isHeader(hit)) if (findRegion(regions.items, hit)) |r| focusRing(&ui, r);

    // scrollbar when content overflows
    if (content_h > vh) {
        const track_w = ui.sc(6);
        const tx = w - track_w - ui.sc(4);
        const frac = @as(f64, @floatFromInt(vh)) / @as(f64, @floatFromInt(content_h));
        const knob_h = @max(ui.sc(36), @as(i32, @intFromFloat(@as(f64, @floatFromInt(vh)) * frac)));
        const max_scroll = content_h - vh;
        const pos_frac = @as(f64, @floatFromInt(st.scroll_y)) / @as(f64, @floatFromInt(max_scroll));
        const avail = vh - hh - knob_h - ui.sc(8);
        const ky: i32 = hh + ui.sc(4) + @as(i32, @intFromFloat(@as(f64, @floatFromInt(@max(0, avail))) * pos_frac));
        c.fillRoundRectAA(tx, ky, track_w, knob_h, @as(f64, @floatFromInt(track_w)) / 2.0, th.switch_off);
    }

    // hairline window border
    c.rectOutline(0, 0, w, vh, 1, th.line | 0x0A000000);

    try win.present();
    return content_h;
}

fn drawHeader(ui: *Ui, st: *const State) !void {
    const th = ui.th;
    const c = &ui.c;
    const w: i32 = @intCast(ui.win.width);
    const hh = headerHeight(ui.win);
    c.fillRect(0, 0, w, hh, th.header_bg | 0xFF000000);
    c.fillRect(0, hh - 1, w, 1, th.line);

    // view switcher, centred
    const tabs = [_]struct { View, []const u8, icons.Icon }{
        .{ .general, "General", .gear },
        .{ .editor, "Editor", .pen },
        .{ .shortcuts, "Shortcuts", .keyboard },
    };
    const th_h = ui.sc(34);
    const gap = ui.sc(4);
    var widths: [tabs.len]i32 = undefined;
    var total: i32 = -gap;
    for (tabs, 0..) |t, i| {
        widths[i] = ui.sc(14) + ui.sc(16) + ui.sc(8) + ui.width(14, .bold, t[1]) + ui.sc(14);
        total += widths[i] + gap;
    }
    var x = @divTrunc(w - total, 2);
    const ty = @divTrunc(hh - th_h, 2);
    for (tabs, 0..) |t, i| {
        const tw = widths[i];
        const sel = st.view == t[0];
        const hov = ui.hovered(x, ty, tw, th_h);
        if (sel) {
            c.fillRoundRectAA(x, ty, tw, th_h, 8 * ui.f, th.view_sel);
        } else if (hov) c.fillRoundRectAA(x, ty, tw, th_h, 8 * ui.f, theme_mod.fade(th.view_sel, 0.6));
        const is = ui.sc(16);
        icons.drawStroke(c, t[2], x + ui.sc(14), ty + @divTrunc(th_h - is, 2), is, 2, th.text);
        ui.label(x + ui.sc(14) + is + ui.sc(8), ty, th_h, 14, th.text, .bold, t[1]);
        try ui.add(.{ .x = x, .y = ty, .w = tw, .h = th_h, .hit = .{ .view = t[0] }, .radius = 8 });
        x += tw + gap;
    }

    // close
    const bs = ui.sc(26);
    const bx = w - ui.sc(12) - bs;
    const by = @divTrunc(hh - bs, 2);
    const hov = ui.hovered(bx, by, bs, bs);
    const r = @as(f64, @floatFromInt(bs)) / 2.0;
    c.fillCircleAA(@as(f64, @floatFromInt(bx)) + r, @as(f64, @floatFromInt(by)) + r, r, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
    const is = ui.sc(14);
    icons.drawStroke(c, .close, bx + @divTrunc(bs - is, 2), by + @divTrunc(bs - is, 2), is, 2.5, th.text);
    try ui.add(.{ .x = bx, .y = by, .w = bs, .h = bs, .hit = .win_close, .radius = r });
}

fn focusRing(ui: *Ui, r: Region) void {
    const g = ui.sc(theme_mod.focus_gap);
    const fw = theme_mod.focus_w * ui.f;
    const e = g + @as(i32, @intFromFloat(@ceil(fw / 2)));
    shapes.roundRectRing(&ui.c, .{ .x = r.x - e, .y = r.y - e, .w = r.w + 2 * e, .h = r.h + 2 * e }, r.radius + @as(f64, @floatFromInt(g)) + fw / 2, fw, ui.th.accent);
}

/// "~/Pictures/Screenshots" style label for the save folder.
fn folderLabel(dir: ?[]const u8, buf: []u8) []const u8 {
    const d = dir orelse return "Pictures";
    if (std.c.getenv("HOME")) |hp| {
        const home = std.mem.span(hp);
        if (home.len > 1 and std.mem.startsWith(u8, d, home) and (d.len == home.len or d[home.len] == '/')) {
            const rest = std.mem.trimStart(u8, d[home.len..], "/");
            return std.fmt.bufPrint(buf, "{s}", .{if (rest.len == 0) "Home" else rest}) catch d;
        }
    }
    return d;
}

fn groupTitle(ui: *Ui, x: i32, y: i32, w: i32, title: []const u8, link: ?[]const u8) !i32 {
    const h = ui.sc(20);
    ui.label(x + ui.sc(2), y, h, 14, ui.th.text, .bold, title);
    if (link) |l| {
        const lw = ui.width(13, .regular, l);
        const lx = x + w - lw - ui.sc(2);
        const hov = ui.hovered(lx - ui.sc(4), y, lw + ui.sc(8), h);
        ui.label(lx, y, h, 13, if (hov) ui.th.accent_hover else ui.th.accent, .regular, l);
        try ui.add(.{ .x = lx - ui.sc(4), .y = y, .w = lw + ui.sc(8), .h = h, .hit = .reset_binds, .radius = 4 });
    }
    return y + h + ui.sc(10);
}

/// A boxed list `h` tall: the card is painted first, rows go on top.
fn beginCard(ui: *Ui, x: i32, y: i32, w: i32, h: i32) Card {
    const rad = theme_mod.card_radius * ui.f;
    ui.c.fillRoundRectAA(x - 1, y - 1, w + 2, h + 2, rad + 1, ui.th.line);
    ui.c.fillRoundRectAA(x, y, w, h, rad, ui.th.card | 0xFF000000);
    return .{ .x = x, .y = y, .w = w };
}

const Row = struct { x: i32, y: i32, w: i32, h: i32 };

/// The next row of `card`, `h` tall, under a separator.
fn rowBegin(ui: *Ui, card: *Card, h: i32) Row {
    if (card.n > 0) ui.c.fillRect(card.x, card.y + card.h, card.w, 1, ui.th.line);
    const r = Row{ .x = card.x, .y = card.y + card.h, .w = card.w, .h = h };
    card.n += 1;
    card.h += h;
    return r;
}

fn endCard(card: *const Card) i32 {
    return card.y + card.h;
}

fn rowTitle(ui: *Ui, r: Row, title: []const u8, subtitle: ?[]const u8) void {
    const x = r.x + ui.sc(16);
    if (subtitle) |s| {
        const t1 = text.height(ui.fs(15));
        const t2 = text.height(ui.fs(13));
        const top = r.y + @divTrunc(r.h - t1 - t2 - ui.sc(2), 2);
        text.draw(&ui.c, x, top, ui.fs(15), ui.th.text, title);
        text.draw(&ui.c, x, top + t1 + ui.sc(2), ui.fs(13), ui.th.text_muted, s);
    } else ui.label(x, r.y, r.h, 15, ui.th.text, .regular, title);
}

fn switchRow(ui: *Ui, card: *Card, title: []const u8, subtitle: ?[]const u8, on: bool, hit: Hit) !void {
    const r = rowBegin(ui, card, ui.sc(theme_mod.row_h));
    const th = ui.th;
    rowTitle(ui, r, title, subtitle);
    const sw = ui.sc(theme_mod.switch_w);
    const sh = ui.sc(theme_mod.switch_h);
    const sx = r.x + r.w - ui.sc(16) - sw;
    const sy = r.y + @divTrunc(r.h - sh, 2);
    const hov = ui.hovered(r.x, r.y, r.w, r.h);
    const off = if (hov) theme_mod.mix(th.switch_off, th.text, 0.08) else th.switch_off;
    ui.c.fillRoundRectAA(sx, sy, sw, sh, @as(f64, @floatFromInt(sh)) / 2.0, if (on) (if (hov) th.accent_hover else th.accent) else off);
    const kr = 10.0 * ui.f;
    const kx: f64 = if (on) @as(f64, @floatFromInt(sx + sw)) - 3.0 * ui.f - kr else @as(f64, @floatFromInt(sx)) + 3.0 * ui.f + kr;
    const ky = @as(f64, @floatFromInt(sy)) + @as(f64, @floatFromInt(sh)) / 2.0;
    ui.c.fillCircleAA(kx, ky + 1.0 * ui.f, kr + 0.5 * ui.f, 0x40000000);
    ui.c.fillCircleAA(kx, ky, kr, 0xFFFFFFFF);
    // the whole row toggles
    try ui.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .hit = hit, .radius = 0 });
}

/// A chip button on the right of row `r`.
fn chipButton(ui: *Ui, r: Row, hit: Hit, icon: ?icons.Icon, label_s: []const u8, bold: bool) !void {
    const th = ui.th;
    const style: text.Style = if (bold) .bold else .regular;
    const is = ui.sc(16);
    const max_label = @divTrunc(r.w, 2);
    var shown = label_s;
    // elide long paths from the left
    var buf: [300]u8 = undefined;
    while (ui.width(14, style, shown) > max_label and shown.len > 4) {
        var cut: usize = 1;
        while (cut < shown.len and (shown[cut] & 0xC0) == 0x80) cut += 1;
        const rest = shown[cut..];
        shown = std.fmt.bufPrint(&buf, "\u{2026}{s}", .{if (std.mem.startsWith(u8, rest, "\u{2026}")) rest[3..] else rest}) catch rest;
    }
    const bw = ui.sc(12) + (if (icon != null) is + ui.sc(8) else 0) + ui.width(14, style, shown) + ui.sc(if (icon != null) 12 else 14) + (if (icon == null) ui.sc(2) else 0);
    const bh = ui.sc(34);
    const bx = r.x + r.w - ui.sc(16) - bw;
    const by = r.y + @divTrunc(r.h - bh, 2);
    const hov = ui.hovered(bx, by, bw, bh);
    ui.c.fillRoundRectAA(bx, by, bw, bh, 8 * ui.f, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
    var x = bx + ui.sc(12);
    if (icon) |ic| {
        icons.drawStroke(&ui.c, ic, x, by + @divTrunc(bh - is, 2), is, 2, th.text);
        x += is + ui.sc(8);
    }
    ui.label(x, by, bh, 14, th.text, style, shown);
    try ui.add(.{ .x = bx, .y = by, .w = bw, .h = bh, .hit = hit, .radius = 8 });
}

fn swatchRow(ui: *Ui, r: Row, selected: u3) !void {
    const th = ui.th;
    const d = ui.sc(24);
    const gap = ui.sc(8);
    var x = r.x + r.w - ui.sc(16) - 8 * d - 7 * gap;
    const cy = @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2.0;
    for (0..8) |i| {
        const col = shapes.palette[i];
        const rad = @as(f64, @floatFromInt(d)) / 2.0;
        const cxf = @as(f64, @floatFromInt(x)) + rad;
        const hov = ui.hovered(x - @divTrunc(gap, 2), r.y, d + gap, r.h);
        if (i == selected) {
            ui.c.ringAA(cxf, cy, rad + 3.0 * ui.f, 2.0 * ui.f, th.accent);
        } else if (hov) ui.c.ringAA(cxf, cy, rad + 2.5 * ui.f, 1.5 * ui.f, th.switch_off);
        ui.c.fillCircleAA(cxf, cy, rad, col);
        ui.c.ringAA(cxf, cy, rad - 0.5 * ui.f, 1.0 * ui.f, 0x66808080);
        try ui.add(.{ .x = x, .y = @intFromFloat(cy - rad), .w = d, .h = d, .hit = .{ .color = @intCast(i) }, .radius = rad });
        x += d + gap;
    }
}

fn sizeStepper(ui: *Ui, r: Row, value: i32, color: u32) !void {
    const th = ui.th;
    const bs = ui.sc(34);
    const val_w = ui.sc(64);
    var x = r.x + r.w - ui.sc(16) - 2 * bs - val_w;
    const by = r.y + @divTrunc(r.h - bs, 2);
    for ([_]Hit{ .th_minus, .th_plus }, 0..) |hit, i| {
        const bx = if (i == 0) x else x + bs + val_w;
        const hov = ui.hovered(bx, by, bs, bs);
        ui.c.fillRoundRectAA(bx, by, bs, bs, 8 * ui.f, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
        const is = ui.sc(16);
        // minus: the plus icon's horizontal stroke only
        if (i == 0) {
            ui.c.fillRoundRectAA(bx + @divTrunc(bs - is, 2) + ui.sc(2), by + @divTrunc(bs, 2) - ui.sc(1), is - ui.sc(4), @max(2, ui.sc(2)), 1, th.text);
        } else icons.drawStroke(&ui.c, .plus, bx + @divTrunc(bs - is, 2), by + @divTrunc(bs - is, 2), is, 2, th.text);
        try ui.add(.{ .x = bx, .y = by, .w = bs, .h = bs, .hit = hit, .radius = 8 });
    }
    x += bs;
    // a dot as thick as the stroke, and the number
    const cy = @as(f64, @floatFromInt(by)) + @as(f64, @floatFromInt(bs)) / 2.0;
    const dot = @min(9.0 * ui.f, @max(1.5, @as(f64, @floatFromInt(value)) * ui.f / 2.0));
    ui.c.fillCircleAA(@as(f64, @floatFromInt(x + ui.sc(16))), cy, dot, color);
    if ((color & 0xFFFFFF) == 0xFFFFFF or (color & 0xFFFFFF) == 0x1C1C1E) ui.c.ringAA(@as(f64, @floatFromInt(x + ui.sc(16))), cy, dot, 1.0, 0x66808080);
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "?";
    ui.label(x + ui.sc(32), by, bs, 15, th.text, .regular, label);
}

/// A chip button whose right edge is `right_gap` in from the row's.
fn chipButtonAt(ui: *Ui, r: Row, hit: Hit, label_s: []const u8, right_gap: i32) !void {
    const th = ui.th;
    const bw = ui.width(14, .regular, label_s) + ui.sc(28);
    const bh = ui.sc(34);
    const bx = r.x + r.w - right_gap - bw;
    const by = r.y + @divTrunc(r.h - bh, 2);
    const hov = ui.hovered(bx, by, bw, bh);
    ui.c.fillRoundRectAA(bx, by, bw, bh, 8 * ui.f, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
    ui.label(bx + ui.sc(14), by, bh, 14, th.text, .regular, label_s);
    try ui.add(.{ .x = bx, .y = by, .w = bw, .h = bh, .hit = hit, .radius = 8 });
}

/// - value + on the right of row `r`.
fn valueStepper(ui: *Ui, r: Row, value: []const u8, minus: Hit, plus: Hit) !void {
    const th = ui.th;
    const bs = ui.sc(34);
    const val_w = @max(ui.sc(64), ui.width(15, .regular, value) + ui.sc(20));
    const x = r.x + r.w - ui.sc(16) - 2 * bs - val_w;
    const by = r.y + @divTrunc(r.h - bs, 2);
    for ([_]Hit{ minus, plus }, 0..) |hit, i| {
        const bx = if (i == 0) x else x + bs + val_w;
        const hov = ui.hovered(bx, by, bs, bs);
        ui.c.fillRoundRectAA(bx, by, bs, bs, 8 * ui.f, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
        const is = ui.sc(16);
        if (i == 0) {
            ui.c.fillRoundRectAA(bx + @divTrunc(bs - is, 2) + ui.sc(2), by + @divTrunc(bs, 2) - ui.sc(1), is - ui.sc(4), @max(2, ui.sc(2)), 1, th.text);
        } else icons.drawStroke(&ui.c, .plus, bx + @divTrunc(bs - is, 2), by + @divTrunc(bs - is, 2), is, 2, th.text);
        try ui.add(.{ .x = bx, .y = by, .w = bs, .h = bs, .hit = hit, .radius = 8 });
    }
    const tw = ui.width(15, .regular, value);
    ui.label(x + bs + @divTrunc(val_w - tw, 2), by, bs, 15, th.text, .regular, value);
}

/// Key caps right-aligned in row `r`; returns their left edge.
fn keyCaps(ui: *Ui, r: Row, caps: []const []const u8, accent: ?u32) i32 {
    const th = ui.th;
    const ch = ui.sc(26);
    const gap = ui.sc(4);
    var total: i32 = -gap;
    for (caps) |k| total += @max(ui.sc(22), ui.width(13, .bold, k) + ui.sc(16)) + gap;
    var x = r.x + r.w - ui.sc(16) - total;
    const left = x;
    const y = r.y + @divTrunc(r.h - ch, 2);
    for (caps) |k| {
        const cw = @max(ui.sc(22), ui.width(13, .bold, k) + ui.sc(16));
        if (accent) |a| {
            ui.c.fillRoundRectAA(x, y, cw, ch, 6 * ui.f, a);
        } else {
            ui.c.fillRoundRectAA(x, y, cw, ch, 6 * ui.f, th.line);
            ui.c.fillRoundRectAA(x, y, cw, ch - @max(1, ui.sc(1)), 6 * ui.f, th.chip);
        }
        const tw = ui.width(13, .bold, k);
        ui.label(x + @divTrunc(cw - tw, 2), y, ch, 13, if (accent != null) th.on_accent else th.text, .bold, k);
        x += cw + gap;
    }
    return left;
}

fn shortcutRow(ui: *Ui, card: *Card, title: []const u8, win: *Window, bind: config.Bind, recording: bool, hit: Hit) !void {
    const r = rowBegin(ui, card, ui.sc(48));
    const th = ui.th;
    if (ui.hovered(r.x, r.y, r.w, r.h) and !recording) {
        ui.c.fillRoundRectAA(r.x + ui.sc(4), r.y + ui.sc(4), r.w - ui.sc(8), r.h - ui.sc(8), 8 * ui.f, theme_mod.fade(th.view_sel, 0.7));
    }
    rowTitle(ui, r, title, null);
    if (recording) {
        _ = keyCaps(ui, r, &.{"Press keys\u{2026}"}, th.accent);
    } else if (bind.code == 0) {
        const s = "Not set";
        ui.label(r.x + r.w - ui.sc(16) - ui.width(13, .regular, s), r.y, r.h, 13, th.text_muted, .regular, s);
    } else {
        var kbuf: [32]u8 = undefined;
        const key = win.kb.keyName(bind.code, &kbuf, config.keyCodeName(bind.code));
        var caps: [3][]const u8 = undefined;
        var n: usize = 0;
        if (bind.ctrl) {
            caps[n] = "Ctrl";
            n += 1;
        }
        if (bind.shift) {
            caps[n] = "Shift";
            n += 1;
        }
        caps[n] = key;
        n += 1;
        _ = keyCaps(ui, r, caps[0..n], null);
    }
    try ui.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .hit = hit, .radius = 0 });
}

test "tab order wraps and skips the close button" {
    const regions = [_]Region{
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .toggle_notify },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .{ .color = 2 } },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .reset_binds },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .win_close },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .hit = .{ .view = .editor } },
    };
    const t = std.testing;
    // the view switcher comes first, wherever it was drawn
    try t.expect(std.meta.eql(nextFocus(&regions, null, true).?, Hit{ .view = .editor }));
    try t.expect(std.meta.eql(nextFocus(&regions, .{ .view = .editor }, true).?, Hit.toggle_notify));
    try t.expect(std.meta.eql(nextFocus(&regions, null, false).?, Hit.reset_binds));
    try t.expect(std.meta.eql(nextFocus(&regions, .toggle_notify, true).?, Hit{ .color = 2 }));
    try t.expect(std.meta.eql(nextFocus(&regions, .reset_binds, true).?, Hit{ .view = .editor }));
    try t.expect(std.meta.eql(nextFocus(&regions, .toggle_notify, false).?, Hit{ .view = .editor }));
    try t.expect(nextFocus(&.{}, null, true) == null);
}

test "settings key commands" {
    const t = std.testing;
    const K = struct {
        fn k(code: u32, shift: bool, keysym: u32) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = false, .shift = shift, .keysym = keysym };
        }
    };
    try t.expectEqual(KeyCommand.next, keyCommand(K.k(window.KEY_TAB, false, 0)));
    try t.expectEqual(KeyCommand.prev, keyCommand(K.k(window.KEY_TAB, true, 0)));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(window.KEY_SPACE, false, ' ')));
    try t.expectEqual(KeyCommand.activate, keyCommand(K.k(window.KEY_ENTER, false, 0)));
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(window.KEY_ESC, false, 0)));
    // Q closes by keysym, wherever the layout puts it (AZERTY: evdev 30)
    try t.expectEqual(KeyCommand.close, keyCommand(K.k(30, false, 'q')));
    try t.expectEqual(KeyCommand.none, keyCommand(K.k(16, false, 'a')));
}

test "the save folder shows relative to home" {
    var buf: [300]u8 = undefined;
    try std.testing.expectEqualStrings("Pictures", folderLabel(null, &buf));
    try std.testing.expectEqualStrings("/srv/shots", folderLabel("/srv/shots", &buf));
}
