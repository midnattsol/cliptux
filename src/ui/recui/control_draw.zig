//! Layout and drawing of the recording control (control.zig): a dark
//! Glass pill, in logical pixels, scaled when painted.
//!
//!   countdown:  [ 3   Recording in 3…   × ]
//!   recording:  [ ● 0:12 | ❚❚  ■  🗑 ]

const std = @import("std");
const fui = @import("../floatui.zig");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const icons = @import("../icons.zig");
const Rect = @import("../window.zig").Rect;

pub const Mode = enum { countdown, recording };
pub const Button = enum { pause, stop, discard, cancel, skip };

pub const State = struct {
    mode: Mode = .countdown,
    count: u32 = 3,
    elapsed_ms: i64 = 0,
    paused: bool = false,
    pulse: bool = false,
    hover: ?Button = null,
};

const pad = 16; // room for the shadow
const pill_w = 232;
const pill_h = 44;
const btn = 32;

const bg: u32 = 0xFF1F1F23;
const fg: u32 = 0xFFF5F5F7;
const muted: u32 = 0xFFA1A1AA;
const hover_bg: u32 = 0xFF34343A;
const red: u32 = 0xFFFF453A;

pub fn windowSize() [2]u32 {
    return .{ pill_w + 2 * pad, pill_h + 2 * pad };
}

pub fn pillRect() Rect {
    return .{ .x = pad, .y = pad, .w = pill_w, .h = pill_h };
}

/// A button's rectangle, relative to the pill.
fn buttonRect(b: Button) Rect {
    const y = (pill_h - btn) / 2;
    return switch (b) {
        .pause => .{ .x = pill_w - 6 - 3 * btn - 8, .y = y, .w = btn, .h = btn },
        .stop => .{ .x = pill_w - 6 - 2 * btn - 4, .y = y, .w = btn, .h = btn },
        .discard, .cancel => .{ .x = pill_w - 6 - btn, .y = y, .w = btn, .h = btn },
        .skip => .{ .x = 0, .y = 0, .w = pill_w - 6 - btn, .h = pill_h },
    };
}

fn buttons(mode: Mode) []const Button {
    return switch (mode) {
        .countdown => &.{ .cancel, .skip },
        .recording => &.{ .pause, .stop, .discard },
    };
}

/// The button under a logical point of the window.
pub fn hit(x: f64, y: f64, mode: Mode) ?Button {
    const px: i32 = @as(i32, @intFromFloat(x)) - pad;
    const py: i32 = @as(i32, @intFromFloat(y)) - pad;
    for (buttons(mode)) |b| {
        const r = buttonRect(b);
        if (px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h) return b;
    }
    return null;
}

/// "0:07", "12:30", "1:02:03"
pub fn formatTime(buf: []u8, ms: i64) []const u8 {
    const s: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

fn sc(v: i32, k: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * k));
}

