//! Text recognition of the contract: whether an engine is there, and the
//! text of 0xAARRGGBB pixels (plain, or Tesseract's TSV with each word's
//! box, which src/ocr/page.zig reads). Results are owned by the caller.

const std = @import("std");

pub fn available() bool {
    return false;
}
pub fn recognize(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ?[]u8 {
    _ = .{ alloc, pixels, width, height };
    return null;
}
pub fn recognizeTsv(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, ppi: u32) ?[]u8 {
    _ = .{ alloc, pixels, width, height, ppi };
    return null;
}
