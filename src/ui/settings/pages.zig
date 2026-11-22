//! The content of each Settings view (General, Editor, Shortcuts,
//! Recording): its groups of boxed-list cards, top to bottom. Every
//! group takes the y it starts at and returns the y after it.

const std = @import("std");
const config = @import("../../app/config.zig");
const theme_mod = @import("../theme.zig");
const shapes = @import("../shapes.zig");
const shell = @import("../../platform/api.zig").shell;
const settings_modes = @import("../settings_modes.zig");
const settings_rec = @import("../recui/settings_rec.zig");
const model = @import("model.zig");
const w = @import("widgets.zig");
const perms = @import("permissions.zig");

const Ui = w.Ui;
const State = model.State;

/// The column the cards go in, and what they show.
pub const Page = struct {
    ui: *Ui,
    cx: i32,
    col_w: i32,
    cfg: *const config.Config,
    st: *const State,
    /// the folder chooser is open
    choosing: bool,

    fn title(p: Page, y: i32, s: []const u8, link: ?[]const u8) !i32 {
        return w.groupTitle(p.ui, p.cx, y, p.col_w, s, link);
    }

    fn card(p: Page, y: i32, h: i32) w.Card {
        return w.beginCard(p.ui, p.cx, y, p.col_w, h);
    }

    fn rowH(p: Page) i32 {
        return p.ui.sc(theme_mod.row_h);
    }
};

/// The view's content from y; returns where it ends.
pub fn drawView(p: Page, y: i32) !i32 {
    return switch (p.st.view) {
        .general => try general(p, y),
        .editor => try editor(p, y),
        .recording => try settings_rec.draw(p.ui, p.ui.alloc, p.cx, y, p.col_w),
        .shortcuts => try shortcuts(p, y),
    };
}

fn general(p: Page, y0: i32) !i32 {
    var y = try afterCapture(p, y0);
    y = try capture(p, y);
    y = try quickAccess(p, y);
    y = try recentCaptures(p, y);
    if (p.st.integration != .unsupported) y = try integration(p, y);
    y = try globalShortcut(p, y);
    return settings_modes.drawGeneral(p.ui, p.cx, y, p.col_w, &p.st.modes);
}

fn afterCapture(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const cfg = p.cfg;
    const y = try p.title(y0, "After capture", null);
    var card = p.card(y, 3 * p.rowH());
    try w.switchRow(ui, &card, "Notification after saving", "Shows where the file went", cfg.notify, .toggle_notify);
    try w.switchRow(ui, &card, "Also copy when saving", "Ctrl+S puts the image on the clipboard too", cfg.copy_on_save, .toggle_copy_on_save);
    const r = w.rowBegin(ui, &card, p.rowH());
    w.rowTitle(ui, r, "Save to", if (p.choosing) "Choosing a folder\u{2026}" else null);
    var buf: [300]u8 = undefined;
    const shown = folderLabel(cfg.saveDir(), &buf);
    try w.chipButton(ui, r, .choose_folder, .folder, shown, false);
    return w.endCard(&card) + ui.sc(26);
}

fn capture(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const st = p.st;
    const y = try p.title(y0, "Capture", null);
    var card = p.card(y, 3 * p.rowH());
    var line_buf: [160]u8 = undefined;
    w.rowTitle(ui, w.rowBegin(ui, &card, p.rowH()), "Capture", perms.captureLine(st, &line_buf));
    const r = w.rowBegin(ui, &card, p.rowH());
    const remembered = p.cfg.scToken() != null;
    if (st.direct) {
        // the desktop lets Shotlet capture every monitor itself
        w.rowTitle(ui, r, "Monitors", "All of them, captured directly (no prompts)");
    } else {
        w.rowTitle(ui, r, "Monitors", if (remembered) "Your choice is remembered" else "Asks on the next capture");
        if (remembered) try w.chipButton(ui, r, .forget_monitors, null, "Choose again", true);
    }
    try perms.drawRow(ui, &card, p.rowH(), &st.perm_note);
    return w.endCard(&card) + ui.sc(26);
}

fn quickAccess(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const cfg = p.cfg;
    const y = try p.title(y0, "Quick access", null);
    var card = p.card(y, 2 * p.rowH());
    {
        const r = w.rowBegin(ui, &card, p.rowH());
        w.rowTitle(ui, r, "Show the thumbnail", "Copy again, save, drag into apps, annotate or pin it");
        try w.chipButton(ui, r, .cycle_thumbnail, null, cfg.thumbnail.label(), false);
    }
    const r = w.rowBegin(ui, &card, p.rowH());
    w.rowTitle(ui, r, "Stays for", "Longer while the pointer is on it");
    var buf: [16]u8 = undefined;
    try w.valueStepper(ui, r, std.fmt.bufPrint(&buf, "{d} s", .{cfg.quick_access_seconds}) catch "?", .quick_minus, .quick_plus);
    return w.endCard(&card) + ui.sc(26);
}