/// Paint onto a transparent (straight alpha) buffer of the window.
pub fn paint(gpa: std.mem.Allocator, px: []u32, bw: u32, bh: u32, k: f64, st: *const State) void {
    const cw: u32 = @intCast(sc(pill_w, k));
    const ch: u32 = @intCast(sc(pill_h, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    @memset(card, bg);
    var cv = render.Canvas.init(card, cw, ch);
    switch (st.mode) {
        .countdown => paintCountdown(&cv, k, st),
        .recording => paintRecording(&cv, k, st),
    }
    fui.placeCard(px, bw, bh, card, cw, ch, sc(pad, k), sc(pad, k), @intCast(sc(pill_h / 2, k)), @intCast(sc(10, k)));
}

fn buttonBg(cv: *render.Canvas, k: f64, b: Button, st: *const State) Rect {
    const r = buttonRect(b);
    const s: Rect = .{ .x = sc(r.x, k), .y = sc(r.y, k), .w = sc(r.w, k), .h = sc(r.h, k) };
    if (st.hover == b) cv.fillRoundRectAA(s.x, s.y, s.w, s.h, 9 * k, hover_bg);
    return s;
}

fn paintCountdown(cv: *render.Canvas, k: f64, st: *const State) void {
    var buf: [32]u8 = undefined;
    const fs = 22 * k;
    const digit = std.fmt.bufPrint(&buf, "{d}", .{st.count}) catch "";
    const cy = @divTrunc(cv.h, 2);
    text.drawStyled(cv, sc(18, k), cy - @divTrunc(text.heightStyled(fs, .semibold), 2), fs, red, text.Style.semibold.num(), digit);
    const label = if (st.hover == .skip) "Start now" else "Recording starts\u{2026}";
    const ls = 13 * k;
    text.draw(cv, sc(46, k), cy - @divTrunc(text.height(ls), 2), ls, if (st.hover == .skip) fg else muted, label);
    const r = buttonBg(cv, k, .cancel, st);
    icons.drawCentered(cv, .close, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2), sc(16, k), fg);
}

fn paintRecording(cv: *render.Canvas, k: f64, st: *const State) void {
    const cy = @as(f64, @floatFromInt(cv.h)) / 2;
    const dot: u32 = if (st.paused) muted else if (st.pulse) red else 0xFFC8352C;
    cv.fillCircleAA(18 * k, cy, 6 * k, dot);
    var buf: [32]u8 = undefined;
    const fs = 15 * k;
    const t = formatTime(&buf, st.elapsed_ms);
    text.drawStyled(cv, sc(32, k), @as(i32, @intFromFloat(cy)) - @divTrunc(text.heightStyled(fs, .semibold), 2), fs, if (st.paused) muted else fg, text.Style.semibold.num(), t);
    const sep_x = sc(buttonRect(.pause).x - 6, k);
    cv.fillRect(sep_x, sc(12, k), @max(1, sc(1, k)), sc(pill_h - 24, k), 0xFF3A3A40);
    paintPause(cv, k, st);
    const s = buttonBg(cv, k, .stop, st);
    const q = sc(12, k);
    cv.fillRoundRectAA(s.x + @divTrunc(s.w - q, 2), s.y + @divTrunc(s.h - q, 2), q, q, 2.5 * k, red);
    const d = buttonBg(cv, k, .discard, st);
    icons.drawCentered(cv, .trash, d.x + @divTrunc(d.w, 2), d.y + @divTrunc(d.h, 2), sc(17, k), fg);
}

fn paintPause(cv: *render.Canvas, k: f64, st: *const State) void {
    const r = buttonBg(cv, k, .pause, st);
    const cx = r.x + @divTrunc(r.w, 2);
    const cy = r.y + @divTrunc(r.h, 2);
    if (st.paused) {
        // resume: a play triangle, drawn as narrowing bars
        const h = sc(14, k);
        var i: i32 = 0;
        while (i < h) : (i += 1) {
            const half = @divTrunc(h, 2);
            const w = half - @as(i32, @intCast(@abs(i - half)));
            cv.fillRect(cx - @divTrunc(half, 2), cy - half + i, w + 1, 1, fg);
        }
        return;
    }
    const bw = sc(4, k);
    const bh = sc(14, k);
    cv.fillRoundRectAA(cx - bw - sc(2, k), cy - @divTrunc(bh, 2), bw, bh, 1.5 * k, fg);
    cv.fillRoundRectAA(cx + sc(2, k), cy - @divTrunc(bh, 2), bw, bh, 1.5 * k, fg);
}

test "time format and hit testing" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0:07", formatTime(&buf, 7400));
    try std.testing.expectEqualStrings("12:30", formatTime(&buf, 750_000));
    try std.testing.expectEqualStrings("1:02:03", formatTime(&buf, 3_723_000));
    const r = buttonRect(.stop);
    try std.testing.expectEqual(@as(?Button, .stop), hit(@floatFromInt(pad + r.x + 4), @floatFromInt(pad + r.y + 4), .recording));
    try std.testing.expectEqual(@as(?Button, null), hit(1, 1, .recording));
    try std.testing.expectEqual(@as(?Button, .skip), hit(pad + 20, pad + 20, .countdown));
}
