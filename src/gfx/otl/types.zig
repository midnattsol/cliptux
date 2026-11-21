//! The shaping buffer's glyph record, its masks and classes, and the
//! scripts and tables shaping works with.

/// The raw layout tables of one face (empty when absent).
pub const Tables = struct {
    gsub: []const u8 = &.{},
    gpos: []const u8 = &.{},
    gdef: []const u8 = &.{},
};

/// Joining-form feature masks; `global` is set on every glyph.
pub const mask_isol: u8 = 1;
pub const mask_fina: u8 = 2;
pub const mask_medi: u8 = 4;
pub const mask_init: u8 = 8;
/// Syriac Alaph forms
pub const mask_fin2: u8 = 0x10;
pub const mask_fin3: u8 = 0x20;
pub const mask_med2: u8 = 0x40;
pub const mask_global: u8 = 0x80;

pub const Script = enum {
    arab,
    syrc,
    nko,
    hebr,

    pub fn tag(self: Script) [4]u8 {
        return switch (self) {
            .arab => "arab".*,
            .syrc => "syrc".*,
            .nko => "nko ".*,
            .hebr => "hebr".*,
        };
    }

    pub fn joins(self: Script) bool {
        return self != .hebr;
    }
};

pub const class_base: u8 = 1;
pub const class_lig: u8 = 2;
pub const class_mark: u8 = 3;

pub const Glyph = struct {
    gid: u16,
    /// source characters covered: [cl0, cl1)
    cl0: u32,
    cl1: u32,
    mask: u8 = mask_global,
    /// GDEF glyph class (or synthesized: base / mark)
    class: u8 = class_base,
    /// the source character is a combining mark (for fonts without GDEF)
    umark: bool = false,
    /// default-ignorable (ZWJ, ZWNJ...): skipped by matching, not drawn
    ignorable: bool = false,
    lig_id: u8 = 0,
    /// 1-based ligature component a mark belongs to; 0 = none
    lig_comp: u8 = 0,
    lig_n: u8 = 0,
    /// positioning, in font units
    adv: i32 = 0,
    dx: i32 = 0,
    dy: i32 = 0,
    /// index (in the same buffer) of the glyph this one hangs off
    /// (mark attachment); dx/dy are then relative to that glyph's origin
    attach: i32 = -1,
    /// cursive attachment: the glyph whose baseline this one follows; dy
    /// is relative to it until the chains are resolved
    cursive: i32 = -1,
};
