//! Annotation shape model and rendering: geometry, tools, palette, the
//! shape painter, hit testing and handles.
//!
//! Shapes live in image pixels. `drawShape` paints one through an `Xform`
//! (image -> canvas), so the same code renders the native-resolution
//! export layer and the scaled on-screen preview.
//!
//! Facade over shapes/: geometry (Point, Rect, Xform), model (Tool,
//! Shape, palette), draw and draw_text (the painter), raster (rings,
//! ellipses, pixelation) and handles (selection handles).

const geometry = @import("shapes/geometry.zig");
const model = @import("shapes/model.zig");
const draw = @import("shapes/draw.zig");
const draw_text = @import("shapes/draw_text.zig");
const raster = @import("shapes/raster.zig");
const handles = @import("shapes/handles.zig");

pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Xform = geometry.Xform;

pub const Tool = model.Tool;
pub const Shape = model.Shape;
pub const textFontPx = model.textFontPx;
pub const palette = model.palette;
pub const palette_names = model.palette_names;
pub const palette_labels = model.palette_labels;
pub const swatch_order = model.swatch_order;

pub const drawShape = draw.drawShape;
pub const drawArrow = draw.drawArrow;
pub const TextCursor = draw_text.TextCursor;
pub const selection_color = draw_text.selection_color;

pub const roundRectRing = raster.roundRectRing;
pub const fillEllipseAA = raster.fillEllipseAA;
pub const pixelateAligned = raster.pixelateAligned;
pub const contrastColor = raster.contrastColor;

// drag constraints (drag.zig)
pub const dragCorners = @import("drag.zig").dragCorners;
pub const snapAngle = @import("drag.zig").snapAngle;

pub const handlePoints = handles.handlePoints;
pub const handleAt = handles.handleAt;
pub const resizeWithHandle = handles.resizeWithHandle;
pub const nudgeHandle = handles.nudgeHandle;
pub const handleFocus = handles.handleFocus;
pub const nearestCorner = handles.nearestCorner;
pub const normalizedHandle = handles.normalizedHandle;

// keep the submodules' tests reachable from the test root
comptime {
    _ = geometry;
    _ = model;
    _ = draw;
    _ = draw_text;
    _ = raster;
    _ = handles;
}
