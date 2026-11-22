//! Dev hook: scripted input (SHOTLET_EDITOR_SCRIPT), one `;`-separated
//! command per idle frame. Commands synthesize window events (move,
//! down, up, click, rclick, drag, scribble, scroll, key, type, hold,
//! release, unplug) or act directly (sel, tool, button, textwidth,
//! surface, render, dump, export, quit).

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const shapes_mod = @import("../shapes.zig");
const ui = @import("../editor_ui.zig");
const script_input = @import("../script_input.zig");
const session = @import("session.zig");
const events = @import("events.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const commands = @import("commands.zig");
const hit = @import("hit.zig");
const render = @import("render.zig");
const exporter = @import("export.zig");

const Editor = editor.Editor;
const Tool = editor.Tool;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const parsePoint = script_input.parsePoint;
const parseInts = script_input.parseInts;

/// Is there a command left to run, and something to run it on?
pub fn pending(ed: *const Editor) bool {
    const src = ed.script.src orelse return false;
    return ed.script.pos < src.len and ed.panes[0].viewc.len > 0;
}

/// Run the next command; a failing one is logged and skipped.
pub fn step(ed: *Editor) !void {
    const src = ed.script.src.?;
    var end = std.mem.indexOfScalarPos(u8, src, ed.script.pos, ';') orelse src.len;
    const cmd = std.mem.trim(u8, src[ed.script.pos..end], " \n\t");
    if (end < src.len) end += 1;
    ed.script.pos = end;
    if (cmd.len == 0) return;
    runCommand(ed, cmd) catch |e| std.log.warn("script '{s}': {t}", .{ cmd, e });
    ed.needs_render = true;
}

const Op = enum { move, down, up, click, rclick, drag, scribble, scroll, key, type, sel, tool, button, render, dump, hold, release, unplug, surface, textwidth, @"export", quit };

fn runCommand(ed: *Editor, cmd: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const word = it.next() orelse return;
    const arg = std.mem.trim(u8, it.rest(), " ");
    const op = std.meta.stringToEnum(Op, word) orelse return error.BadScript;
    switch (op) {
        .move => try moveTo(ed, try parsePoint(arg)),
        .down, .up => try button(ed, .left, op == .down, try parsePoint(arg)),
        .click => try click(ed, .left, try parsePoint(arg)),
        .rclick => try click(ed, .right, try parsePoint(arg)),
        .drag => try dragPath(ed, arg),
        .scribble => try scribble(ed, arg),
        .scroll => try scroll(ed, arg),
        .key => try events.handle(ed, .{ .key = try script_input.parseKey(arg) }),
        .type => try typeText(ed, arg),
        .sel => try setSelection(ed, arg),
        .tool => try setTool(ed, arg),
        .button => try pressButton(ed, arg),
        .render => try render.renderFrame(ed),
        .dump => try dumpSurface(ed, arg),
        .hold, .release => try holdKey(ed, arg, op == .hold),
        // editor side of an output going away
        .unplug => try events.handle(ed, .{ .resize = .{ .w = 0, .h = 0, .surface = try std.fmt.parseInt(u8, arg, 10) } }),
        .surface => ed.script.surface = try std.fmt.parseInt(u8, arg, 10),
        .textwidth => try dragTextWidth(ed, arg),
        .@"export" => exporter.dumpExport(ed, arg),
        .quit => commands.finish(ed, .cancel),
    }
}

// --- synthesized pointer events on the script's surface ---

fn motion(ed: *Editor, x: f64, y: f64) !void {
    try events.handle(ed, .{ .pointer_motion = .{ .surface = ed.script.surface, .x = x, .y = y } });
}

fn buttonXY(ed: *Editor, btn: window.Button, pressed: bool, x: f64, y: f64) !void {
    try events.handle(ed, .{ .pointer_button = .{ .surface = ed.script.surface, .button = btn, .pressed = pressed, .x = x, .y = y } });
}

fn moveTo(ed: *Editor, p: Point) !void {
    try motion(ed, @floatFromInt(p.x), @floatFromInt(p.y));
}

fn button(ed: *Editor, btn: window.Button, pressed: bool, p: Point) !void {
    try buttonXY(ed, btn, pressed, @floatFromInt(p.x), @floatFromInt(p.y));
}

fn click(ed: *Editor, btn: window.Button, p: Point) !void {
    try moveTo(ed, p);
    try button(ed, btn, true, p);
    try button(ed, btn, false, p);
}

/// drag X,Y X2,Y2: a left drag along a slight arc.
fn dragPath(ed: *Editor, arg: []const u8) !void {
    var pts = std.mem.tokenizeScalar(u8, arg, ' ');
    const a = try parsePoint(pts.next() orelse return error.BadScript);
    const b = try parsePoint(pts.next() orelse return error.BadScript);
    try moveTo(ed, a);
    try button(ed, .left, true, a);
    for (1..13) |i| {
        const t = @as(f64, @floatFromInt(i)) / 12.0;
        const x = @as(f64, @floatFromInt(a.x)) + @as(f64, @floatFromInt(b.x - a.x)) * t;
        const y = @as(f64, @floatFromInt(a.y)) + @as(f64, @floatFromInt(b.y - a.y)) * t + @sin(t * std.math.pi) * 20;
        try motion(ed, x, y);
    }
    try moveTo(ed, b);
    try button(ed, .left, false, b);
}

/// scribble cx,cy,r,n: a long freehand stroke, rendering a frame per
/// motion, and log the time per frame.
fn scribble(ed: *Editor, arg: []const u8) !void {
    const v = try parseInts(4, arg);
    const t0 = session.nowMs();
    const n: usize = @intCast(v[3]);
    for (0..n + 1) |i| {
        const a = @as(f64, @floatFromInt(i)) * 0.05;
        const rr = @as(f64, @floatFromInt(v[2])) * (0.3 + 0.7 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)));
        const x = @as(f64, @floatFromInt(v[0])) + @cos(a) * rr;
        const y = @as(f64, @floatFromInt(v[1])) + @sin(a) * rr;
        try motion(ed, x, y);
        if (i == 0) try buttonXY(ed, .left, true, x, y);
        try render.renderFrame(ed);
    }
    const t1 = session.nowMs();
    try buttonXY(ed, .left, false, 0, 0);
    std.log.info("scribble: {d} frames in {d} ms, commit {d} ms", .{ n, t1 - t0, session.nowMs() - t1 });
}

