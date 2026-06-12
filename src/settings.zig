//! Settings window: toggles, defaults and a keyboard reference, persisted
//! to ~/.config/cliptux/config. Rendered with the system TrueType font.

const std = @import("std");
const window = @import("window.zig");
const render = @import("render.zig");
const config = @import("config.zig");
const text = @import("text.zig");

const Canvas = render.Canvas;
const Window = window.Window;

const ui_bg: u32 = 0xFF17191C;
const ui_panel: u32 = 0xFF212529;
const ui_panel_hi: u32 = 0xFF2A2F34;
const ui_fg: u32 = 0xFFE9ECEF;
const ui_dim: u32 = 0xFF99A1A9;
const ui_accent: u32 = 0xFF4DABF7;

const palette = [8]u32{
    0xFFE03131, 0xFFFF922B, 0xFFFFD43B, 0xFF51CF66,
    0xFF339AF0, 0xFFCC5DE8, 0xFFFFFFFF, 0xFF1A1A1A,
};

const Hit = union(enum) {
    toggle_notify,
    toggle_copy_on_save,
    th_minus,
    th_plus,
    color: u3,
    bind: config.Action,
    close,
    win_close,
    win_max,
    win_min,
};

fn headerHeight(win: *const Window) i32 {
    return @intFromFloat(@round(42.0 * @as(f64, @floatFromInt(win.scale120)) / 120.0));
}

const Region = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    hit: Hit,

    fn contains(self: Region, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

pub fn run(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, home: []const u8, smoke_ms: i64) !void {
    var smoke_deadline: i64 = 0;
    if (smoke_ms > 0) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        smoke_deadline = @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000) + smoke_ms;
    }
    var cfg = config.load(alloc, home);
    text.init(alloc);
    defer text.deinit();

    var win = try Window.init(alloc, runtime_dir, display);
    defer win.deinit();
    win.current_cursor = .arrow;
    try win.open("cliptux settings", .{ .fullscreen = false, .width = 600, .height = 910 });

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(alloc);

    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;
    var dirty = true;
    var scroll_y: i32 = 0;
    var content_h: i32 = 0;
    var recording: ?config.Action = null;
    var hover_idx: i32 = -1;

    while (true) {
        if (smoke_deadline != 0) {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            if (@as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000) > smoke_deadline) break;
        }
        const ev = (try win.nextEventTimeout(100)) orelse continue;
        switch (ev) {
            .resize => dirty = true,
            .frame_done => {},
            .close => break,
            .key => |k| {
                if (!k.pressed) continue;
                if (recording) |action| {
                    if (k.code == window.KEY_ESC) {
                        recording = null;
                        dirty = true;
                        continue;
                    }
                    // ignore bare modifiers; wait for the real key
                    switch (k.code) {
                        29, 97, 42, 54, 56, 100, 125, 126 => continue, // ctrl/shift/alt/super
                        else => {},
                    }
                    const new_bind = config.Bind{ .code = k.code, .ctrl = k.ctrl, .shift = k.shift };
                    // clear any other action using the same combo
                    for (&cfg.binds, 0..) |*b, i| {
                        if (i != @intFromEnum(action) and b.matches(k.code, k.ctrl, k.shift)) {
                            b.* = .{};
                        }
                    }
                    cfg.binds[@intFromEnum(action)] = new_bind;
                    recording = null;
                    config.save(alloc, home, &cfg) catch |err|
                        std.log.warn("could not save config: {t}", .{err});
                    dirty = true;
                    continue;
                }
                if (k.code == window.KEY_ESC or k.code == 16) break; // Esc or Q
            },
            .pointer_axis => |a| {
                var step: i32 = @intFromFloat(a.value * 12.0 * @as(f64, @floatFromInt(win.scale120)) / 120.0);
                if (step == 0 and a.value != 0) step = if (a.value > 0) 1 else -1;
                const max_scroll = @max(0, content_h - @as(i32, @intCast(win.height)));
                scroll_y = std.math.clamp(scroll_y + step, 0, max_scroll);
                dirty = true;
            },
            .pointer_motion => |m| {
                mouse_x = @intFromFloat(m.x);
                mouse_y = @intFromFloat(m.y);
                // redraw only when the hovered control changes
                var hover: i32 = -1;
                for (regions.items, 0..) |r, ri| {
                    if (r.contains(mouse_x, mouse_y)) {
                        hover = @intCast(ri);
                        break;
                    }
                }
                if (hover != hover_idx) {
                    hover_idx = hover;
                    dirty = true;
                }
            },
            .pointer_button => |b| {
                if (b.button != window.BTN_LEFT or !b.pressed) continue;
                const px: i32 = @intFromFloat(b.x);
                const py: i32 = @intFromFloat(b.y);
                var hit_something = false;
                const hh_click = headerHeight(&win);
                for (regions.items) |r| {
                    if (!r.contains(px, py)) continue;
                    // content scrolled under the fixed header must not
                    // swallow clicks meant for the window controls
                    const is_win_ctl = r.hit == .win_close or r.hit == .win_max or r.hit == .win_min;
                    if (py < hh_click and !is_win_ctl) continue;
                    hit_something = true;
                    switch (r.hit) {
                        .toggle_notify => cfg.notify = !cfg.notify,
                        .toggle_copy_on_save => cfg.copy_on_save = !cfg.copy_on_save,
                        .th_minus => cfg.default_thickness = @max(1, cfg.default_thickness - 1),
                        .th_plus => cfg.default_thickness = @min(32, cfg.default_thickness + 1),
                        .color => |c| cfg.default_color = c,
                        .bind => |action| {
                            recording = if (recording == action) null else action;
                            dirty = true;
                            break;
                        },
                        .close, .win_close => {
                            config.save(alloc, home, &cfg) catch |err|
                                std.log.warn("could not save config: {t}", .{err});
                            return;
                        },
                        .win_max => try win.toggleMaximize(),
                        .win_min => try win.minimize(),
                    }
                    if (r.hit != .bind) {
                        config.save(alloc, home, &cfg) catch |err|
                            std.log.warn("could not save config: {t}", .{err});
                    }
                    dirty = true;
                    break;
                }
                if (!hit_something) {
                    if (recording != null) {
                        recording = null;
                        dirty = true;
                    } else if (py < headerHeight(&win)) {
                        // drag the window by its header bar
                        try win.startMove();
                    }
                }
            },
        }

        if (dirty and !win.frame_pending and win.width > 0) {
            content_h = try draw(&win, &cfg, &regions, alloc, mouse_x, mouse_y, scroll_y, recording);
            dirty = false;
        }
    }
    config.save(alloc, home, &cfg) catch {};
}

