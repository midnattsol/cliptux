//! The editor's value types: the outcome of a session, the drag in
//! progress, the text being edited, a surface's pane, and the small
//! bookkeeping structs the Editor groups its internal state into.

const std = @import("std");
const shapes_mod = @import("../shapes.zig");
const view_mod = @import("../view.zig");
const textedit = @import("../textedit.zig");
const ui = @import("../editor_ui.zig");
const RectList = @import("../rect_list.zig").RectList;

const Point = shapes_mod.Point;
const Rect = shapes_mod.Rect;
const Shape = shapes_mod.Shape;
const View = view_mod.View;

pub const Action = enum {
    cancel,
    /// the export is on the clipboard; close and keep serving it
    copied,
    save,
    /// save to a path the user picks (the caller shows the dialog)
    save_as,
    /// close and start another capture: `next_capture` names the command
    new_capture,
};

/// A failed copy says so; a copy that worked closes the editor (the
/// thumbnail, or nothing, is its feedback).
pub const CopyNotice = enum { none, failed };

pub const Result = struct {
    action: Action,
    /// encoded PNG of the selected region; null when action == .cancel
    png_data: ?[]u8 = null,
};

/// over everything outside the selection (theme.Theme.dim)
pub const dim_color: u32 = 0x52000000;

pub const DragMode = union(enum) {
    none,
    /// anchor corner, image pixels
    selecting: Point,
    moving_sel: MovingSel,
    resizing_sel: ResizingSel,
    drawing,
    moving_shape: MovingShape,
    resizing_shape: ResizingShape,
    picking: ui.PickPart,
    /// dragging the popover's size slider
    size_slider,
    /// dragging inside the text being edited
    text_select,
    /// dragging a text box's width handle
    text_width: TextWidth,

    pub const MovingSel = struct { orig: Rect, start: Point };
    pub const ResizingSel = struct { handle: u3, orig: Rect };
    pub const MovingShape = struct { start: Point, applied: Point };
    pub const ResizingShape = struct { handle: u3, orig: Shape };
    pub const TextWidth = struct { idx: usize, orig_w: i32, orig_x: i32, orig_box_w: i32, rtl: bool, editing: bool };
};

pub const TextState = struct {
    idx: usize,
    te: textedit.TextEdit,
    is_new: bool,
    /// the text before this edit, to tell whether anything changed
    orig: []u8,
    /// the caret shows at the end of the line above a soft wrap
    upstream: bool = false,
    /// x kept across Up/Down presses
    goal_x: ?i32 = null,
};

/// Undo coalescing: repeats of the same kind of tweak within a moment
/// share one checkpoint (see props.editTarget).
pub const Coalesce = struct {
    kind: u8 = 0,
    ms: i64 = 0,
};

/// The last left click, to tell double clicks.
pub const LastClick = struct {
    ms: i64 = 0,
    at: Point = .{ .x = 0, .y = 0 },
};

/// Space held during a drag moves the rectangle instead of sizing it.
pub const SpaceMove = struct {
    held: bool = false,
    last: ?Point = null,
};

/// Dev: the scripted input being played (SHOTLET_EDITOR_SCRIPT).
pub const Script = struct {
    src: ?[]const u8 = null,
    pos: usize = 0,
    /// the surface scripted pointer events go to
    surface: u8 = 0,
};

pub const max_panes = 8;

/// What one surface shows: a View of the document and its caches. With
/// one surface per monitor, each pane maps its monitor's image rect.
pub const Pane = struct {
    alive: bool = false,
    /// buffer size and scale of the surface
    width: u32 = 0,
    height: u32 = 0,
    scale120: u32 = 120,
    view: View = .{},
    /// layer as shown through `view`, buffer-sized, and a dimmed copy
    viewc: []u32 = &.{},
    viewc_dim: []u32 = &.{},
    stroke_mask: []u8 = &.{}, // scratch for Canvas strokes
    /// coverage of the freehand stroke being drawn, buffer-sized
    live_cov: []u8 = &.{},
    live_bbox: Rect = Rect.empty,
    /// beautify preview of the selection (background, shadow, corners)
    bcache: []u32 = &.{},
    bcache_rect: Rect = Rect.empty,
    bcache_valid: bool = false,
    /// per back buffer: what changed since it was last drawn
    pending: [2]RectList = .{ .{}, .{} },
    content_dirty: RectList = .{},
    overlays: RectList = .{},
    last_frame: []u32 = &.{},
    /// needs a frame once its surface is free
    due: bool = true,
    /// blurred backdrops and shadows of the floating chrome
    backdrops: [ui.n_slots]ui.Backdrop = @splat(.{}),
    /// bumped whenever what composeRegion paints may have changed, so the
    /// backdrops know when to look again
    gen: u64 = 1,

    pub fn release(self: *Pane, alloc: std.mem.Allocator) void {
        alloc.free(self.viewc);
        self.viewc = &.{};
        alloc.free(self.viewc_dim);
        self.viewc_dim = &.{};
        alloc.free(self.stroke_mask);
        self.stroke_mask = &.{};
        alloc.free(self.live_cov);
        self.live_cov = &.{};
        alloc.free(self.bcache);
        self.bcache = &.{};
        self.bcache_valid = false;
        self.last_frame = &.{};
        for (&self.backdrops) |*b| b.release(alloc);
    }
};