/// scroll V, or scroll v120:N for a high-resolution wheel.
fn scroll(ed: *Editor, arg: []const u8) !void {
    if (std.mem.startsWith(u8, arg, "v120:")) {
        try events.handle(ed, .{ .pointer_axis = .{ .value = 0, .value120 = try std.fmt.parseInt(i32, arg[5..], 10) } });
    } else try events.handle(ed, .{ .pointer_axis = .{ .value = try std.fmt.parseFloat(f64, arg) } });
}

// --- keys ---

/// type TEXT: one IME commit per character; `|` is Enter.
fn typeText(ed: *Editor, arg: []const u8) !void {
    var i: usize = 0;
    while (i < arg.len) {
        const n = std.unicode.utf8ByteSequenceLength(arg[i]) catch 1;
        var k: window.Key = .{ .code = .none, .pressed = true, .ctrl = false, .shift = false };
        const piece = arg[i..@min(arg.len, i + n)];
        if (std.mem.eql(u8, piece, "|")) {
            k.code = .enter;
        } else {
            @memcpy(k.text_buf[0..piece.len], piece);
            k.text_len = @intCast(piece.len);
        }
        try events.handle(ed, .{ .key = k });
        i += n;
    }
}

/// hold shift|alt|space ... release shift|alt|space
fn holdKey(ed: *Editor, arg: []const u8, down: bool) !void {
    const eql = std.mem.eql;
    const code: window.KeyCode = if (eql(u8, arg, "shift")) .shift_left else if (eql(u8, arg, "alt")) .alt_left else if (eql(u8, arg, "space")) .space else return error.BadKey;
    try events.handle(ed, .{ .key = .{ .code = code, .pressed = down, .ctrl = false, .shift = down and code == .shift_left, .alt = down and code == .alt_left } });
}

