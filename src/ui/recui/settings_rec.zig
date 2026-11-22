//! The Settings window's Recording view (settings.zig draws the frame):
//! format, frame rates, quality, the GIF size, the countdown, and what is
//! recorded by default (microphone, system sound, clicks, keystrokes).
//! Each change is written at once (record/settings.zig keys).

const std = @import("std");
const settings = @import("../settings.zig");
const theme_mod = @import("../theme.zig");
const rs = @import("../../record/settings.zig");
const shell = @import("../../platform/api.zig").shell;

pub const Hit = enum(u8) {
    fmt_minus,
    fmt_plus,
    fps_minus,
    fps_plus,
    q_minus,
    q_plus,
    gif_fps_minus,
    gif_fps_plus,
    gif_w_minus,
    gif_w_plus,
    cd_minus,
    cd_plus,
    mic,
    system,
    clicks,
    keys,
};

fn h(x: Hit) settings.Hit {
    return .{ .rec = @backingInt(x) };
}

fn home() []const u8 {
    return if (std.c.getenv("HOME")) |p| std.mem.span(p) else "/";
}

const fps_steps = [_]u32{ 15, 24, 30, 60 };
const gif_fps_steps = [_]u32{ 10, 12, 15, 20, 25, 30 };
const gif_w_steps = [_]u32{ 320, 480, 640, 800, 1024, 1280, 0 };
const cd_steps = [_]u32{ 0, 3, 5, 10 };

/// The next value in `steps` (wrapping at neither end).
pub fn step(steps: []const u32, v: u32, up: bool) u32 {
    const i = std.mem.indexOfScalar(u32, steps, v) orelse return steps[steps.len / 2];
    if (up) return steps[@min(i + 1, steps.len - 1)];
    return steps[if (i == 0) 0 else i - 1];
}

pub fn draw(ui: *settings.Ui, gpa: std.mem.Allocator, cx: i32, y0: i32, col_w: i32) !i32 {
    const s = rs.load(gpa, home());
    const rh = ui.sc(theme_mod.row_h);
    var y = try settings.groupTitle(ui, cx, y0, col_w, "Recording", null);
    var card = settings.beginCard(ui, cx, y, col_w, 4 * rh);
    var buf: [32]u8 = undefined;
    try stepRow(ui, &card, "Format", "Also on the bar when you choose the area", if (s.format == .mp4) "MP4 video" else "GIF", .fmt_minus, .fmt_plus);
    try stepRow(ui, &card, "Video frame rate", null, std.fmt.bufPrint(&buf, "{d} fps", .{s.fps}) catch "?", .fps_minus, .fps_plus);
    try stepRow(ui, &card, "Video quality", "Higher: larger files", @tagName(s.quality), .q_minus, .q_plus);
    try stepRow(ui, &card, "Countdown", "Click it to start at once", if (s.countdown == 0) "None" else std.fmt.bufPrint(&buf, "{d} s", .{s.countdown}) catch "?", .cd_minus, .cd_plus);
    y = settings.endCard(&card) + ui.sc(26);

    y = try settings.groupTitle(ui, cx, y, col_w, "GIF", null);
    card = settings.beginCard(ui, cx, y, col_w, 2 * rh);
    try stepRow(ui, &card, "Frame rate", "Fewer frames: smaller files", std.fmt.bufPrint(&buf, "{d} fps", .{s.gif_fps}) catch "?", .gif_fps_minus, .gif_fps_plus);
    try stepRow(ui, &card, "At most this wide", null, if (s.gif_width == 0) "Full size" else std.fmt.bufPrint(&buf, "{d} px", .{s.gif_width}) catch "?", .gif_w_minus, .gif_w_plus);
    y = settings.endCard(&card) + ui.sc(26);

    y = try settings.groupTitle(ui, cx, y, col_w, "Record by default", null);
    card = settings.beginCard(ui, cx, y, col_w, 4 * rh);
    try settings.switchRow(ui, &card, "Microphone", "MP4 only", s.mic, h(.mic));
    try settings.switchRow(ui, &card, "System sound", "What the speakers play; MP4 only", s.system_audio, h(.system));
    var needs_buf: [64]u8 = undefined;
    const needs = std.fmt.bufPrint(&needs_buf, "Needs the {s}", .{shell.words().title}) catch null;
    try settings.switchRow(ui, &card, "Show clicks", needs, s.clicks, h(.clicks));
    try settings.switchRow(ui, &card, "Show keystrokes", needs, s.keys, h(.keys));
    return settings.endCard(&card) + ui.sc(26);
}

fn stepRow(ui: *settings.Ui, card: *settings.Card, title: []const u8, sub: ?[]const u8, value: []const u8, minus: Hit, plus: Hit) !void {
    const r = settings.rowBegin(ui, card, ui.sc(theme_mod.row_h));
    settings.rowTitle(ui, r, title, sub);
    try settings.valueStepper(ui, r, value, h(minus), h(plus));
}

fn tf(v: bool) []const u8 {
    return if (v) "true" else "false";
}

pub fn activate(gpa: std.mem.Allocator, home_dir: []const u8, raw: u8) void {
    const s = rs.load(gpa, home_dir);
    var buf: [16]u8 = undefined;
    const hit: Hit = @fromBackingInt(raw);
    const up = switch (hit) {
        .fmt_plus, .fps_plus, .q_plus, .gif_fps_plus, .gif_w_plus, .cd_plus => true,
        else => false,
    };
    const kv: struct { []const u8, []const u8 } = switch (hit) {
        .fmt_minus, .fmt_plus => .{ "record_format", if (s.format == .mp4) "gif" else "mp4" },
        .fps_minus, .fps_plus => .{ "record_fps", num(&buf, step(&fps_steps, s.fps, up)) },
        .q_minus, .q_plus => .{ "record_quality", @tagName(qualityStep(s.quality, up)) },
        .gif_fps_minus, .gif_fps_plus => .{ "record_gif_fps", num(&buf, step(&gif_fps_steps, s.gif_fps, up)) },
        .gif_w_minus, .gif_w_plus => .{ "record_gif_width", num(&buf, step(&gif_w_steps, s.gif_width, up)) },
        .cd_minus, .cd_plus => .{ "record_countdown", num(&buf, step(&cd_steps, s.countdown, up)) },
        .mic => .{ "record_mic", tf(!s.mic) },
        .system => .{ "record_system_audio", tf(!s.system_audio) },
        .clicks => .{ "record_clicks", tf(!s.clicks) },
        .keys => .{ "record_keys", tf(!s.keys) },
    };
    rs.save(gpa, home_dir, kv[0], kv[1]);
}

fn num(buf: []u8, v: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}

fn qualityStep(q: @import("../../encode/sink.zig").Quality, up: bool) @import("../../encode/sink.zig").Quality {
    return switch (q) {
        .low => if (up) .medium else .low,
        .medium => if (up) .high else .low,
        .high => if (up) .high else .medium,
    };
}

test "steppers move along their lists" {
    try std.testing.expectEqual(@as(u32, 60), step(&fps_steps, 30, true));
    try std.testing.expectEqual(@as(u32, 60), step(&fps_steps, 60, true));
    try std.testing.expectEqual(@as(u32, 0), step(&gif_w_steps, 1280, true));
    try std.testing.expectEqual(@as(u32, 30), step(&fps_steps, 17, false));
}
