//! One frame of the Settings window: the current view's cards in a
//! centred, scrolled column under the fixed header bar (view switcher and
//! close button), the focus ring and the scrollbar, in the window's
//! drawn frame (ui/frame.zig).

const std = @import("std");
const window = @import("../../platform/linux/window.zig");
const render = @import("../../gfx/render.zig");
const config = @import("../../app/config.zig");
const theme_mod = @import("../theme.zig");
const icons = @import("../icons.zig");
const shapes = @import("../shapes.zig");
const model = @import("model.zig");
const focus = @import("focus.zig");
const w = @import("widgets.zig");
const pages = @import("pages.zig");
const frame = @import("../frame.zig");

const Canvas = render.Canvas;
const Window = window.Window;
const Ui = w.Ui;
const Region = model.Region;
const State = model.State;

/// Draw and present a frame; returns the content's height (unscrolled).
pub fn draw(win: *Window, fr: *frame.Frame, cfg: *const config.Config, regions: *std.ArrayList(Region), alloc: std.mem.Allocator, st: *const State, choosing: bool) !i32 {
    var ui = Ui{
        .win = win,
        .c = try fr.begin(alloc, win),
        .f = @as(f64, @floatFromInt(win.scale120)) / 120.0,
        .th = st.theme,
        .regions = regions,
        .alloc = alloc,
        .mx = st.mouse_x,
        .my = st.mouse_y,
    };
    @memset(ui.c.px, st.theme.window_bg | 0xFF000000);
    regions.clearRetainingCapacity();

    const width: i32 = ui.c.w;
    // a centred column, at most 640 wide
    const col_w = @min(width - 2 * ui.sc(24), ui.sc(640));
    const y0: i32 = model.headerHeight(ui.f) + ui.sc(28) - st.scroll_y;
    const page: pages.Page = .{ .ui = &ui, .cx = @divTrunc(width - col_w, 2), .col_w = col_w, .cfg = cfg, .st = st, .choosing = choosing };
    const content_h = (try pages.drawView(page, y0)) + st.scroll_y;

    // keyboard focus ring on scrolled content (the header draws its own)
    drawFocus(&ui, st, false);
    try drawHeader(&ui, st);
    drawFocus(&ui, st, true);
    drawScrollbar(&ui, content_h, st.scroll_y);
    try fr.present(win, st.theme.hairline);
    return content_h;
}

/// The focus ring, if the focused control is in the header (or not).
fn drawFocus(ui: *Ui, st: *const State, header: bool) void {
    const hit = st.focus orelse return;
    if (focus.isHeader(hit) != header) return;
    if (focus.findRegion(ui.regions.items, hit)) |r| focusRing(ui, r);
}

/// The scrollbar's knob, when the content overflows the window.
fn drawScrollbar(ui: *Ui, content_h: i32, scroll_y: i32) void {
    const vh: i32 = ui.c.h;
    if (content_h <= vh) return;
    const hh = model.headerHeight(ui.f);
    const track_w = ui.sc(6);
    const tx = ui.c.w - track_w - ui.sc(4);
    const frac = @as(f64, @floatFromInt(vh)) / @as(f64, @floatFromInt(content_h));
    const knob_h = @max(ui.sc(36), @as(i32, @intFromFloat(@as(f64, @floatFromInt(vh)) * frac)));
    const max_scroll = content_h - vh;
    const pos_frac = @as(f64, @floatFromInt(scroll_y)) / @as(f64, @floatFromInt(max_scroll));
    const avail = vh - hh - knob_h - ui.sc(8);
    const ky: i32 = hh + ui.sc(4) + @as(i32, @intFromFloat(@as(f64, @floatFromInt(@max(0, avail))) * pos_frac));
    ui.c.fillRoundRectAA(tx, ky, track_w, knob_h, @as(f64, @floatFromInt(track_w)) / 2.0, ui.th.switch_off);
}

