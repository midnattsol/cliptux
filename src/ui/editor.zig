//! Interactive annotation editor: freeze-frame the screenshot fullscreen,
//! drag to select a region, annotate, then copy to clipboard or save.
//!
//! The document (shapes, selection) lives in image pixels (doc.zig). A
//! native-resolution composite `layer` holds the image with every
//! committed shape; exports crop it. The window shows the layer through a
//! `View` (view.zig) into `viewc`, a buffer-sized cache, and each frame
//! repaints only the rectangles that changed since that back buffer was
//! last drawn, then paints the chrome on top.
//!
//! This file holds the Editor's state and small accessors; the behaviour
//! lives in editor/: session (the event loop), events, pointer, drag,
//! drawing, keys_input, text_edit, props, commands, discard, selection,
//! history, hit, caches, beauty_cache, render, export, script, capmode
//! (the mode strip's modes) and winpick (clicking a window).

const std = @import("std");
const capture = @import("../app/capture.zig");
const window = @import("window.zig");
const png = @import("../gfx/png.zig");
const config = @import("../app/config.zig");
const shapes_mod = @import("shapes.zig");
const doc_mod = @import("doc.zig");
const ui = @import("editor_ui.zig");
const theme_mod = @import("theme.zig");
const motion = @import("motion.zig");
const dbus = @import("../platform/dbus.zig");
const tools = @import("tools/mod.zig");
const types = @import("editor/types.zig");

const session = @import("editor/session.zig");
const events = @import("editor/events.zig");
const caches = @import("editor/caches.zig");
const props = @import("editor/props.zig");
const commands = @import("editor/commands.zig");
const text_edit = @import("editor/text_edit.zig");
const history = @import("editor/history.zig");
const hit = @import("editor/hit.zig");
const render = @import("editor/render.zig");
const exporter = @import("editor/export.zig");
const fade = @import("editor/fade.zig");
const dim = @import("editor/dim.zig");
const capmode = @import("editor/capmode.zig");

const Window = window.Window;
const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;
const palette = shapes_mod.palette;

pub const Tool = shapes_mod.Tool;
pub const scrollSteps = @import("scroll_steps.zig").scrollSteps;
pub const RectList = @import("rect_list.zig").RectList;
pub const Action = types.Action;
pub const CopyNotice = types.CopyNotice;
pub const Result = types.Result;
pub const DragMode = types.DragMode;
pub const max_panes = types.max_panes;
pub const Pane = types.Pane;
pub const CaptureMode = capmode.Mode;