fn recentCaptures(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const cfg = p.cfg;
    const rh = p.rowH();
    const y = try p.title(y0, "Recent captures", null);
    var card = p.card(y, 4 * rh);
    try w.switchRow(ui, &card, "Keep copied and saved captures", "Private to you, in ~/.local/state/shotlet", cfg.history, .toggle_history);
    {
        const r = w.rowBegin(ui, &card, rh);
        w.rowTitle(ui, r, "Keep at most", null);
        var buf: [24]u8 = undefined;
        try w.valueStepper(ui, r, std.fmt.bufPrint(&buf, "{d} captures", .{cfg.history_max}) catch "?", .hist_minus, .hist_plus);
    }
    {
        const r = w.rowBegin(ui, &card, rh);
        w.rowTitle(ui, r, "Using at most", null);
        var buf: [24]u8 = undefined;
        try w.valueStepper(ui, r, std.fmt.bufPrint(&buf, "{d} MB", .{cfg.history_max_mb}) catch "?", .hist_mb_minus, .hist_mb_plus);
    }
    const r = w.rowBegin(ui, &card, rh);
    const asking = p.st.history_clear == .asking;
    w.rowTitle(ui, r, "Captures kept so far", switch (p.st.history_clear) {
        .idle => null,
        .asking => "This deletes every kept capture",
        .cleared => "Cleared",
    });
    try w.chipButton(ui, r, .clear_history, null, if (asking) "Yes, clear all" else "Clear history\u{2026}", asking);
    try w.chipButtonAt(ui, r, .open_history, "Open\u{2026}", ui.sc(150));
    return w.endCard(&card) + ui.sc(26);
}

fn integration(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const st = p.st;
    const words = st.words;
    const y = try p.title(y0, words.title, null);
    var card = p.card(y, ui.sc(64));
    const r = w.rowBegin(ui, &card, ui.sc(64));
    var buf: [128]u8 = undefined;
    w.rowTitle(ui, r, words.part, switch (st.integration) {
        .active => shell.note() orelse "On: no capture prompts; thumbnails and pins stay above other windows",
        .installed => "Installed; log out and in once to finish",
        .failed => std.fmt.bufPrint(&buf, "Could not install it; see {s}", .{words.command}) catch "Could not install it",
        else => "Off: the thumbnail is an ordinary window",
    });
    if (st.integration == .missing or st.integration == .failed) try w.chipButton(ui, r, .integration_enable, null, "Enable", true);
    return w.endCard(&card) + ui.sc(26);
}

fn globalShortcut(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const cap = p.st.capture;
    const y = try p.title(y0, "Global shortcut", null);
    var card = p.card(y, ui.sc(64));
    const r = w.rowBegin(ui, &card, ui.sc(64));
    const words = p.st.words;
    var buf: [160]u8 = undefined;
    if (cap.capture) {
        const sub = if (cap.shortcut() == null)
            std.fmt.bufPrint(&buf, "Pick one with {s} shortcut KEY", .{words.command})
        else if (cap.blocked)
            std.fmt.bufPrint(&buf, "{s}: pick another with {s} shortcut", .{ words.system_key, words.command })
        else
            std.fmt.bufPrint(&buf, "Set by the {s}: {s} shortcut", .{ words.title, words.command });
        w.rowTitle(ui, r, cap.shortcut() orelse "No shortcut", sub catch null);
    } else w.rowTitle(ui, r, "Bind a key to \u{201C}shotlet\u{201D}", words.custom_shortcuts);
    return w.endCard(&card) + ui.sc(26);
}

fn editor(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const cfg = p.cfg;
    const y = try p.title(y0, "New annotations", null);
    var card = p.card(y, 2 * p.rowH());
    {
        const r = w.rowBegin(ui, &card, p.rowH());
        w.rowTitle(ui, r, "Default colour", null);
        try w.swatchRow(ui, r, cfg.default_color);
    }
    const r = w.rowBegin(ui, &card, p.rowH());
    w.rowTitle(ui, r, "Default size", "Stroke width and text size; the wheel changes it while drawing");
    try w.sizeStepper(ui, r, cfg.default_thickness, shapes.palette[cfg.default_color]);
    return w.endCard(&card) + ui.sc(26);
}

fn shortcuts(p: Page, y0: i32) !i32 {
    var y = try settings_modes.drawShortcuts(p.ui, p.cx, y0, p.col_w, &p.st.modes);
    y = try editorShortcuts(p, y);
    return fixedKeys(p, y);
}

fn editorShortcuts(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    const y = try p.title(y0, "Editor shortcuts", "Reset to defaults");
    var card = p.card(y, @as(i32, config.n_actions) * ui.sc(48));
    inline for (0..config.n_actions) |i| {
        const action: config.Action = @fromBackingInt(@intCast(i));
        try w.shortcutRow(ui, &card, action.label(), ui.win, p.cfg.binds[i], p.st.recording == action, .{ .bind = action });
    }
    return w.endCard(&card) + ui.sc(26);
}

fn fixedKeys(p: Page, y0: i32) !i32 {
    const ui = p.ui;
    var y = try p.title(y0, "Fixed keys", null);
    const fixed = [_]struct { []const u8, []const []const u8 }{
        .{ "Copy and close", &.{"Enter"} },
        .{ "Cancel, then close", &.{"Esc"} },
        .{ "Preset colours", &.{ "1", "\u{2013}", "8" } },
        .{ "Size", &.{ "-", "=" } },
        .{ "All shortcuts", &.{"?"} },
    };
    var card = p.card(y, @as(i32, fixed.len) * ui.sc(48));
    for (fixed) |row| {
        const r = w.rowBegin(ui, &card, ui.sc(48));
        w.rowTitle(ui, r, row[0], null);
        _ = w.keyCaps(ui, r, row[1], null);
    }
    y = w.endCard(&card) + ui.sc(14);
    ui.label(p.cx + ui.sc(4), y, ui.sc(20), 13, ui.th.text_muted, .regular, "Click a shortcut (or focus it and press Enter), then press the new keys; Esc cancels.");
    return y + ui.sc(20) + ui.sc(26);
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

test "the save folder shows relative to home" {
    var buf: [300]u8 = undefined;
    try std.testing.expectEqualStrings("Pictures", folderLabel(null, &buf));
    try std.testing.expectEqualStrings("/srv/shots", folderLabel("/srv/shots", &buf));
}
