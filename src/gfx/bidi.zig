//! Right-to-left text support: the core of the Unicode Bidirectional
//! Algorithm (UAX #9) for one line of text, and Arabic contextual shaping
//! through the presentation-form codepoints that common fonts map.
//!
//! Covered: paragraph direction from the first strong character (P2/P3),
//! explicit embeddings, overrides and isolates (X1-X10), weak types
//! W1-W7, bracket pairs N0, neutrals N1/N2, implicit levels I1/I2,
//! trailing whitespace L1, reordering L2 and mirroring L4. Bidi classes
//! come from a compact range table covering the scripts and punctuation
//! that occur in practice, not the full UCD.
//!
//! This file is a facade over the submodules in `bidi/`.

const classes = @import("bidi/classes.zig");
const brackets = @import("bidi/brackets.zig");
const levels = @import("bidi/levels.zig");
const reorder_mod = @import("bidi/reorder.zig");
const joining_mod = @import("bidi/joining.zig");
const arabic = @import("bidi/arabic.zig");

pub const Class = classes.Class;
pub const class = classes.class;
pub const isRtl = classes.isRtl;
pub const isExplicit = classes.isExplicit;

pub const mirror = brackets.mirror;

pub const Direction = levels.Direction;
pub const paragraphLevel = levels.paragraphLevel;
pub const resolveLevels = levels.resolveLevels;
pub const lineLevels = levels.lineLevels;

pub const reorder = reorder_mod.reorder;

pub const joiningMasks = joining_mod.joiningMasks;

pub const removed = arabic.removed;
pub const shapeArabic = arabic.shapeArabic;
pub const baseLetter = arabic.baseLetter;

comptime {
    _ = classes;
    _ = brackets;
    _ = levels;
    _ = reorder_mod;
    _ = joining_mod;
    _ = arabic;
    _ = @import("bidi/explicit.zig");
    _ = @import("bidi/sequence.zig");
    _ = @import("bidi/test_util.zig");
}