const Ui = struct {
    win: *Window,
    c: Canvas,
    f: f64, // display scale

    fn sc(self: *const Ui, v: f64) i32 {
        return @intFromFloat(@round(v * self.f));
    }
    fn fs(self: *const Ui, v: f64) f64 {
        return v * self.f; // font size in px
    }
};

fn draw(win: *Window, cfg: *const config.Config, regions: *std.ArrayList(Region), alloc: std.mem.Allocator, mx: i32, my: i32, scroll_y: i32, recording: ?config.Action) !i32 {
    const px = try win.backBuffer();
    var ui = Ui{
        .win = win,
        .c = Canvas.init(px, win.width, win.height),
        .f = @as(f64, @floatFromInt(win.scale120)) / 120.0,
    };
    const c = &ui.c;
    @memset(px, ui_bg);
    regions.clearRetainingCapacity();

    const w: i32 = @intCast(win.width);
    const margin = ui.sc(28);
    const body = ui.fs(15);
    const small = ui.fs(13);
    const hh = headerHeight(win);
    var y: i32 = hh + ui.sc(18) - scroll_y;

    // ---- card: General ----
    {
        const rows = 4;
        const card_h = ui.sc(16) * 2 + ui.sc(20) + rows * ui.sc(48);
        card(&ui, margin, y, w - margin * 2, card_h, "General");
        var ry = y + ui.sc(16) + ui.sc(26);

        ry = toggleRow(&ui, regions, alloc, margin, ry, w, "Notification after copy or save", cfg.notify, .toggle_notify, mx, my);
        ry = toggleRow(&ui, regions, alloc, margin, ry, w, "Also copy to clipboard when saving", cfg.copy_on_save, .toggle_copy_on_save, mx, my);

        // thickness row
        {
            const row_h = ui.sc(48);
            const cy = ry + @divTrunc(row_h, 2);
            text.draw(c, margin + ui.sc(16), cy - @divTrunc(text.height(body), 2), body, ui_fg, "Default thickness");
            const bsz = ui.sc(30);
            var bx = w - margin - ui.sc(16) - bsz * 2 - ui.sc(78);
            try squareButton(&ui, regions, alloc, bx, cy - @divTrunc(bsz, 2), bsz, .th_minus, mx, my, "-");
            var buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{d}", .{cfg.default_thickness}) catch "?";
            text.draw(c, bx + bsz + ui.sc(14), cy - @divTrunc(text.height(body), 2), body, ui_fg, label);
            c.fillCircleAA(@floatFromInt(bx + bsz + ui.sc(52)), @floatFromInt(cy), @min(9.0 * ui.f, @max(1.5, @as(f64, @floatFromInt(cfg.default_thickness)) * ui.f / 2.0)), palette[cfg.default_color]);
            bx = bx + bsz + ui.sc(78);
            try squareButton(&ui, regions, alloc, bx, cy - @divTrunc(bsz, 2), bsz, .th_plus, mx, my, "+");
            ry += row_h;
        }

        // color row
        {
            const row_h = ui.sc(48);
            const cy: f64 = @floatFromInt(ry + @divTrunc(row_h, 2));
            text.draw(c, margin + ui.sc(16), ry + @divTrunc(row_h - text.height(body), 2), body, ui_fg, "Default color");
            var cx = w - margin - ui.sc(16) - ui.sc(8 * 32 - 6);
            for (palette, 0..) |col, i| {
                const cxf: f64 = @floatFromInt(cx + ui.sc(12));
                const hovered = mx >= cx and mx < cx + ui.sc(30) and my >= ry and my < ry + row_h;
                const radius: f64 = if (hovered) 11.5 * ui.f else 9.5 * ui.f;
                c.fillCircleAA(cxf, cy, radius, col);
                if (i == cfg.default_color) {
                    c.ringAA(cxf, cy, radius + 3.5 * ui.f, 2.0 * ui.f, 0xFFFFFFFF);
                } else if (hovered) {
                    c.ringAA(cxf, cy, radius + 3.0 * ui.f, 1.5 * ui.f, 0x66FFFFFF);
                } else if (col == 0xFF1A1A1A) {
                    c.ringAA(cxf, cy, radius, 1.0 * ui.f, 0x59FFFFFF);
                }
                try regions.append(alloc, .{ .x = cx, .y = ry, .w = ui.sc(30), .h = row_h, .hit = .{ .color = @intCast(i) } });
                cx += ui.sc(32);
            }
            ry += row_h;
        }
        y += card_h + ui.sc(18);
    }

    // ---- card: Editor shortcuts (click a shortcut to rebind) ----
    {
        const n: i32 = config.n_actions;
        const row_h = ui.sc(34);
        const fixed_rows = 3; // non-editable hints at the bottom
        const card_h = ui.sc(16) + ui.sc(26) + n * row_h + ui.sc(10) + fixed_rows * (text.height(small) + ui.sc(6)) + ui.sc(14);
        card(&ui, margin, y, w - margin * 2, card_h, "Editor shortcuts  -  click one to change it");
        var ry = y + ui.sc(16) + ui.sc(26);

        inline for (@typeInfo(config.Action).@"enum".fields, 0..) |fld, i| {
            const action: config.Action = @enumFromInt(i);
            _ = fld;
            const hovered = mx >= margin and mx < w - margin and my >= ry and my < ry + row_h;
            const is_recording = recording == action;
            if (hovered and !is_recording)
                c.fillRoundRectAA(margin + ui.sc(6), ry, w - margin * 2 - ui.sc(12), row_h, 7.0 * ui.f, ui_panel_hi);
            text.draw(c, margin + ui.sc(16), ry + @divTrunc(row_h - text.height(small), 2), small, ui_fg, action.label());

            // shortcut pill (right aligned)
            var nbuf: [32]u8 = undefined;
            const bname = if (is_recording) "Press a key..." else config.bindName(cfg.binds[i], &nbuf);
            const bw = text.width(small, bname) + ui.sc(20);
            const bx = w - margin - ui.sc(16) - bw;
            const bh = row_h - ui.sc(8);
            const by = ry + ui.sc(4);
            const pill_bg: u32 = if (is_recording) ui_accent else if (cfg.binds[i].code == 0) 0xFF3A3134 else 0xFF31373D;
            const pill_fg: u32 = if (is_recording) 0xFF14181C else if (cfg.binds[i].code == 0) 0xFFCC8B8B else ui_fg;
            c.fillRoundRectAA(bx, by, bw, bh, @as(f64, @floatFromInt(bh)) / 2.0, pill_bg);
            text.draw(c, bx + ui.sc(10), by + @divTrunc(bh - text.height(small), 2), small, pill_fg, bname);

            try regions.append(alloc, .{ .x = margin, .y = ry, .w = w - margin * 2, .h = row_h, .hit = .{ .bind = action } });
            ry += row_h;
        }

        ry += ui.sc(10);
        const fixed = [_][]const u8{
            "Fixed:  Enter copies    Esc quits    Right click cancels",
            "1-8 picks a color    Wheel or - / = adjusts thickness",
            "Recording: press the new combo, Esc to cancel",
        };
        for (fixed) |line| {
            text.draw(c, margin + ui.sc(16), ry, small, ui_dim, line);
            ry += text.height(small) + ui.sc(6);
        }
        y += card_h + ui.sc(18);
    }

    // ---- card: Global shortcut + save location ----
    {
        const line_h = text.height(small) + ui.sc(7);
        const card_h = ui.sc(16) + ui.sc(26) + line_h * 4 + ui.sc(12);
        card(&ui, margin, y, w - margin * 2, card_h, "System");
        var ry = y + ui.sc(16) + ui.sc(26);
        text.draw(c, margin + ui.sc(16), ry, small, ui_fg, "Global shortcut: bind a key to \"cliptux\" in");
        ry += line_h;
        text.draw(c, margin + ui.sc(16), ry, small, ui_dim, "GNOME Settings > Keyboard > Custom Shortcuts");
        ry += line_h + ui.sc(6);
        const loc = cfg.saveDir() orelse "Save location: system Pictures folder";
        text.draw(c, margin + ui.sc(16), ry, small, ui_fg, loc);
        ry += line_h;
        text.draw(c, margin + ui.sc(16), ry, small, ui_dim, "Override with save_dir= in ~/.config/cliptux/config");
        y += card_h + ui.sc(18);
    }

    // close button (in flow, scrolls with content)
    {
        const bw = ui.sc(108);
        const bh = ui.sc(36);
        const bx = w - margin - bw;
        const by = y + ui.sc(4);
        const hovered = mx >= bx and mx < bx + bw and my >= by and my < by + bh;
        c.fillRoundRectAA(bx, by, bw, bh, 9.0 * ui.f, if (hovered) 0xFF5DB3F8 else ui_accent);
        const cl = "Close";
        text.draw(c, bx + @divTrunc(bw - text.width(body, cl), 2), by + @divTrunc(bh - text.height(body), 2), body, 0xFF14181C, cl);
        try regions.append(alloc, .{ .x = bx, .y = by, .w = bw, .h = bh, .hit = .close });
        y = by + bh + ui.sc(20);
    }

    const content_h = y + scroll_y;

    // ---- fixed header bar (drawn over scrolled content) ----
    {
        c.fillRect(0, 0, w, hh, 0xFF20242A);
        c.fillRect(0, hh - 1, w, 1, 0xFF2E3338);
        const title = "cliptux Settings";
        text.draw(c, ui.sc(16), @divTrunc(hh - text.height(body), 2), body, ui_fg, title);

        // window controls, right to left: close, maximize, minimize
        const br = 13.0 * ui.f; // button circle radius
        const bgap = ui.sc(38);
        const cy_f: f64 = @floatFromInt(@divTrunc(hh, 2));
        const icons = [_]Hit{ .win_close, .win_max, .win_min };
        var bcx: f64 = @floatFromInt(w - ui.sc(26));
        for (icons) |hit| {
            const bx: i32 = @intFromFloat(bcx - br);
            const by: i32 = @intFromFloat(cy_f - br);
            const bsz: i32 = @intFromFloat(br * 2.0);
            const hovered = mx >= bx and mx < bx + bsz and my >= by and my < by + bsz;
            if (hovered) {
                const hover_bg: u32 = if (hit == .win_close) 0xFFB3404A else 0xFF3A4046;
                c.fillCircleAA(bcx, cy_f, br, hover_bg);
            } else {
                c.fillCircleAA(bcx, cy_f, br, 0xFF2C3137);
            }
            const g = 4.5 * ui.f;
            const P = struct { x: i32, y: i32 };
            switch (hit) {
                .win_close => {
                    const a = [_]P{
                        .{ .x = @intFromFloat(bcx - g), .y = @intFromFloat(cy_f - g) },
                        .{ .x = @intFromFloat(bcx + g), .y = @intFromFloat(cy_f + g) },
                    };
                    const b2 = [_]P{
                        .{ .x = @intFromFloat(bcx - g), .y = @intFromFloat(cy_f + g) },
                        .{ .x = @intFromFloat(bcx + g), .y = @intFromFloat(cy_f - g) },
                    };
                    c.strokePolylineAA(a[0..], 1.8 * ui.f, ui_fg);
                    c.strokePolylineAA(b2[0..], 1.8 * ui.f, ui_fg);
                },
                .win_max => {
                    c.rectOutline(@intFromFloat(bcx - g), @intFromFloat(cy_f - g), @intFromFloat(g * 2), @intFromFloat(g * 2), @max(1, ui.sc(1.5)), ui_fg);
                },
                .win_min => {
                    c.fillRect(@intFromFloat(bcx - g), @intFromFloat(cy_f + g - 1.0 * ui.f), @intFromFloat(g * 2), @max(1, ui.sc(1.5)), ui_fg);
                },
                else => {},
            }
            try regions.append(alloc, .{ .x = bx, .y = by, .w = bsz, .h = bsz, .hit = hit });
            bcx -= @floatFromInt(bgap);
        }
    }

    // scrollbar when content overflows
    const vh: i32 = @intCast(win.height);
    if (content_h > vh) {
        const track_w = ui.sc(5);
        const tx = w - track_w - ui.sc(4);
        const frac = @as(f64, @floatFromInt(vh)) / @as(f64, @floatFromInt(content_h));
        const knob_h = @max(ui.sc(36), @as(i32, @intFromFloat(@as(f64, @floatFromInt(vh)) * frac)));
        const max_scroll = content_h - vh;
        const pos_frac = @as(f64, @floatFromInt(scroll_y)) / @as(f64, @floatFromInt(max_scroll));
        const hh2 = headerHeight(win);
        const avail = vh - hh2 - knob_h - ui.sc(8);
        const ky: i32 = hh2 + ui.sc(4) + @as(i32, @intFromFloat(@as(f64, @floatFromInt(@max(0, avail))) * pos_frac));
        c.fillRoundRectAA(tx, ky, track_w, knob_h, @as(f64, @floatFromInt(track_w)) / 2.0, 0x4DFFFFFF);
    }

    // hairline window border
    c.rectOutline(0, 0, w, vh, 1, 0xFF2E3338);

    try win.present();
    return content_h;
}

