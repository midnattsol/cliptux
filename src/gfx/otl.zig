//! OpenType Layout: glyph substitution (GSUB) and positioning (GPOS) from
//! the font's own tables, enough to shape Arabic, Syriac, NKo and Hebrew
//! the way the font designer intended: joining forms (isol/init/medi/fina),
//! required and contextual ligatures (lam-alef...), contextual alternates,
//! kerning and mark attachment (harakat, niqqud).
//!
//! GSUB lookup types 1-7 (reverse chaining, type 8, is skipped) and GPOS
//! types 1, 2, 4, 5, 6, 7, 8 and 9 (cursive attachment, type 3, is
//! skipped). Lookup flags honoured: ignore base glyphs / ligatures /
//! marks, mark attachment class and mark filtering sets (GDEF).
//!
//! Fonts are untrusted: every read is bounds-checked (out-of-range reads
//! yield 0, which every table treats as "nothing here"), nested lookups
//! are depth-limited and each shaping call has an operation budget, so a
//! hostile font can produce wrong glyphs but never a crash or a hang.
//!
//! The work is split under otl/: types (glyph record, masks, scripts),
//! common (reads, coverage, class definitions, GDEF, script and feature
//! lists), lookup (context, lookup flags), gsub, gpos, context ((chained)
//! context rules) and shape (feature stages, entry point).

const types = @import("otl/types.zig");
const common = @import("otl/common.zig");
const shaping = @import("otl/shape.zig");

pub const Tables = types.Tables;

/// Joining-form feature masks; `global` is set on every glyph.
pub const mask_isol = types.mask_isol;
pub const mask_fina = types.mask_fina;
pub const mask_medi = types.mask_medi;
pub const mask_init = types.mask_init;
/// Syriac Alaph forms
pub const mask_fin2 = types.mask_fin2;
pub const mask_fin3 = types.mask_fin3;
pub const mask_med2 = types.mask_med2;
pub const mask_global = types.mask_global;

pub const Script = types.Script;

pub const class_base = types.class_base;
pub const class_lig = types.class_lig;
pub const class_mark = types.class_mark;

pub const Glyph = types.Glyph;

pub const hasScript = common.hasScript;
pub const shape = shaping.shape;

// Reference every submodule so their tests run (a comptime block, unlike
// `test {}`, does not count as a test itself).
comptime {
    _ = types;
    _ = common;
    _ = @import("otl/lookup.zig");
    _ = @import("otl/gsub.zig");
    _ = @import("otl/gpos.zig");
    _ = @import("otl/context.zig");
    _ = shaping;
}