const Tab = struct { model.View, []const u8, icons.Icon };
const tabs = [_]Tab{
    .{ .general, "General", .gear },
    .{ .editor, "Editor", .pen },
    .{ .shortcuts, "Shortcuts", .keyboard },
    .{ .recording, "Recording", .background },
};

fn drawHeader(ui: *Ui, st: *const State) !void {
    const th = ui.th;
    const width: i32 = ui.c.w;
    const hh = model.headerHeight(ui.f);
    ui.c.fillRect(0, 0, width, hh, th.header_bg | 0xFF000000);
    ui.c.fillRect(0, hh - 1, width, 1, th.line);
    try drawViewSwitcher(ui, st, width, hh);
    try drawCloseButton(ui, width, hh);
}

/// The view switcher, centred in the header.
fn drawViewSwitcher(ui: *Ui, st: *const State, width: i32, hh: i32) !void {
    const th_h = ui.sc(34);
    const gap = ui.sc(4);
    var widths: [tabs.len]i32 = undefined;
    var total: i32 = -gap;
    for (tabs, 0..) |t, i| {
        widths[i] = ui.sc(14) + ui.sc(16) + ui.sc(8) + ui.width(14, .semibold, t[1]) + ui.sc(14);
        total += widths[i] + gap;
    }
    var x = @divTrunc(width - total, 2);
    const ty = @divTrunc(hh - th_h, 2);
    for (tabs, 0..) |t, i| {
        try drawTab(ui, t, st.view == t[0], x, ty, widths[i], th_h);
        x += widths[i] + gap;
    }
}

fn drawTab(ui: *Ui, t: Tab, sel: bool, x: i32, ty: i32, tw: i32, th_h: i32) !void {
    const th = ui.th;
    const hov = ui.hovered(x, ty, tw, th_h);
    if (sel) {
        ui.c.fillRoundRectAA(x, ty, tw, th_h, 8 * ui.f, th.view_sel);
    } else if (hov) ui.c.fillRoundRectAA(x, ty, tw, th_h, 8 * ui.f, theme_mod.fade(th.view_sel, 0.6));
    const is = ui.sc(16);
    icons.drawStroke(&ui.c, t[2], x + ui.sc(14), ty + @divTrunc(th_h - is, 2), is, 2, th.text);
    ui.label(x + ui.sc(14) + is + ui.sc(8), ty, th_h, 14, th.text, .semibold, t[1]);
    try ui.add(.{ .x = x, .y = ty, .w = tw, .h = th_h, .hit = .{ .view = t[0] }, .radius = 8 });
}

fn drawCloseButton(ui: *Ui, width: i32, hh: i32) !void {
    const th = ui.th;
    const bs = ui.sc(26);
    const bx = width - ui.sc(12) - bs;
    const by = @divTrunc(hh - bs, 2);
    const hov = ui.hovered(bx, by, bs, bs);
    const r = @as(f64, @floatFromInt(bs)) / 2.0;
    ui.c.fillCircleAA(@as(f64, @floatFromInt(bx)) + r, @as(f64, @floatFromInt(by)) + r, r, if (hov) theme_mod.mix(th.chip, th.switch_off, 0.8) else th.chip);
    const is = ui.sc(14);
    icons.drawStroke(&ui.c, .close, bx + @divTrunc(bs - is, 2), by + @divTrunc(bs - is, 2), is, 2.5, th.text);
    try ui.add(.{ .x = bx, .y = by, .w = bs, .h = bs, .hit = .win_close, .radius = r });
}

fn focusRing(ui: *Ui, r: Region) void {
    const g = ui.sc(theme_mod.focus_gap);
    const fw = theme_mod.focus_w * ui.f;
    const e = g + @as(i32, @intFromFloat(@ceil(fw / 2)));
    shapes.roundRectRing(&ui.c, .{ .x = r.x - e, .y = r.y - e, .w = r.w + 2 * e, .h = r.h + 2 * e }, r.radius + @as(f64, @floatFromInt(g)) + fw / 2, fw, ui.th.accent);
}
