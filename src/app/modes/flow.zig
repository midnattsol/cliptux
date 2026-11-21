//! What happens to a capture after it is taken, by mode (app/shot.zig
//! calls afterCapture between taking the capture and opening the editor):
//!
//! - area: the editor, as always;
//! - previous: the editor with the last selection of this monitor layout;
//! - fullscreen (the monitor under the pointer), screens (all of them) and
//!   window: what `after_fullscreen` says: the editor with it selected,
//!   the floating thumbnail, or the clipboard (and the thumbnail when
//!   quick access is on), with no editor;
//! - scroll: a region is picked, scrolled and stitched, and the tall
//!   result opens in the editor.

const std = @import("std");
const capture = @import("../capture.zig");
const config = @import("../config.zig");
const dbus = @import("../../platform/dbus.zig");
const env_mod = @import("../env.zig");
const keep_mod = @import("../keep.zig");
const png = @import("../../gfx/png.zig");
const doc_mod = @import("../../ui/doc.zig");
const window = @import("../../ui/window.zig");
const geom = @import("geom.zig");
const last_area = @import("last_area.zig");
const mode = @import("mode.zig");
const settings = @import("settings.zig");
const clip = @import("clip.zig");
const window_frame = @import("window_frame.zig");
const scroll = @import("../scroll/capture.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    env: env_mod.Env,
    conn: *dbus.Connection,
    cfg: *config.Config,
    win: *window.Window,
};

/// How the editor should open.
pub const Edit = struct {
    /// selected first, in image pixels
    sel: ?geom.Rect = null,
    /// the image has see-through pixels (a window): export them
    keep_alpha: bool = false,
};

pub const Outcome = union(enum) {
    /// finished (or cancelled): no editor
    done,
    edit: Edit,
};

pub fn afterCapture(c: Ctx, cap: *capture.Capture, req: mode.Request) !Outcome {
    return switch (req.mode) {
        .area => .{ .edit = .{} },
        .previous => .{ .edit = .{ .sel = previous(c, cap) } },
        .fullscreen => instant(c, cap, geom.pixelRect(cap.monitors[geom.monitorAt(cap.monitors, req.pointer)]), false),
        .screens => instant(c, cap, fullRect(cap), false),
        .window => try windowShot(c, cap),
        .scroll => try scrolling(c, cap),
    };
}

fn fullRect(cap: *const capture.Capture) geom.Rect {
    return .{ .x = 0, .y = 0, .w = @intCast(cap.image.width), .h = @intCast(cap.image.height) };
}

fn previous(c: Ctx, cap: *const capture.Capture) ?geom.Rect {
    const key = last_area.layoutKey(cap.monitors, cap.image.width, cap.image.height);
    const r = last_area.load(c.gpa, c.env.home, key);
    if (r == null) std.log.info("previous area: none yet for this monitor layout", .{});
    return r;
}

/// A window from the GNOME extension (or KWin): the whole image, framed.
fn windowShot(c: Ctx, cap: *capture.Capture) !Outcome {
    const s = settings.load(c.gpa, c.env.home);
    const scale: f64 = if (cap.monitors[0].logical) |l| @as(f64, @floatFromInt(cap.image.width)) / @as(f64, @floatFromInt(@max(1, l.w))) else 1;
    std.log.info("window capture: {d}x{d}", .{ cap.image.width, cap.image.height });
    cap.image = try window_frame.frame(c.gpa, cap.image, scale, s.window_shadow, beautify(c.cfg));
    cap.monitors[0] = .{ .x = 0, .y = 0, .w = cap.image.width, .h = cap.image.height };
    return instant(c, cap, fullRect(cap), true);
}

fn beautify(cfg: *const config.Config) doc_mod.Beautify {
    return .{ .enabled = cfg.beautify, .bg = cfg.beautify_background, .padding = cfg.beautify_padding, .rounded = cfg.beautify_corners, .shadow = cfg.beautify_shadow };
}

/// Screens and windows: no region to pick, so straight to what the
/// settings say.
fn instant(c: Ctx, cap: *capture.Capture, r: geom.Rect, alpha: bool) !Outcome {
    const s = settings.load(c.gpa, c.env.home);
    std.log.info("capture mode: {d}x{d} at {d},{d}, then {t}", .{ r.w, r.h, r.x, r.y, s.after });
    if (s.after == .editor) return .{ .edit = .{ .sel = r, .keep_alpha = alpha } };
    // a window is already framed; screens get the beautify frame here
    const b: doc_mod.Beautify = if (alpha) .{} else beautify(c.cfg);
    const exported = try doc_mod.exportImage(c.gpa, cap.image.pixels, cap.image.width, cap.image.height, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h }, b);
    defer c.gpa.free(exported.pixels);
    const see_through = alpha or (b.enabled and b.background().transparent());
    const data = try png.encodeWith(c.gpa, exported.pixels, exported.width, exported.height, .{ .alpha = if (see_through) .auto else .never });
    errdefer c.gpa.free(data);
    try deliver(c, cap, r, data, s.after);
    return .done;
}

/// Keep `data` (owned) for the thumbnail and the history; copy it when
/// asked to, then serve the clipboard.
fn deliver(c: Ctx, cap: *capture.Capture, r: geom.Rect, data: []u8, after: settings.After) !void {
    var doc = doc_mod.Document.init(c.gpa, cap.image.width, cap.image.height);
    defer doc.deinit();
    doc.sel = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    const kept = keep_mod.keep(c.gpa, c.env, c.cfg, .{ .image_png = data, .source = &cap.image, .doc = &doc });
    if (after == .thumbnail or c.cfg.quick_access) if (kept) |k| keep_mod.spawnQuick(c.gpa, c.env, &k);
    if (after != .copy) {
        c.gpa.free(data);
        return;
    }
    clip.copyPng(c.win, data) catch |err| {
        c.gpa.free(data);
        std.log.warn("could not copy the capture: {t}", .{err});
        return;
    };
    std.log.info("capture copied to the clipboard", .{});
    try c.win.serveClipboard();
}

/// Pick a region, scroll it and stitch; the tall image replaces the
/// capture and opens in the editor.
fn scrolling(c: Ctx, cap: *capture.Capture) !Outcome {
    const s = settings.load(c.gpa, c.env.home);
    var tall = (scroll.run(c, cap, s) catch |err| {
        std.log.warn("scrolling capture failed ({t}): it needs the GNOME integration or a compositor Shotlet can capture directly", .{err});
        return .done;
    }) orelse return .done;
    errdefer tall.deinit(c.gpa);
    const single = try capture.Capture.single(c.gpa, tall);
    cap.deinit(c.gpa);
    cap.* = single;
    return .{ .edit = .{} };
}
