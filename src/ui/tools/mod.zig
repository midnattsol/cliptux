//! The editor's extra tools, behind a few hooks the editor calls: the
//! ruler and spotlight annotations, the colour picker (eyedropper), crop,
//! copy text (OCR), redact sensitive data, opening dropped images and
//! pinning. Each lives in its own file here; this one holds their state
//! and routes the editor's events to them.

const std = @import("std");
const config = @import("../../app/config.zig");
const window = @import("../../platform/api.zig").window;
const shapes = @import("../shapes.zig");
const doc_mod = @import("../doc.zig");
const editor_mod = @import("../editor.zig");
const ruler = @import("ruler.zig");
const spotlight = @import("spotlight.zig");
const edges = @import("edges.zig");
const ui = @import("../editor_ui.zig");
const render = @import("../../gfx/render.zig");
const color = @import("color.zig");
const toast_mod = @import("toast.zig");
const eyedrop = @import("eyedrop.zig");
const tui = @import("tui.zig");
const crop = @import("crop.zig");
const crop_mode = @import("crop_mode.zig");
const open = @import("open.zig");
const launch = @import("launch.zig");
const ocr_job = @import("ocr_job.zig");

const Editor = editor_mod.Editor;
const Shape = shapes.Shape;
const Point = shapes.Point;
const Rect = shapes.Rect;
const Tool = shapes.Tool;

/// Modes that take the pointer instead of the current tool.
pub const Mode = enum { none, eyedropper, crop };

/// Crop aspect ratios.
pub const Aspect = enum { free, square, wide, classic };

/// The tools' controls on the toolbar, popover and menu
/// (editor_ui.ButtonKind.ext).
pub const Ext = union(enum) {
    eyedropper,
    crop,
    copy_text,
    redact_sensitive,
    pin,
    crop_apply,
    crop_cancel,
    aspect: Aspect,
    /// a colour from the picker's history
    picked: u8,
};

pub const State = struct {
    mode: Mode = .none,
    aspect: Aspect = .free,
    /// rulers are in the export (else only on screen)
    export_measures: bool = true,
    /// dimming of new spotlights, percent
    spot_dim: u8 = spotlight.default_dim,
    /// colours picked with the eyedropper, newest first
    history: color.History = .{},
    toast: toast_mod.Toast = .{},
    /// `shotlet text`: select a region, its text goes to the clipboard
    text_capture: bool = false,
    /// pictures before and after each crop, and opened ones
    crops: crop.Store = .{},
    /// text recognition running in the background
    ocr: ocr_job.Job = .{},
};

/// Once, when the editor first shows: how it was started.
pub fn start(ed: *Editor) void {
    ed.tools.text_capture = launch.text_capture;
    if (ed.tools.text_capture) std.log.info("text capture: the selected area's text goes to the clipboard", .{});
    if (launch.select_all) ed.doc.sel = ed.doc.imageRect();
    // images dropped on the editor open in it
    ed.win.accept_mimes = &open.drop_mimes;
}

pub fn deinit(ed: *Editor) void {
    ocr_job.deinit(ed);
    ed.tools.crops.deinit(ed.alloc);
}

// --- events ---

/// A press on the picture (not on the chrome). True when a tool took it.
pub fn onPress(ed: *Editor) !bool {
    return crop_mode.onPress(ed) or try eyedrop.onPress(ed);
}

/// The selection was dragged (crop keeps its aspect ratio).
pub fn afterSelDrag(ed: *Editor) void {
    crop_mode.constrain(ed);
}

/// Keys a mode takes before the editor (Enter applies a crop).
pub fn onKey(ed: *Editor, k: window.Key) !bool {
    // capturing text: Enter reads the selection instead of copying it
    if (ed.tools.text_capture and k.code.isEnter() and ed.doc.sel != null) {
        try ocr_job.start(ed, .copy_text);
        return true;
    }
    if (ed.tools.mode == .crop and k.code.isEnter() and ed.focus == null) {
        try crop_mode.apply(ed);
        return true;
    }
    return false;
}

/// A region was just selected (`shotlet text` reads it at once).
pub fn onSelected(ed: *Editor) void {
    if (!ed.tools.text_capture or ed.doc.sel == null) return;
    ocr_job.start(ed, .copy_text) catch |err| std.log.warn("copy text: {t}", .{err});
}

/// After undo (`undone`) or redo: what the step crossed besides shapes.
pub fn afterHistory(ed: *Editor, undone: bool) !void {
    try crop_mode.afterHistory(ed, undone);
}

/// The pointer moved with nothing dragged.
pub fn onHover(ed: *Editor) void {
    if (ed.tools.mode != .none) ed.needs_render = true;
}

/// Esc or a right click: leave a mode. True when there was one.
pub fn cancel(ed: *Editor) bool {
    if (ed.tools.mode == .none) return false;
    ed.tools.mode = .none;
    ed.needs_render = true;
    return true;
}