// --- direct actions ---

/// sel X,Y,W,H: the selection, in window pixels.
fn setSelection(ed: *Editor, arg: []const u8) !void {
    const v = try parseInts(4, arg);
    caches.selDirty(ed);
    const a = hit.clampImg(ed, ed.imgAt(.{ .x = v[0], .y = v[1] }));
    const b = hit.clampImg(ed, ed.imgAt(.{ .x = v[0] + v[2], .y = v[1] + v[3] }));
    ed.doc.sel = Rect.fromCorners(a, b);
    caches.selDirty(ed);
}

fn setTool(ed: *Editor, arg: []const u8) !void {
    inline for (@typeInfo(Tool).@"enum".field_names) |name| {
        if (std.mem.eql(u8, arg, name)) try props.setTool(ed, @field(Tool, name));
    }
}

/// button NAME: click a control by name; controls in the popover or the
/// menu open it first.
fn pressButton(ed: *Editor, name: []const u8) !void {
    for (0..2) |attempt| {
        for (ed.buttons.items) |b| {
            if (std.mem.eql(u8, ui.buttonName(b.kind), name)) {
                return click(ed, .left, .{ .x = b.rect.x + @divTrunc(b.rect.w, 2), .y = b.rect.y + @divTrunc(b.rect.h, 2) });
            }
        }
        if (attempt == 1) break;
        try openHolder(ed, name);
    }
    return error.NoSuchButton;
}

/// The control `name` is not laid out yet: open what holds it, lay it
/// all out again.
fn openHolder(ed: *Editor, name: []const u8) !void {
    const want: ?ui.Popover = switch (ui.nameLayer(name) orelse .bar) {
        .popover => .colors,
        .menu => .more,
        else => null,
    };
    if (want) |w| if (ed.popover != w) commands.togglePopover(ed, w);
    ed.pane_i = ed.tb_pane;
    defer ed.pane_i = ed.mouse_pane;
    try ui.layoutToolbar(ed);
}

/// dump PATH: the script surface's frame, rendered now.
fn dumpSurface(ed: *Editor, path: []const u8) !void {
    const idx = ed.script.surface;
    if (idx >= ed.n_panes or !ed.panes[idx].alive) return error.NoSuchSurface;
    for (ed.panes[0..ed.n_panes]) |*p| p.due = p.alive;
    try render.renderFrame(ed);
    ed.pane_i = idx;
    defer ed.pane_i = ed.mouse_pane;
    if (ed.panes[idx].due) {
        try render.renderPane(ed, idx);
        ed.panes[idx].due = false;
    }
    exporter.dumpFrame(ed, path);
}

/// textwidth DX: drag the width handle of the text being edited (or the
/// selected one) DX pixels; textwidth auto: double-click it.
fn dragTextWidth(ed: *Editor, arg: []const u8) !void {
    const i = hit.textHandleShape(ed) orelse return error.NoText;
    ed.pane_i = ed.script.surface;
    const h = hit.textWidthHandle(ed, i);
    ed.pane_i = ed.mouse_pane;
    if (std.mem.eql(u8, arg, "auto")) {
        try click(ed, .left, h);
        try click(ed, .left, h);
        return;
    }
    const dx = try std.fmt.parseInt(i32, arg, 10);
    try moveTo(ed, h);
    try button(ed, .left, true, h);
    for (1..9) |k| {
        const x = @as(f64, @floatFromInt(h.x)) + @as(f64, @floatFromInt(dx)) * @as(f64, @floatFromInt(k)) / 8.0;
        try motion(ed, x, @floatFromInt(h.y));
    }
    try button(ed, .left, false, .{ .x = h.x + dx, .y = h.y });
}
