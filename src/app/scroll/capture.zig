//! The scrolling capture: pick a region on the frozen capture, then
//! frames of it as the content scrolls (Shotlet turning the wheel where
//! it can, else the person scrolling), stitched (stitch.zig) while the
//! control (ui/scroll_hud.zig) shows the image growing (session.zig).
//! Stop, the end of the page or the maximum height ends it; a short stop
//! pauses with its reason and Continue (stop.zig); no frame at all says
//! so on the control. The tall image goes to the editor. Whether it can
//! run at all is decided before (available.zig).

const std = @import("std");
const capture = @import("../capture.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/api.zig").sys;
const shell_seam = @import("../../platform/api.zig").shell;
const geom = @import("../modes/geom.zig");
const flow = @import("../modes/flow.zig");
const settings = @import("../modes/settings.zig");
const region_pick = @import("../../ui/region_pick.zig");
const hud_mod = @import("../../ui/scroll_hud.zig");
const theme = @import("../../ui/theme.zig");
const Session = @import("session.zig").Session;

/// Null when cancelled.
pub fn run(c: flow.Ctx, cap: *const capture.Capture, s: settings.Settings) !?png.Image {
    std.log.info("scrolling capture: pick a region", .{});
    const region = switch (try region_pick.pick(c.gpa, c.win, cap, .{ .region = .{ .label = "Start scrolling capture" } })) {
        .region => |r| r,
        else => return null,
    };
    std.log.info("scrolling capture: region {d}x{d} at {d},{d}", .{ region.w, region.h, region.x, region.y });
    const shell = shell_seam.applies() and shell_seam.active(c.conn);
    var hud = try hud_mod.Hud.open(c.win, theme.of(theme.readPrefs(c.conn, 800)));
    defer c.win.closeWindow();
    try showHud(c, &hud, cap, region, shell);
    var session = Session.init(c, &hud, .{ .cap = cap, .region = region, .shell = shell, .auto = s.scroll_auto }, s.scroll_max_height) catch |err| return failed(&hud, err);
    defer session.deinit();
    return session.collect() catch |err| failed(&hud, err);
}

/// No frame of the region came (the source would not start, or gave
/// nothing): the control says so until it is closed, instead of
/// vanishing. Null: nothing to edit.
fn failed(hud: *hud_mod.Hud, err: anyerror) !?png.Image {
    std.log.warn("scrolling capture failed ({t}): no frame of the region", .{err});
    hud.show(.failed, "Couldn\u{2019}t capture the region", "Close and try again", 0);
    while (true) {
        try hud.draw(null);
        if (try hud.poll(100)) |_| return null;
    }
}

/// Map the control, beside the region on GNOME, and let the overlay go.
fn showHud(c: flow.Ctx, hud: *hud_mod.Hud, cap: *const capture.Capture, region: geom.Rect, shell: bool) !void {
    const deadline = sys.monoMs() + 1500;
    var placed = !shell;
    while (sys.monoMs() < deadline) {
        try hud.draw(null);
        _ = try hud.poll(50);
        if (!placed) if (besideRegion(cap, region)) |p| {
            placed = shell_seam.place(c.gpa, c.conn, hud_mod.title, p[0], p[1]);
        };
        if (placed and sys.monoMs() + 1000 > deadline) break;
    }
}

/// Where the control goes (logical): right of the region, else left,
/// else the monitor's top-right corner.
fn besideRegion(cap: *const capture.Capture, region: geom.Rect) ?[2]i32 {
    const l = (geom.imageToLogical(cap.monitors, region) orelse return null).rect;
    const m = cap.monitors[geom.monitorAt(cap.monitors, .{ l.x + @divTrunc(l.w, 2), l.y + @divTrunc(l.h, 2) })].logical orelse return null;
    const gap = 16;
    const w = hud_mod.width;
    const h = hud_mod.height;
    const right = m.x + @as(i32, @intCast(m.w));
    const y = std.math.clamp(l.y, m.y + gap, m.y + @as(i32, @intCast(m.h)) - h - gap);
    if (l.x + l.w + gap + w <= right) return .{ l.x + l.w + gap, y };
    if (l.x - gap - w >= m.x) return .{ l.x - gap - w, y };
    return .{ right - w - gap, m.y + gap };
}