/// Timers and background work, once per loop; the longest the loop may
/// wait for the next event (ms).
pub fn tick(ed: *Editor, now: i64) i32 {
    open.poll(ed);
    ocr_job.poll(ed) catch |err| std.log.warn("text recognition: {t}", .{err});
    var wait: i64 = if (ocr_job.busy(ed)) 40 else 1000;
    if (ed.tools.toast.tick(now)) |left| {
        if (left == 0) ed.needs_render = true;
        wait = @min(wait, @max(1, left));
    }
    return @intCast(wait);
}

// --- chrome ---

pub fn collectOverlays(ed: *Editor, list: anytype) void {
    if (eyedrop.loupeRect(ed)) |r| list.add(r.expand(ed.sc(4)));
    if (crop_mode.overlay(ed)) |r| list.add(r);
    if (toast_mod.footprint(ed)) |r| list.add(r);
}

pub fn drawChrome(ed: *Editor, canvas: *render.Canvas) void {
    crop_mode.draw(ed, canvas);
    eyedrop.drawLoupe(ed, canvas);
}

/// Over everything but the help: the toast.
pub fn drawTop(ed: *Editor, canvas: *render.Canvas) void {
    toast_mod.draw(ed, canvas);
}

/// The cursor a mode wants.
pub fn cursor(ed: *const Editor) ?window.Cursor {
    return switch (ed.tools.mode) {
        .none => null,
        .eyedropper, .crop => .crosshair,
    };
}

// --- shapes: ruler and spotlight ---

/// Fill in what a new shape of the tool needs beyond colour and size.
pub fn initShape(ed: *const Editor, s: *Shape) void {
    switch (s.tool) {
        .spotlight => s.number = ed.tools.spot_dim,
        .ruler => s.number = logicalScale(ed, s.p0),
        else => {},
    }
}

/// Image pixels per logical pixel (thousandths) of the monitor at `p`;
/// 0 when unknown or 1.
fn logicalScale(ed: *const Editor, p: Point) u32 {
    for (ed.monitors) |m| {
        const l = m.logical orelse continue;
        const r = Rect{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) };
        if (!r.contains(p.x, p.y) or l.w == 0) continue;
        const k = @as(f64, @floatFromInt(m.w)) / @as(f64, @floatFromInt(l.w));
        return if (@abs(k - 1) < 0.01) 0 else @intFromFloat(@round(k * 1000));
    }
    return 0;
}

/// The ruler being drawn follows the pointer: Shift keeps it on an axis,
/// its end snaps to colour edges (Alt: no snapping). True when handled.
pub fn updateDrawing(ed: *Editor, s: *Shape, ip: Point) bool {
    if (s.tool != .ruler) return false;
    const a = ed.drag_anchor;
    var q = ruler.endPoint(a, ip, ed.mod_shift);
    if (!ed.mod_alt) {
        const lock: ?edges.Axis = if (!ed.mod_shift) null else if (q.y == a.y) .y else .x;
        const radius: i32 = @max(2, @as(i32, @intFromFloat(@round(ed.pn().view.lenToImg(@floatFromInt(ed.sc(8)))))));
        q = edges.snap(.{ .px = ed.img.pixels, .w = ed.img.width, .h = ed.img.height }, q, radius, lock);
    }
    s.p0 = a;
    s.p1 = q;
    ed.needs_render = true;
    return true;
}

/// Where a ruler starts: on the nearest edge too.
pub fn startPoint(ed: *const Editor, tool: Tool, ip: Point) Point {
    if (tool != .ruler or ed.mod_alt) return ip;
    const radius: i32 = @max(2, @as(i32, @intFromFloat(@round(ed.pn().view.lenToImg(@floatFromInt(ed.sc(8)))))));
    return edges.snap(.{ .px = ed.img.pixels, .w = ed.img.width, .h = ed.img.height }, ip, radius, null);
}

/// A committed shape: say what a ruler measured (logs, for scripts).
pub fn committed(s: *const Shape) void {
    if (s.tool != .ruler) return;
    var buf: [96]u8 = undefined;
    std.log.info("ruler: {s}", .{ruler.Measure.of(s).label(&buf)});
}

// --- popover segments ---

const Seg = ui.Seg;

/// The segment rows the popover shows for `tool`.
pub fn segRows(ed: *const Editor, tool: Tool, out: [][3]?Seg) usize {
    _ = ed;
    switch (tool) {
        .spotlight => {
            out[0] = .{ .spot_rect, .spot_ellipse, null };
            out[1] = .{ .dim_light, .dim_medium, .dim_strong };
            return 2;
        },
        .ruler => {
            out[0] = .{ .measure_show, .measure_hide, null };
            return 1;
        },
        else => return 0,
    }
}

