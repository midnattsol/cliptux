//! Settings of the capture modes, in the same file as the rest
//! (app/config.zig; written with config.update, which merges keys):
//!
//!     after_fullscreen=thumbnail   editor | thumbnail | copy | save:
//!                                  what a screen, all-screens or window
//!                                  capture does once taken (see
//!                                  delivery: never nothing, like an area)
//!     timer_seconds=5              the self-timer: 3, 5 or 10
//!     window_shadow=true           window captures get a soft shadow
//!     scroll_max_height=20000      scrolling captures stop there (px)
//!     scroll_auto=true             scroll for the person where possible

const std = @import("std");
const config = @import("../config.zig");
const env = @import("../env.zig");
const sys = @import("../../platform/sys.zig");
const mode = @import("mode.zig");

pub const After = enum {
    editor,
    thumbnail,
    copy,
    save,

    pub fn label(self: After) []const u8 {
        return switch (self) {
            .editor => "Open the editor",
            .thumbnail => "Copy, show the thumbnail",
            .copy => "Copy to the clipboard",
            .save => "Save to the folder",
        };
    }

    /// The next choice, for the Settings button that cycles them.
    pub fn next(self: After) After {
        const n = @typeInfo(After).@"enum".field_names.len;
        return @fromBackingInt(@intCast((@as(usize, @backingInt(self)) + 1) % n));
    }
};

/// What a capture taken without the editor does: like an area copied or
/// saved in the editor, it always lands somewhere (the clipboard or a
/// file), and in the history; the thumbnail follows quick_access unless
/// it was asked for.
pub const Delivery = struct {
    save: bool = false,
    copy: bool = false,
    thumbnail: bool = false,
};

pub fn delivery(after: After, cfg: *const config.Config) Delivery {
    return switch (after) {
        .editor => .{},
        .thumbnail => .{ .copy = true, .thumbnail = true },
        .copy => .{ .copy = true, .thumbnail = cfg.quick_access },
        .save => .{ .save = true, .copy = cfg.copy_on_save, .thumbnail = cfg.quick_access },
    };
}

pub const Settings = struct {
    after: After = .thumbnail,
    timer_s: u8 = 5,
    window_shadow: bool = true,
    scroll_max_height: u32 = 20_000,
    scroll_auto: bool = true,

    fn apply(self: *Settings, key: []const u8, v: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, key, "after_fullscreen")) {
            self.after = std.meta.stringToEnum(After, v) orelse self.after;
        } else if (eql(u8, key, "timer_seconds")) {
            const s = std.fmt.parseInt(u8, v, 10) catch return;
            if (std.mem.indexOfScalar(u8, &mode.timer_choices, s) != null) self.timer_s = s;
        } else if (eql(u8, key, "window_shadow")) {
            self.window_shadow = !eql(u8, v, "false");
        } else if (eql(u8, key, "scroll_max_height")) {
            const h = std.fmt.parseInt(u32, v, 10) catch return;
            self.scroll_max_height = std.math.clamp(h, 1000, 60_000);
        } else if (eql(u8, key, "scroll_auto")) {
            self.scroll_auto = !eql(u8, v, "false");
        }
    }

    pub fn parse(data: []const u8) Settings {
        var s: Settings = .{};
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const kv = config.parseLine(line) orelse continue;
            s.apply(kv.key, kv.value);
        }
        return s;
    }
};

pub fn load(gpa: std.mem.Allocator, home: []const u8) Settings {
    var dbuf: [1024]u8 = undefined;
    const dir = env.configDir(&dbuf, home) catch return .{};
    var pbuf: [1100]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/config", .{dir}) catch return .{};
    const data = sys.readFileAlloc(gpa, path, 64 * 1024) catch return .{};
    defer gpa.free(data);
    return Settings.parse(data);
}

pub fn setAfter(gpa: std.mem.Allocator, home: []const u8, a: After) !void {
    try config.update(gpa, home, &.{.{ .key = "after_fullscreen", .value = @tagName(a) }});
}

pub fn setTimer(gpa: std.mem.Allocator, home: []const u8, s: u8) !void {
    var buf: [4]u8 = undefined;
    try config.update(gpa, home, &.{.{ .key = "timer_seconds", .value = try std.fmt.bufPrint(&buf, "{d}", .{s}) }});
}

test "a capture without the editor is always copied or saved" {
    var cfg: config.Config = .{};
    cfg.quick_access = false;
    try std.testing.expectEqual(Delivery{ .copy = true, .thumbnail = true }, delivery(.thumbnail, &cfg));
    try std.testing.expectEqual(Delivery{ .copy = true }, delivery(.copy, &cfg));
    try std.testing.expectEqual(Delivery{ .save = true }, delivery(.save, &cfg));
    cfg.quick_access = true;
    cfg.copy_on_save = true;
    try std.testing.expectEqual(Delivery{ .save = true, .copy = true, .thumbnail = true }, delivery(.save, &cfg));
    try std.testing.expectEqual(After.editor, After.save.next());
}

test "mode settings parse with defaults for the rest" {
    const s = Settings.parse("notify=true\nafter_fullscreen=copy\ntimer_seconds=10\nwindow_shadow=false\n# x\nscroll_max_height=5\n");
    try std.testing.expectEqual(After.copy, s.after);
    try std.testing.expectEqual(@as(u8, 10), s.timer_s);
    try std.testing.expect(!s.window_shadow);
    try std.testing.expectEqual(@as(u32, 1000), s.scroll_max_height);
    const bad = Settings.parse("after_fullscreen=nope\ntimer_seconds=7\n");
    try std.testing.expectEqual(After.thumbnail, bad.after);
    try std.testing.expectEqual(@as(u8, 5), bad.timer_s);
}