pub const Editor = struct {
    alloc: std.mem.Allocator,
    win: *Window,
    img: *const png.Image,
    doc: doc_mod.Document,

    /// image + committed shapes at native resolution (minus `lifted`)
    layer: []u32 = &.{},
    /// one per window surface (monitor); `cur` is the one being handled
    panes: [max_panes]Pane = @splat(.{}),
    n_panes: u8 = 1,
    pane_i: u8 = 0,
    /// surface under the pointer, and the one showing the toolbar
    mouse_pane: u8 = 0,
    tb_pane: u8 = 0,

    // --- tool state ---
    tool: Tool = .select,
    color_idx: u4 = 0,
    custom_active: bool = false,
    custom_color: u32 = 0xFF15AABF,
    /// logical stroke width; image pixels = thickness * ui scale / view scale
    thickness: i32 = 3,
    /// bit 0: filled (text: background pill), bit 1: rounded corners
    /// per tool, so the rectangle's fill doesn't leak into text
    styles: std.EnumArray(Tool, u2) = .initFill(0),
    beautify: doc_mod.Beautify = .{},
    /// new captures start with the beautify frame on (the panel's pin)
    beautify_always: bool = false,
    /// the extra tools' state (tools/mod.zig)
    tools: tools.State = .{},

    cur: ?Shape = null,
    selected: ?usize = null,
    /// shape left out of `layer` and drawn live (being moved or edited)
    lifted: ?usize = null,
    text: ?types.TextState = null,
    drag: DragMode = .none,
    mouse: Point = .{ .x = -10000, .y = -10000 },
    scroll_acc: f64 = 0,
    mod_shift: bool = false,
    mod_alt: bool = false,
    space: types.SpaceMove = .{},
    /// where the current drag started (image pixels)
    drag_anchor: Point = .{ .x = 0, .y = 0 },
    last_click: types.LastClick = .{},
    coalesce: types.Coalesce = .{},

    // --- chrome ---
    buttons: std.ArrayList(ui.Button) = .empty,
    toolbar_rect: Rect = Rect.empty,
    hover_btn: i32 = -1,
    focus: ?usize = null,
    help_open: bool = false,
    picker: ui.Picker = .{},
    /// the colour popover or the More menu, and how far it has opened
    popover: ui.Popover = .none,
    pop_rect: Rect = Rect.empty,
    pop_open: motion.Tween = .{},
    /// a closing popover, fading out
    pop_closing: ui.PopClosing = .{},
    /// the beautify panel beside the toolbar
    panel_rect: Rect = Rect.empty,
    seps: [12]Rect = undefined,
    n_seps: usize = 0,
    /// toolbar below the selection (else above or inside)
    tb_below: bool = true,
    tb_layout_pane: u8 = 0,
    /// toolbar position and opacity, the active tool's fill (relative to
    /// the toolbar), the hover highlight
    tb_x: motion.Tween = .{},
    tb_y: motion.Tween = .{},
    tb_alpha: motion.Tween = .{},
    act_x: motion.Tween = .{},
    act_y: motion.Tween = .{},
    hov: motion.Tween = .{ .dur_ms = theme_mod.motion_fast },
    hover_prev: i32 = -1,
    hover_since_ms: i64 = 0,
    /// hover_since_ms of the hover whose tooltip has been drawn
    tip_drawn_for: i64 = -1,
    /// move keyboard focus into the popover once it is laid out
    focus_into_popover: bool = false,
    /// mid-edge selection handle under the pointer (-1: none)
    sel_hover: i8 = -1,

    /// the look, from the desktop's preferences (see theme.zig)
    prefs: theme_mod.Prefs = .{},
    theme: theme_mod.Theme = theme_mod.Theme.get(true, null),
    /// session bus, to follow appearance changes while open
    bus: ?*dbus.Connection = null,

    /// of 256, what the dim outside the selection keeps (editor/dim.zig)
    dim_keep: u32,
    /// the dim fading in as the editor opens (editor/fade.zig)
    enter: fade.Enter = .{},
    needs_render: bool = true,
    running: bool = true,
    action: Action = .cancel,
    ui_init: bool = false,
    smoke_deadline_ms: i64 = 0, // dev: auto-cancel timestamp (0 = off)
    cfg_thickness: i32 = 3,
    binds: [config.n_actions]config.Bind = config.default_binds,
    copy_notice: CopyNotice = .none,
    copy_notice_hide_at_ms: i64 = 0,
    preset_sel: ?[4]i32 = null,
    /// the image has see-through pixels worth keeping (a window capture)
    keep_alpha: bool = false,
    /// how far a tall image is scrolled (ui/tall_view.zig), buffer pixels
    tall_scroll: i32 = 0,
    /// the capture mode to start after .new_capture (a shotlet command)
    next_capture: [:0]const u8 = "",
    /// the capture modes before a selection: the strip, clickable windows
    /// (editor/capmode.zig, editor/winpick.zig)
    capmode: capmode.State = .{},
    /// first run: show the "drag / Enter / ?" hint until the first action
    show_hint: bool = false,
    /// the hint was on screen this session (the caller remembers it)
    hint_seen: bool = false,
    /// until then (monotonic ms) Esc discards unsaved annotations
    /// (editor/discard.zig)
    discard_until_ms: i64 = 0,
    script: types.Script = .{},

    /// where each captured monitor lies inside `img`; set by the caller
    monitors: []const capture.Monitor = &.{},

    // --- behaviour, implemented in editor/ ---

    /// Run the editor; returns the user's chosen action and exported PNG.
    pub const run = session.run;
    pub const setPrefs = session.setPrefs;
    pub const handle = events.handle;
    pub const recompose = caches.recompose;
    pub const selDirty = caches.selDirty;
    pub const frameRect = caches.frameRect;
    pub const replaceImage = caches.replaceImage;
    pub const setThickness = props.setThickness;
    pub const editTarget = props.editTarget;
    pub const applyColor = props.applyColor;
    pub const setTool = props.setTool;
    pub const onButton = commands.onButton;
    pub const closePopover = commands.closePopover;
    pub const finish = commands.finish;
    pub const textWidthHandle = hit.textWidthHandle;
    pub const textHandleShape = hit.textHandleShape;
    pub const toggleTextWidth = text_edit.toggleTextWidth;
    pub const settle = history.settle;
    pub const caretRect = render.caretRect;
    pub const composeRegionTo = render.composeRegionTo;
    pub const liveBounds = render.liveBounds;
    pub const exportPng = exporter.exportPng;
    /// Ease back to the plain capture before the window goes away.
    pub const fadeOut = fade.out;

    pub fn init(alloc: std.mem.Allocator, win: *Window, img: *const png.Image) Editor {
        return .{ .alloc = alloc, .win = win, .img = img, .doc = doc_mod.Document.init(alloc, img.width, img.height), .dim_keep = dim.keepFor(img.pixels, img.width, img.height) };
    }

    /// Dev helper: start with a selection already in place (window pixels).
    pub fn presetSelection(self: *Editor, sel: ?[4]i32) void {
        self.preset_sel = sel;
    }

    pub fn deinit(self: *Editor) void {
        if (self.text) |t| self.alloc.free(t.orig);
        self.text = null;
        if (self.cur) |*s| s.deinit(self.alloc);
        if (self.drag == .resizing_shape) self.drag.resizing_shape.orig.deinit(self.alloc);
        tools.deinit(self);
        self.doc.deinit();
        self.buttons.deinit(self.alloc);
        self.pop_closing.release(self.alloc);
        self.releaseCaches();
        self.alloc.free(self.layer);
        self.layer = &.{};
    }

    /// Free the window-sized caches. Call after the editing session ends
    /// while the process stays alive (e.g. serving the clipboard).
    pub fn releaseCaches(self: *Editor) void {
        for (&self.panes) |*p| p.release(self.alloc);
    }

    /// The pane being handled (mouse input, or the one rendering).
    pub fn pn(self: anytype) @TypeOf(&self.panes[0]) {
        return &self.panes[self.pane_i];
    }

    pub fn isTbPane(self: *const Editor) bool {
        return self.pane_i == self.tb_pane;
    }

    pub fn isMousePane(self: *const Editor) bool {
        return self.pane_i == self.mouse_pane;
    }

    pub fn color(self: *const Editor) u32 {
        return if (self.custom_active) self.custom_color else palette[self.color_idx];
    }

    /// UI scale factor from the window's fractional scale (1.0 at 100%).
    pub fn uf(self: *const Editor) f64 {
        return @as(f64, @floatFromInt(self.pn().scale120)) / 120.0;
    }

    /// Scale a logical UI length to physical pixels.
    pub fn sc(self: *const Editor, v: f64) i32 {
        return @intFromFloat(@round(v * self.uf()));
    }

    pub fn screenRect(self: *const Editor) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.pn().width), .h = @intCast(self.pn().height) };
    }

    /// Stroke width in image pixels for the current thickness.
    pub fn imgThickness(self: *const Editor) i32 {
        const t = @as(f64, @floatFromInt(self.thickness)) * self.uf() / self.pn().view.scale;
        return @max(1, @as(i32, @intFromFloat(@round(t))));
    }

    pub fn imgAt(self: *const Editor, b: Point) Point {
        return self.pn().view.toImgEdge(b);
    }

    /// The selection on screen (buffer pixels).
    pub fn selBuf(self: *const Editor) ?Rect {
        const s = self.doc.sel orelse return null;
        return self.pn().view.rectToBuf(s.normalized());
    }

    pub fn handleRadius(self: *const Editor) i32 {
        return @max(6, self.sc(10));
    }
};

comptime {
    _ = fade;
    _ = dim;
    _ = capmode;
}