pub fn segLabel(s: Seg) []const u8 {
    return switch (s) {
        .spot_rect => "Rectangle",
        .spot_ellipse => "Ellipse",
        .dim_light => "Light",
        .dim_medium => "Medium",
        .dim_strong => "Strong",
        .measure_show => "In export",
        .measure_hide => "Screen only",
        else => "",
    };
}

fn dimLevel(s: Seg) ?u8 {
    return switch (s) {
        .dim_light => spotlight.levels[0],
        .dim_medium => spotlight.levels[1],
        .dim_strong => spotlight.levels[2],
        else => null,
    };
}

/// The spotlight the popover edits: selected, else the next one drawn.
fn spotTarget(ed: *const Editor) ?*const Shape {
    const i = ed.selected orelse return null;
    const s = &ed.doc.shapes.items[i];
    return if (s.tool == .spotlight) s else null;
}

pub fn segOn(ed: *const Editor, s: Seg) bool {
    const ellipse = if (spotTarget(ed)) |t| t.filled else (ed.styles.get(.spotlight) & 1) != 0;
    const dim = if (spotTarget(ed)) |t| t.number else ed.tools.spot_dim;
    return switch (s) {
        .spot_rect => !ellipse,
        .spot_ellipse => ellipse,
        .measure_show => ed.tools.export_measures,
        .measure_hide => !ed.tools.export_measures,
        else => dim == dimLevel(s) orelse return false,
    };
}

pub fn applySeg(ed: *Editor, s: Seg) !void {
    switch (s) {
        .spot_rect, .spot_ellipse => {
            const ellipse = s == .spot_ellipse;
            ed.styles.set(.spotlight, @intFromBool(ellipse));
            try ed.editTarget(5, struct {
                fn f(sh: *Shape, v: bool) void {
                    if (sh.tool == .spotlight) sh.filled = v;
                }
            }.f, ellipse);
        },
        .measure_show, .measure_hide => ed.tools.export_measures = s == .measure_show,
        else => {
            const level = dimLevel(s) orelse return;
            ed.tools.spot_dim = level;
            try ed.editTarget(6, struct {
                fn f(sh: *Shape, v: u8) void {
                    if (sh.tool == .spotlight) sh.number = v;
                }
            }.f, level);
        },
    }
    ed.needs_render = true;
}

// --- export ---

/// The export: the layer cropped (and framed), without the rulers when
/// they are kept on screen only.
pub fn exportPixels(ed: *Editor) !doc_mod.Exported {
    const doc = &ed.doc;
    const keep_all = ed.tools.export_measures or for (doc.shapes.items) |s| {
        if (s.tool == .ruler) break false;
    } else true;
    if (keep_all) return doc_mod.exportImage(ed.alloc, ed.layer, ed.img.width, ed.img.height, doc.exportRect(), ed.beautify);
    var list: std.ArrayList(Shape) = .empty;
    defer list.deinit(ed.alloc);
    for (doc.shapes.items) |s| if (s.tool != .ruler) try list.append(ed.alloc, s);
    const layer = try ed.alloc.alloc(u32, ed.img.pixels.len);
    defer ed.alloc.free(layer);
    try doc_mod.composeRegion(ed.alloc, layer, ed.img.pixels, ed.img.width, ed.img.height, list.items, null, doc.imageRect());
    return doc_mod.exportImage(ed.alloc, layer, ed.img.width, ed.img.height, doc.exportRect(), ed.beautify);
}

// --- keys ---

/// The tools' configurable actions.
pub fn onAction(ed: *Editor, a: config.Action) !void {
    switch (a) {
        .ruler => try ed.setTool(.ruler),
        .spotlight => try ed.setTool(.spotlight),
        .eyedropper => try eyedrop.toggle(ed),
        .crop => try crop_mode.enter(ed),
        .pin => try open.pinExport(ed),
        .copy_text => try ocr_job.start(ed, .copy_text),
        .redact_sensitive => try ocr_job.start(ed, .redact),
        else => {},
    }
}

/// A tool control was pressed.
pub fn onButton(ed: *Editor, e: Ext) !void {
    switch (e) {
        .eyedropper => try eyedrop.toggle(ed),
        .crop, .crop_apply => try crop_mode.enter(ed),
        .crop_cancel => _ = cancel(ed),
        .pin => try open.pinExport(ed),
        .copy_text, .redact_sensitive => {
            ed.closePopover();
            try ocr_job.start(ed, if (e == .copy_text) .copy_text else .redact);
        },
        .aspect => |a| try crop_mode.setAspect(ed, a),
        .picked => |i| if (i < ed.tools.history.len) {
            _ = try eyedrop.useColor(ed, ed.tools.history.items[i]);
        },
    }
}

test {
    _ = color;
    _ = crop;
    _ = launch;
    _ = ocr_job;
    _ = @import("redact.zig");
    _ = ruler;
    _ = spotlight;
    _ = edges;
}
