//! The editor's event loop: wait for input or the next animation frame,
//! dispatch events, render when a surface is free, and follow the
//! desktop's appearance while open.

const std = @import("std");
const editor = @import("../editor.zig");
const ui = @import("../editor_ui.zig");
const theme_mod = @import("../theme.zig");
const motion = @import("../motion.zig");
const tools = @import("../tools/mod.zig");
const events = @import("events.zig");
const render = @import("render.zig");
const exporter = @import("export.zig");
const script = @import("script.zig");
const fade = @import("fade.zig");

const Editor = editor.Editor;

pub fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Run the editor; returns the user's chosen action and exported PNG.
pub fn run(ed: *Editor) !editor.Result {
    if (getenv("SHOTLET_EDITOR_SCRIPT")) |s| ed.script.src = s;
    while (ed.running) {
        const now = nowMs();
        if (ed.smoke_deadline_ms != 0 and now > ed.smoke_deadline_ms) {
            ed.action = .cancel;
            break;
        }
        hideCopyNoticeWhenDue(ed, now);
        const scripted = script.pending(ed);
        pollBus(ed);
        try pumpEvents(ed, waitMs(ed, now, scripted));
        if (render.renderReady(ed)) {
            // drain buffered Wayland events to get latest pointer position
            try ed.win.drainPending();
            try drainQueue(ed);
            try render.renderFrame(ed);
        }
        if (scripted and !ed.needs_render) try script.step(ed);
    }
    if (getenv("SHOTLET_EDITOR_DUMP")) |prefix| exporter.dumpAtExit(ed, prefix);
    if (ed.action == .cancel or ed.action == .copied) return .{ .action = ed.action };
    return .{ .action = ed.action, .png_data = try exporter.exportPng(ed) };
}

fn hideCopyNoticeWhenDue(ed: *Editor, now: i64) void {
    if (ed.copy_notice_hide_at_ms == 0 or now < ed.copy_notice_hide_at_ms) return;
    ed.copy_notice = .none;
    ed.copy_notice_hide_at_ms = 0;
    ed.needs_render = true;
}

/// How long to wait for input: transitions draw a frame per refresh, a
/// tooltip wakes when due, the tools may ask for sooner.
fn waitMs(ed: *Editor, now: i64, scripted: bool) i32 {
    const anim = ui.animating(ed) or fade.entering(ed);
    if (anim) ed.needs_render = true;
    var wait: i32 = if (scripted) 5 else if (anim) 8 else 100;
    wait = @min(wait, tools.tick(ed, now));
    const tip = ui.tooltipDueMs(ed);
    if (tip != 0) {
        if (tip <= now) ed.needs_render = true else wait = @min(wait, @as(i32, @intCast(std.math.clamp(tip - now, 1, 100))));
    }
    return wait;
}

/// Wait up to `wait` ms for an event, then handle everything queued.
fn pumpEvents(ed: *Editor, wait: i32) !void {
    const ev = try ed.win.nextEventTimeout(ed.win.pollTimeoutMs(wait)) orelse return;
    try events.handle(ed, ev);
    try drainQueue(ed);
}

fn drainQueue(ed: *Editor) !void {
    while (ed.win.queue.items.len > 0) {
        try events.handle(ed, try ed.win.nextEvent());
    }
}

/// Follow the desktop's appearance while open (Settings portal
/// SettingChanged), without blocking.
fn pollBus(ed: *Editor) void {
    const conn = ed.bus orelse return;
    var n: usize = 0;
    while (n < 16) : (n += 1) {
        var msg = (conn.nextMessageDeadline(nowMs()) catch return) orelse return;
        defer msg.deinit(ed.alloc);
        if (theme_mod.applySignal(&ed.prefs, &msg)) setPrefs(ed, ed.prefs);
    }
}

/// Apply appearance preferences: colours and motion.
pub fn setPrefs(ed: *Editor, prefs: theme_mod.Prefs) void {
    ed.prefs = prefs;
    ed.theme = prefs.theme();
    // scripted runs dump frames: keep them independent of timing
    motion.enabled = prefs.animations and getenv("SHOTLET_EDITOR_SCRIPT") == null;
    for (ed.panes[0..ed.n_panes]) |*p| {
        for (&p.backdrops) |*b| b.hash = 0;
        p.gen +%= 1;
    }
    ed.needs_render = true;
}
