//! Where a scrolling capture's frames come from, and who scrolls:
//!
//! - GNOME: the Shotlet extension's scroll session (modes/shell_bus.zig):
//!   it grabs the region, and turns the wheel there itself when asked to;
//! - wlroots and KWin: direct capture of the outputs (app/direct.zig),
//!   cropped to the region; the wheel through inject_wl.zig when the
//!   compositor offers a way, else the person scrolls.

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const direct = @import("direct.zig");
const dbus = @import("../dbus.zig");
const env_mod = @import("../../../app/env.zig");
const png = @import("../../../gfx/png.zig");
const shellcap = @import("../gnome/shellcap.zig");
const geom = @import("../../../app/modes/geom.zig");
const shell_bus = @import("../gnome/shell_bus.zig");
const inject = @import("../wlroots/inject.zig");

pub const Source = union(enum) {
    shell: struct { session: shell_bus.Scroll, auto: bool },
    direct: struct { region: geom.Rect, logical: geom.Rect, wheel: ?inject.Wheel },

    /// Whether frames come after a scroll Shotlet makes (else the person
    /// scrolls).
    pub fn scrolls(self: *const Source) bool {
        return switch (self.*) {
            .shell => |s| s.auto,
            .direct => |d| d.wheel != null,
        };
    }

    pub fn deinit(self: *Source) void {
        switch (self.*) {
            .shell => |*s| s.session.end(),
            .direct => |*d| if (d.wheel) |*w| w.deinit(),
        }
    }

    /// Scroll `clicks` notches (0: none), then the region's frame.
    pub fn grab(self: *Source, gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, clicks: i32) !png.Image {
        return switch (self.*) {
            .shell => |*s| shellFrame(gpa, env, &s.session, clicks),
            .direct => |*d| directFrame(gpa, env, bus, d.region, d.logical, if (d.wheel) |*w| w else null, clicks),
        };
    }
};

fn shellFrame(gpa: std.mem.Allocator, env: env_mod.Env, session: *shell_bus.Scroll, clicks: i32) !png.Image {
    var idbuf: [64]u8 = undefined;
    const id = try session.step(clicks, &idbuf);
    var pbuf: [1200]u8 = undefined;
    const data = try shellcap.readAndRemove(gpa, try shellcap.piecePath(&pbuf, env.runtime_dir, id, 0));
    defer gpa.free(data);
    return png.decode(gpa, data);
}

fn directFrame(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, region: geom.Rect, logical: geom.Rect, wheel: ?*inject.Wheel, clicks: i32) !png.Image {
    if (wheel) |w| if (clicks > 0) {
        try w.scroll(logical.x + @divTrunc(logical.w, 2), logical.y + @divTrunc(logical.h, 2), clicks);
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 160 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
    };
    var cap = switch (try direct.captureAll(gpa, env.runtime_dir, env.wayland_display, bus)) {
        .captured => |c| c.cap,
        .unavailable => return error.NoDirectCapture,
    };
    defer cap.deinit(gpa);
    return crop(gpa, &cap.image, region);
}

pub fn crop(gpa: std.mem.Allocator, img: *const png.Image, r: geom.Rect) !png.Image {
    const c = geom.Rect.intersect(r, .{ .x = 0, .y = 0, .w = @intCast(img.width), .h = @intCast(img.height) }) orelse return error.RegionOffScreen;
    const w: u32 = @intCast(c.w);
    const h: u32 = @intCast(c.h);
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| @memcpy(px[y * w ..][0..w], img.pixels[(@as(usize, @intCast(c.y)) + y) * img.width + @as(usize, @intCast(c.x)) ..][0..w]);
    return .{ .width = w, .height = h, .pixels = px };
}

/// The layout's bounding box, logical.
fn layoutBox(mons: []const capture.Monitor) geom.Rect {
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    for (mons) |m| if (m.logical) |l| {
        x0 = @min(x0, l.x);
        y0 = @min(y0, l.y);
        x1 = @max(x1, l.x + @as(i32, @intCast(l.w)));
        y1 = @max(y1, l.y + @as(i32, @intCast(l.h)));
    };
    if (x1 <= x0) return .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Start a session for the region (image pixels of `cap`).
pub fn open(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, cap: *const capture.Capture, region: geom.Rect, shell: bool, auto: bool) !Source {
    const l = geom.imageToLogical(cap.monitors, region) orelse return error.RegionOffScreen;
    if (shell) return .{ .shell = .{ .session = try shell_bus.Scroll.begin(gpa, bus, l.rect, auto), .auto = auto } };
    const wheel = if (auto) inject.Wheel.open(gpa, env.runtime_dir, env.wayland_display, layoutBox(cap.monitors)) catch null else null;
    return .{ .direct = .{ .region = region, .logical = l.rect, .wheel = wheel } };
}
