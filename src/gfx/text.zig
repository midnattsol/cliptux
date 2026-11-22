//! High-level text drawing: system fonts (found through fontconfig or a
//! directory scan, see fontdb.zig) with a per-codepoint fallback chain, so
//! characters the UI font lacks come from another installed face instead of
//! tofu. Falls back to the 5x7 bitmap font when no usable font exists.
//! Sizes are in pixels (already display-scaled). Text is decoded lossily:
//! invalid UTF-8 shows as U+FFFD, never crashes.
//!
//! Facade over text/: state (fonts, fallback), shape and layout (a
//! paragraph into positioned glyphs), draw, measure, caret, wrap_lines.

const state = @import("text/state.zig");
const layout = @import("text/layout.zig");
const draw_mod = @import("text/draw.zig");
const measure = @import("text/measure.zig");
const caret = @import("text/caret.zig");
const wrap_lines = @import("text/wrap_lines.zig");

pub const Style = state.Style;
pub const Face = state.Face;
pub const init = state.init;
pub const initWith = state.initWith;
pub const deinit = state.deinit;
pub const available = state.available;

pub const Item = layout.Item;

pub const draw = draw_mod.draw;
pub const drawStyled = draw_mod.drawStyled;
pub const drawDir = draw_mod.drawDir;
pub const drawRange = draw_mod.drawRange;

pub const width = measure.width;
pub const widthStyled = measure.widthStyled;
pub const widthDir = measure.widthDir;
pub const widthRange = measure.widthRange;
pub const height = measure.height;
pub const heightStyled = measure.heightStyled;
pub const ascent = measure.ascent;

pub const offsetForX = caret.offsetForX;
pub const offsetForXDir = caret.offsetForXDir;
pub const offsetForXRange = caret.offsetForXRange;
pub const xForOffset = caret.xForOffset;
pub const xForOffsetDir = caret.xForOffsetDir;
pub const xForOffsetRange = caret.xForOffsetRange;
pub const rangeSpans = caret.rangeSpans;
pub const rangeSpansLine = caret.rangeSpansLine;

pub const Line = wrap_lines.Line;
pub const wrapLines = wrap_lines.wrapLines;

test {
    _ = state;
    _ = layout;
    _ = @import("text/shape.zig");
    _ = @import("text/tabular.zig");
    _ = draw_mod;
    _ = measure;
    _ = caret;
    _ = wrap_lines;
    _ = @import("wrap.zig");
    _ = @import("bidi.zig");
    _ = @import("otl.zig");
    _ = @import("ttf.zig");
    _ = @import("fontdb.zig");
    _ = @import("utf8.zig");
}
