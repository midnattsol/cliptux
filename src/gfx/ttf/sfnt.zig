//! sfnt container: .ttc collection headers and the table directory.

const std = @import("std");
const otl = @import("../otl.zig");
const bytes = @import("bytes.zig");
const beU16 = bytes.beU16;
const beU32 = bytes.beU32;

pub const sfnt_truetype = 0x00010000;
const sfnt_true = 0x74727565; // 'true' (Apple)
const sfnt_otto = 0x4F54544F; // 'OTTO' (CFF outlines)
const tag_ttcf = 0x74746366; // 'ttcf'

/// Number of faces in a font file (1 for plain .ttf/.otf, n for .ttc).
pub fn faceCount(data: []const u8) u32 {
    const tag = beU32(data, 0) catch return 0;
    if (tag != tag_ttcf) return 1;
    return @min(beU32(data, 8) catch 0, 1024);
}

/// The table slices a face needs; absent tables are empty.
pub const Tables = struct {
    head: []const u8 = &.{},
    maxp: []const u8 = &.{},
    cmap: []const u8 = &.{},
    glyf: []const u8 = &.{},
    loca: []const u8 = &.{},
    hhea: []const u8 = &.{},
    hmtx: []const u8 = &.{},
    cff: []const u8 = &.{},
    layout: otl.Tables = .{},
};

/// Offset of face `index`'s table directory (0 for a plain font file).
pub fn directoryOffset(data: []const u8, index: u32) error{ Truncated, NotTrueType, BadFont }!usize {
    if ((beU32(data, 0) catch return error.NotTrueType) == tag_ttcf) {
        const n = try beU32(data, 8);
        if (index >= n) return error.BadFont;
        return try beU32(data, 12 + @as(usize, index) * 4);
    } else if (index != 0) return error.BadFont;
    return 0;
}

/// Check the sfnt version at `dir` and slice out the known tables.
pub fn readTables(data: []const u8, dir: usize) error{ Truncated, NotTrueType }!Tables {
    const version = try beU32(data, dir);
    if (version != sfnt_truetype and version != sfnt_true and version != sfnt_otto) return error.NotTrueType;

    const num_tables = try beU16(data, dir + 4);
    var t: Tables = .{};
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = dir + 12 + i * 16;
        const tag = bytes.sub(data, rec, 4) orelse return error.Truncated;
        const off = try beU32(data, rec + 8);
        const len = try beU32(data, rec + 12);
        const slice = bytes.sub(data, off, len) orelse return error.Truncated;
        assign(&t, tag, slice);
    }
    return t;
}

fn assign(t: *Tables, tag: []const u8, slice: []const u8) void {
    if (std.mem.eql(u8, tag, "head")) t.head = slice;
    if (std.mem.eql(u8, tag, "maxp")) t.maxp = slice;
    if (std.mem.eql(u8, tag, "cmap")) t.cmap = slice;
    if (std.mem.eql(u8, tag, "glyf")) t.glyf = slice;
    if (std.mem.eql(u8, tag, "loca")) t.loca = slice;
    if (std.mem.eql(u8, tag, "hhea")) t.hhea = slice;
    if (std.mem.eql(u8, tag, "hmtx")) t.hmtx = slice;
    if (std.mem.eql(u8, tag, "CFF ")) t.cff = slice;
    if (std.mem.eql(u8, tag, "GSUB")) t.layout.gsub = slice;
    if (std.mem.eql(u8, tag, "GPOS")) t.layout.gpos = slice;
    if (std.mem.eql(u8, tag, "GDEF")) t.layout.gdef = slice;
}
