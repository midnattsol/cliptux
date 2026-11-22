//! Capture modes: what a capture covers and how it starts.
//!
//!     shotlet [area]        select a region in the editor (the default)
//!     shotlet fullscreen    the monitor under the pointer
//!     shotlet screens       every monitor
//!     shotlet previous      the last selection again (per monitor layout)
//!     shotlet window        click a window: just that window
//!     shotlet scroll        a region scrolled and stitched into one image
//!     shotlet timer [S]     area after a 3, 5 or 10 s countdown
//!
//! Every mode takes `--delay S` (the self-timer). On GNOME with the
//! Shotlet extension each mode has its own shortcut there; elsewhere bind
//! the commands in the desktop's keyboard settings.

const std = @import("std");

pub const Mode = enum {
    area,
    fullscreen,
    screens,
    previous,
    window,
    scroll,

    pub fn parse(name: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, name);
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .area => "Capture area",
            .fullscreen => "Capture screen",
            .screens => "Capture all screens",
            .previous => "Capture previous area",
            .window => "Capture window",
            .scroll => "Scrolling capture",
        };
    }

    /// Captured and finished without the editor's region selection.
    pub fn instant(self: Mode) bool {
        return self == .fullscreen or self == .screens or self == .window;
    }
};

/// A shortcut of the GNOME extension: a mode, the self-timer, or the
/// last thumbnail again.
pub const Shortcut = struct {
    /// its key in the extension's settings
    key: []const u8,
    /// the word `shotlet gnome-integration shortcut WORD KEY` takes
    name: []const u8,
    label: []const u8,
    /// none of GNOME's own shortcuts uses these (Alt+Print is SysRq)
    default: []const u8,
};

pub const shortcuts = [_]Shortcut{
    .{ .key = "capture-shortcut", .name = "area", .label = "Capture area", .default = "Print" },
    .{ .key = "fullscreen-shortcut", .name = "fullscreen", .label = "Capture screen", .default = "<Ctrl>Print" },
    .{ .key = "screens-shortcut", .name = "screens", .label = "Capture all screens", .default = "<Ctrl><Shift>Print" },
    .{ .key = "previous-shortcut", .name = "previous", .label = "Capture previous area", .default = "<Shift><Super>Print" },
    .{ .key = "window-shortcut", .name = "window", .label = "Capture window", .default = "<Super>Print" },
    .{ .key = "scroll-shortcut", .name = "scroll", .label = "Scrolling capture", .default = "<Ctrl><Super>Print" },
    .{ .key = "timer-shortcut", .name = "timer", .label = "Self-timer", .default = "<Ctrl><Shift><Super>Print" },
    .{ .key = "thumbnail-shortcut", .name = "thumbnail", .label = "Last thumbnail again", .default = "<Shift><Super>t" },
};

pub fn shortcutNamed(name: []const u8) ?Shortcut {
    for (shortcuts) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// The timer's choices, in seconds.
pub const timer_choices = [_]u8{ 3, 5, 10 };

pub fn validDelay(s: u32) bool {
    return s <= 60;
}

/// One capture to make.
pub const Request = struct {
    mode: Mode = .area,
    /// seconds of countdown before capturing
    delay_s: u8 = 0,
    /// the pointer, in the compositor's logical layout, when known (the
    /// GNOME extension says where it was)
    pointer: ?[2]i32 = null,

    /// `--mode NAME` as the extension passes it.
    pub fn withModeArg(self: *Request, name: []const u8) void {
        self.mode = Mode.parse(name) orelse .area;
    }

    /// "X,Y"
    pub fn withPointerArg(self: *Request, s: []const u8) void {
        var it = std.mem.splitScalar(u8, s, ',');
        const x = std.fmt.parseInt(i32, it.next() orelse return, 10) catch return;
        const y = std.fmt.parseInt(i32, it.next() orelse return, 10) catch return;
        self.pointer = .{ x, y };
    }
};

/// `shotlet MODE [--delay S]`, `shotlet timer [S]`: the request, or null
/// for a command that is no capture mode.
pub fn parseCommand(cmd: []const u8, rest: []const []const u8, default_timer: u8) ?Request {
    var req: Request = .{};
    if (std.mem.eql(u8, cmd, "timer")) {
        req.delay_s = default_timer;
        if (rest.len > 0) if (std.fmt.parseInt(u8, rest[0], 10)) |s| {
            if (validDelay(s)) req.delay_s = s;
        } else |_| {};
    } else req.mode = Mode.parse(cmd) orelse return null;
    var i: usize = 0;
    while (i + 1 < rest.len) : (i += 1) {
        if (!std.mem.eql(u8, rest[i], "--delay")) continue;
        const s = std.fmt.parseInt(u8, rest[i + 1], 10) catch continue;
        if (validDelay(s)) req.delay_s = s;
    }
    return req;
}

test "commands name modes" {
    try std.testing.expectEqual(Mode.window, parseCommand("window", &.{}, 5).?.mode);
    try std.testing.expectEqual(@as(?Request, null), parseCommand("settings", &.{}, 5));
    const t = parseCommand("timer", &.{}, 5).?;
    try std.testing.expectEqual(Mode.area, t.mode);
    try std.testing.expectEqual(@as(u8, 5), t.delay_s);
    try std.testing.expectEqual(@as(u8, 10), parseCommand("timer", &.{"10"}, 5).?.delay_s);
    const d = parseCommand("fullscreen", &.{ "--delay", "3" }, 5).?;
    try std.testing.expectEqual(Mode.fullscreen, d.mode);
    try std.testing.expectEqual(@as(u8, 3), d.delay_s);
    try std.testing.expectEqual(@as(u8, 0), parseCommand("screens", &.{ "--delay", "999" }, 5).?.delay_s);
    var r: Request = .{};
    r.withPointerArg("-20,300");
    try std.testing.expectEqual([2]i32{ -20, 300 }, r.pointer.?);
    r.withModeArg("bogus");
    try std.testing.expectEqual(Mode.area, r.mode);
}

test "every mode but area has its own shortcut key" {
    for (shortcuts) |s| try std.testing.expect(std.mem.endsWith(u8, s.key, "-shortcut"));
    try std.testing.expect(shortcutNamed("scroll") != null);
    try std.testing.expect(shortcutNamed("nope") == null);
}
