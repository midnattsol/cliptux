//! Minimal TrueType/OpenType font parser and rasterizer: cmap (formats 4
//! and 12), glyf (simple + composite), CFF outlines ('OTTO' fonts, via
//! cff.zig), loca, hmtx, and .ttc collections. Outlines are flattened and
//! filled with a 4x supersampled nonzero-winding scanline, producing 8-bit
//! coverage bitmaps. Enough for crisp UI text; no hinting. The layout
//! tables (GSUB/GPOS/GDEF) are only located here; otl.zig applies them.
//!
//! Font files are untrusted: every table read is bounds-checked, and a
//! malformed glyph rasterizes as empty instead of failing the whole font.
//!
//! Facade over ttf/: sfnt (directory, collections), cmap, glyf, path,
//! raster, font (the Font face and its glyph cache).

const font = @import("ttf/font.zig");

pub const LoadError = font.LoadError;
pub const Glyph = font.Glyph;
pub const Font = font.Font;
pub const max_size_px = font.max_size_px;
pub const faceCount = @import("ttf/sfnt.zig").faceCount;
pub const Path = @import("ttf/path.zig").Path;

test {
    _ = @import("cff.zig");
    _ = @import("otl.zig");
    _ = @import("ttf/bytes.zig");
    _ = @import("ttf/mmap.zig");
    _ = @import("ttf/sfnt.zig");
    _ = @import("ttf/cmap.zig");
    _ = @import("ttf/glyf.zig");
    _ = @import("ttf/path.zig");
    _ = @import("ttf/raster.zig");
    _ = @import("ttf/font.zig");
    _ = @import("ttf/test_font.zig");
}
