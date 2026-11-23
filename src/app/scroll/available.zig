//! Whether a scrolling capture can run, decided before anything is
//! captured or a region picked (`shotlet scroll`, which the mode strip's
//! J and the tray start too). When it cannot, the person is told why in
//! plain words: a notice on the screen and a line on stderr, and the
//! command exits with status 1 instead of opening a picker whose capture
//! could never start.

const std = @import("std");
const platform = @import("../../platform/api.zig");
const desktop = platform.desktop;
const shell = platform.shell;
const sys = platform.sys;
const keep = @import("../keep.zig");
const Env = @import("../env.zig").Env;

pub const Support = platform.capture.ScrollSupport;

/// What to tell the person: a title and a line under it.
pub const Notice = struct {
    title_buf: [96]u8 = undefined,
    title_len: usize = 0,
    body_buf: [128]u8 = undefined,
    body_len: usize = 0,

    pub fn title(self: *const Notice) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn body(self: *const Notice) []const u8 {
        return self.body_buf[0..self.body_len];
    }

    fn setTitle(self: *Notice, comptime fmt: []const u8, args: anytype) void {
        self.title_len = put(&self.title_buf, fmt, args);
    }

    fn setBody(self: *Notice, comptime fmt: []const u8, args: anytype) void {
        self.body_len = put(&self.body_buf, fmt, args);
    }
};

/// `fmt` into `buf`, cut short when it does not fit; its length.
fn put(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return w.buffered().len;
}

/// Why a scrolling capture cannot run, in the backend's words for its
/// integration (shell.words()); null when it can.
pub fn notice(why: Support, w: shell.Words) ?Notice {
    var n: Notice = .{};
    const cmd = w.command;
    switch (why) {
        .available => return null,
        .unsupported => {
            n.setTitle("Scrolling capture isn\u{2019}t available here", .{});
            n.setBody("This desktop doesn\u{2019}t let Shotlet capture while you scroll", .{});
        },
        .shell_needs_login => {
            needsIntegration(&n, w);
            n.setBody("It loads at your next login: log out and back in", .{});
        },
        .shell_missing => {
            needsIntegration(&n, w);
            if (cmd.len > 0) n.setBody("Install it with {s} install", .{cmd}) else n.setBody("Install it first", .{});
        },
        .shell_off => {
            needsIntegration(&n, w);
            if (cmd.len > 0) n.setBody("It isn\u{2019}t running: see {s} status", .{cmd}) else n.setBody("It isn\u{2019}t running", .{});
        },
    }
    return n;
}

/// "Scrolling capture needs the GNOME integration" ("the desktop
/// integration": a capital kept only for a name in capitals).
fn needsIntegration(n: *Notice, w: shell.Words) void {
    var buf: [64]u8 = undefined;
    const len = put(&buf, "{s}", .{w.title});
    if (len > 1 and std.ascii.isLower(buf[1])) buf[0] = std.ascii.toLower(buf[0]);
    n.setTitle("Scrolling capture needs the {s}", .{buf[0..len]});
}

/// True when a scrolling capture can run; else the person was told why.
pub fn ensure(gpa: std.mem.Allocator, env: Env) bool {
    var conn = desktop.connectBrief(gpa, env) catch |err| {
        std.log.info("scrolling capture: no desktop session ({t}); trying anyway", .{err});
        return true;
    };
    defer conn.deinit();
    const n = notice(platform.capture.scrollSupport(gpa, env, &conn), shell.words()) orelse return true;
    tell(env, &n);
    return false;
}

/// stderr, the log and a notice on the screen (`shotlet toast --info`).
fn tell(env: Env, n: *const Notice) void {
    std.log.warn("scrolling capture: {s}. {s}", .{ n.title(), n.body() });
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "shotlet scroll: {s}. {s}.\n", .{ n.title(), n.body() }) catch "shotlet scroll: not available here\n";
    sys.writeAll(2, line) catch {};
    var tz: [96:0]u8 = undefined;
    var bz: [128:0]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&tz, "{s}", .{n.title()}, 0) catch return;
    const b = std.fmt.bufPrintSentinel(&bz, "{s}", .{n.body()}, 0) catch return;
    keep.spawnSelf(env, &.{ "toast", "--info", t.ptr, b.ptr });
}

const gnome_words: shell.Words = .{ .title = "GNOME integration", .command = "shotlet gnome-integration" };

test "available: nothing to say" {
    try std.testing.expect(notice(.available, gnome_words) == null);
}

test "GNOME: what the integration needs, by its state" {
    const login = notice(.shell_needs_login, gnome_words).?;
    try std.testing.expectEqualStrings("Scrolling capture needs the GNOME integration", login.title());
    try std.testing.expectEqualStrings("It loads at your next login: log out and back in", login.body());
    const missing = notice(.shell_missing, gnome_words).?;
    try std.testing.expectEqualStrings("Scrolling capture needs the GNOME integration", missing.title());
    try std.testing.expectEqualStrings("Install it with shotlet gnome-integration install", missing.body());
    try std.testing.expectEqualStrings("It isn\u{2019}t running: see shotlet gnome-integration status", notice(.shell_off, gnome_words).?.body());
}

test "elsewhere: the desktop cannot, and a nameless integration" {
    const n = notice(.unsupported, .{}).?;
    try std.testing.expectEqualStrings("Scrolling capture isn\u{2019}t available here", n.title());
    try std.testing.expectEqualStrings("This desktop doesn\u{2019}t let Shotlet capture while you scroll", n.body());
    const d = notice(.shell_missing, .{}).?;
    try std.testing.expectEqualStrings("Scrolling capture needs the desktop integration", d.title());
    try std.testing.expectEqualStrings("Install it first", d.body());
}
