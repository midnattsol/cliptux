//! "Recent captures" (`shotlet history`, and the tray menu): a small
//! panel listing the kept captures as a two-column grid of thumbnails
//! with relative times. Click one to pick it, then Copy, Save, Annotate,
//! Pin or Delete it (Enter copies, Delete removes, Esc closes). Clear
//! history, in the footer while nothing is picked, asks before it clears
//! everything (Cancel, Esc or any other click back out). When
//! Tesseract is installed the captures are read in the background and a
//! search field filters them by their text; without it there is no field.
//!
//! Facade over history_ui/: panel (state and actions), layout, events,
//! render and ocr_scan (the background reader).

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const clock = @import("clock.zig");
const clipimg = @import("clipimg.zig");
const ocr = @import("../platform/api.zig").ocr;
const sys = @import("../platform/api.zig").sys;
const text = @import("../gfx/text.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const theme_mod = @import("../ui/theme.zig");
const layout = @import("history_ui/layout.zig");
const Panel = @import("history_ui/panel.zig").Panel;
const Env = env_mod.Env;

pub const panel_w = layout.panel_w;
pub const relTime = clock.relTime;
pub const Action = layout.Action;

pub fn run(gpa: std.mem.Allocator, env: Env, smoke_ms: i64) !void {
    text.init(gpa);
    defer text.deinit();
    var p: Panel = .{
        .gpa = gpa,
        .env = env,
        .cfg = config.load(gpa, env.home),
        .win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display),
    };
    defer p.deinit();
    p.root_len = (try history.historyRoot(&p.root_buf, env.home)).len;
    if (p.bus_()) |b| p.theme = fui.Theme.fromPrefs(theme_mod.readPrefs(b, 1000));
    try p.load();
    p.searchable = ocr.available();
    std.log.info("history: text search {s}", .{if (p.searchable) "on (tesseract)" else "off (no libtesseract)"});
    try open(&p);
    p.startOcr();
    const end = if (smoke_ms > 0) sys.monoMs() + smoke_ms else 0;
    events: while (true) {
        if (end != 0 and sys.monoMs() > end) break;
        try p.render();
        const ev = (try p.win.nextEventTimeout(250)) orelse {
            p.pollOcr();
            p.expireNotice();
            continue;
        };
        if (!try p.onEvent(ev)) break;
        // the rest of the batch: a close in it (the second of two quick
        // Escs) closes the panel too
        while (try p.win.nextEventTimeout(0)) |e2| if (!try p.onEvent(e2)) break :events;
        clipimg.takeDrop(gpa, env, &p.win);
        p.pollOcr();
    }
    p.win.closeWindow();
    if (p.win.hasClipboard()) try p.win.serveClipboard();
}

/// Open the panel's transparent window, sized to it plus its shadow.
fn open(p: *Panel) !void {
    const w: u32 = panel_w + 2 * layout.pad;
    const h: u32 = @intCast(p.panelH() + 2 * layout.pad);
    // an image dropped here opens in the editor
    p.win.accept_mimes = &clipimg.drop_mimes;
    try p.win.open("Recent captures", .{ .fullscreen = false, .transparent = true, .width = w, .height = h });
    p.win.report_leave = true;
    p.win.setCursor(.arrow) catch {};
    try p.resize();
}
