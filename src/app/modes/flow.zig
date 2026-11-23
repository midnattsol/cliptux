//! What happens to a capture after it is taken, by mode (app/shot.zig
//! calls afterCapture between taking the capture and opening the editor):
//!
//! - area: the editor, as always;
//! - previous: the editor with the last selection of this monitor layout;
//! - fullscreen (the monitor under the pointer), screens (all of them) and
//!   window: what `after_fullscreen` says: the editor with it selected,
//!   or with no editor copied (with the floating thumbnail), copied or
//!   saved (with the thumbnail when quick access is on): never only
//!   kept in the history (settings.delivery);
//! - scroll: a region is picked, scrolled and stitched, and the tall
//!   result opens in the editor.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const capture = @import("../capture.zig");
const config = @import("../config.zig");
const env_mod = @import("../env.zig");
const keep_mod = @import("../keep.zig");
const save = @import("../shot/save.zig");
const png = @import("../../gfx/png.zig");
const doc_mod = @import("../../ui/doc.zig");
const window = @import("../../platform/api.zig").window;
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
    conn: *desktop.Session,
    cfg: *config.Config,
    win: *window.Window,
};

/// How the editor should open.
pub const Edit = struct {
    /// selected first, in image pixels
    sel: ?geom.Rect = null,
    /// the image has see-through pixels (a window): export them
    keep_alpha: bool = false,
    /// an area to pick: the mode strip shows before a selection
    modes: bool = false,
    /// where the windows were at capture (image pixels, topmost first;
    /// the caller's), to click one
    windows: []const @import("../../ui/shapes.zig").Rect = &.{},
    /// taken by the GNOME extension (a recording picked from the editor
    /// gets its overlays)
    from_shell: bool = false,
    /// `shotlet window` can pick a window here
    window_ok: bool = true,
};

pub const Outcome = union(enum) {
    /// finished (or cancelled): no editor
    done,
    edit: Edit,
};

pub fn afterCapture(c: Ctx, cap: *capture.Capture, req: mode.Request) !Outcome {
    return switch (req.mode) {
        .area => .{ .edit = .{ .modes = true } },
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
    return .{ .enabled = cfg.beautify_always, .bg = cfg.beautify_background, .padding = cfg.beautify_padding, .rounded = cfg.beautify_corners, .shadow = cfg.beautify_shadow };
}

/// The editor's Screen (its mode strip) when screen captures skip the
/// editor: rectangle `r` of the capture delivered as after_fullscreen
/// says.
pub fn deliverScreen(c: Ctx, cap: *capture.Capture, r: geom.Rect) !void {
    _ = try instant(c, cap, r, false);
}

/// A screen capture opens the editor (Screen then selects in place).
pub fn screenOpensEditor(c: Ctx) bool {
    return settings.load(c.gpa, c.env.home).after == .editor;
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
    try deliver(c, cap, r, data, settings.delivery(s.after, c.cfg));
    return .done;
}

/// Save `data` (owned) when asked to, keep it for the thumbnail and the
/// history, then copy it and serve the clipboard when asked to.
fn deliver(c: Ctx, cap: *capture.Capture, r: geom.Rect, data: []u8, d: settings.Delivery) !void {
    const path: ?[]u8 = if (d.save) saveFile(c, data) else null;
    defer if (path) |p| c.gpa.free(p);
    var doc = doc_mod.Document.init(c.gpa, cap.image.width, cap.image.height);
    defer doc.deinit();
    doc.sel = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    const kept = keep_mod.keep(c.gpa, c.env, c.cfg, .{ .image_png = data, .source = &cap.image, .doc = &doc, .saved = path orelse "" });
    if (d.thumbnail) if (kept) |k| keep_mod.spawnQuick(c.gpa, c.env, &k, null);
    // a save that failed still copies: the capture lands somewhere
    if (!d.copy and path != null) {
        c.gpa.free(data);
        return;
    }
    try copy(c, data);
}

/// Into the screenshots folder; null (logged) when it could not be written.
fn saveFile(c: Ctx, data: []const u8) ?[]u8 {
    const path = save.savePng(c.gpa, c.env, c.cfg, data) catch |err| {
        std.log.warn("could not save the capture ({t}); copying it instead", .{err});
        return null;
    };
    std.log.info("capture saved to {s}", .{path});
    return path;
}

/// Put `data` (owned) on the clipboard and serve it.
fn copy(c: Ctx, data: []u8) !void {
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
        std.log.warn("scrolling capture failed ({t})", .{err});
        return .done;
    }) orelse return .done;
    errdefer tall.deinit(c.gpa);
    const single = try capture.Capture.single(c.gpa, tall);
    cap.deinit(c.gpa);
    cap.* = single;
    return .{ .edit = .{} };
}