fn card(ui: *Ui, x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
    ui.c.fillRoundRectAA(x, y, w, h, 12.0 * ui.f, ui_panel);
    text.draw(&ui.c, x + ui.sc(16), y + ui.sc(12), ui.fs(12), ui_accent, title);
}

fn toggleRow(ui: *Ui, regions: *std.ArrayList(Region), alloc: std.mem.Allocator, margin: i32, y: i32, w: i32, label: []const u8, on: bool, hit: Hit, mx: i32, my: i32) i32 {
    const c = &ui.c;
    const row_h = ui.sc(48);
    const body = ui.fs(15);
    const hovered = my >= y and my < y + row_h and mx >= margin and mx < w - margin;
    if (hovered) c.fillRoundRectAA(margin + ui.sc(6), y, w - margin * 2 - ui.sc(12), row_h, 8.0 * ui.f, ui_panel_hi);
    text.draw(c, margin + ui.sc(16), y + @divTrunc(row_h - text.height(body), 2), body, ui_fg, label);

    const tw = ui.sc(44);
    const th = ui.sc(24);
    const tx = w - margin - ui.sc(16) - tw;
    const ty = y + @divTrunc(row_h - th, 2);
    c.fillRoundRectAA(tx, ty, tw, th, @as(f64, @floatFromInt(th)) / 2.0, if (on) ui_accent else 0xFF40464D);
    const knob_r = @as(f64, @floatFromInt(th)) / 2.0 - 2.5 * ui.f;
    const knob_x: f64 = if (on)
        @as(f64, @floatFromInt(tx + tw)) - knob_r - 3.0 * ui.f
    else
        @as(f64, @floatFromInt(tx)) + knob_r + 3.0 * ui.f;
    c.fillCircleAA(knob_x, @as(f64, @floatFromInt(ty)) + @as(f64, @floatFromInt(th)) / 2.0, knob_r, 0xFFFFFFFF);

    regions.append(alloc, .{ .x = margin, .y = y, .w = w - margin * 2, .h = row_h, .hit = hit }) catch {};
    return y + row_h;
}

fn squareButton(ui: *Ui, regions: *std.ArrayList(Region), alloc: std.mem.Allocator, x: i32, y: i32, size: i32, hit: Hit, mx: i32, my: i32, glyph: []const u8) !void {
    const c = &ui.c;
    const hovered = mx >= x and mx < x + size and my >= y and my < y + size;
    c.fillRoundRectAA(x, y, size, size, 8.0 * ui.f, if (hovered) 0xFF40464D else ui_panel_hi);
    const body = ui.fs(17);
    text.draw(c, x + @divTrunc(size - text.width(body, glyph), 2), y + @divTrunc(size - text.height(body), 2), body, ui_fg, glyph);
    try regions.append(alloc, .{ .x = x, .y = y, .w = size, .h = size, .hit = hit });
}
