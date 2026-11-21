//! PNG file framing: the signature, reading the chunk sequence and writing
//! chunks with their CRC.

const std = @import("std");

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const Chunk = struct {
    type: *const [4]u8,
    data: []const u8,
};

/// Walks the chunks after the signature. CRCs are not checked.
pub const Reader = struct {
    data: []const u8,
    pos: usize = signature.len,

    /// The next chunk, or null when fewer than 8 bytes remain (a missing
    /// IEND is tolerated).
    pub fn next(self: *Reader) !?Chunk {
        const data = self.data;
        if (data.len - self.pos < 8) return null;
        const chunk_len = std.mem.readInt(u32, data[self.pos..][0..4], .big);
        const chunk_type = data[self.pos + 4 ..][0..4];
        self.pos += 8;
        if (chunk_len > 0x7FFFFFFF or data.len - self.pos < @as(usize, chunk_len) + 4) return error.Truncated;
        const chunk = data[self.pos..][0..chunk_len];
        self.pos += chunk_len + 4; // skip crc
        return .{ .type = chunk_type, .data = chunk };
    }
};

/// Writes one chunk whose data arrives in pieces: begin() with the total
/// length, append() each piece, end() for the CRC.
pub const Writer = struct {
    crc: std.hash.Crc32,

    pub fn begin(alloc: std.mem.Allocator, out: *std.ArrayList(u8), chunk_type: *const [4]u8, len: u32) !Writer {
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, len, .big);
        try out.appendSlice(alloc, &len_buf);
        var w: Writer = .{ .crc = std.hash.Crc32.init() };
        w.crc.update(chunk_type);
        try out.appendSlice(alloc, chunk_type);
        return w;
    }

    pub fn append(self: *Writer, alloc: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
        self.crc.update(data);
        try out.appendSlice(alloc, data);
    }

    pub fn end(self: *Writer, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var crc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_buf, self.crc.final(), .big);
        try out.appendSlice(alloc, &crc_buf);
    }
};

pub fn writeChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    var w: Writer = try .begin(alloc, out, chunk_type, @intCast(data.len));
    try w.append(alloc, out, data);
    try w.end(alloc, out);
}

/// The 13-byte IHDR payload (compression, filter method 0).
pub fn ihdr(width: u32, height: u32, depth: u8, color_type: u8, interlace: bool) [13]u8 {
    var h: [13]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], width, .big);
    std.mem.writeInt(u32, h[4..8], height, .big);
    h[8] = depth;
    h[9] = color_type;
    h[10] = 0; // compression
    h[11] = 0; // filter
    h[12] = @intFromBool(interlace);
    return h;
}
