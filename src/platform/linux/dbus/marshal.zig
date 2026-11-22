//! Body builder: appends DBus wire values with the alignment rules of the
//! little-endian marshalling format.

const std = @import("std");

/// Body builder. All append methods handle alignment.
pub const Marshal = struct {
    buf: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Marshal {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Marshal) void {
        self.buf.deinit(self.alloc);
    }

    pub fn pad(self: *Marshal, alignment: usize) !void {
        while (self.buf.items.len % alignment != 0)
            try self.buf.append(self.alloc, 0);
    }
    pub fn putByte(self: *Marshal, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }
    pub fn putU16(self: *Marshal, v: u16) !void {
        try self.pad(2);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putU32(self: *Marshal, v: u32) !void {
        try self.pad(4);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putI32(self: *Marshal, v: i32) !void {
        try self.putU32(@bitCast(v));
    }
    pub fn putU64(self: *Marshal, v: u64) !void {
        try self.pad(8);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putBool(self: *Marshal, v: bool) !void {
        try self.putU32(if (v) 1 else 0);
    }
    pub fn putString(self: *Marshal, s: []const u8) !void {
        try self.putU32(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    pub fn putObjectPath(self: *Marshal, s: []const u8) !void {
        try self.putString(s);
    }
    pub fn putSignature(self: *Marshal, s: []const u8) !void {
        try self.buf.append(self.alloc, @intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    /// variant with a simple inner value
    pub fn putVariantString(self: *Marshal, s: []const u8) !void {
        try self.putSignature("s");
        try self.putString(s);
    }
    pub fn putVariantBool(self: *Marshal, v: bool) !void {
        try self.putSignature("b");
        try self.putBool(v);
    }
    pub fn putVariantU32(self: *Marshal, v: u32) !void {
        try self.putSignature("u");
        try self.putU32(v);
    }
    pub fn putVariantI32(self: *Marshal, v: i32) !void {
        try self.putSignature("i");
        try self.putI32(v);
    }

    /// Begin an array: returns position of the length field. Call endArray
    /// after writing elements. elem_alignment is the alignment of one element.
    pub fn beginArray(self: *Marshal, elem_alignment: usize) !ArrayMark {
        try self.pad(4);
        const len_pos = self.buf.items.len;
        try self.buf.appendSlice(self.alloc, &.{ 0, 0, 0, 0 });
        try self.pad(elem_alignment);
        return .{ .len_pos = len_pos, .start = self.buf.items.len };
    }
    pub fn endArray(self: *Marshal, mark: ArrayMark) void {
        const len: u32 = @intCast(self.buf.items.len - mark.start);
        @memcpy(self.buf.items[mark.len_pos..][0..4], std.mem.asBytes(&len));
    }
    pub const ArrayMark = struct { len_pos: usize, start: usize };

    /// dict entries and structs are 8-aligned
    pub fn beginStruct(self: *Marshal) !void {
        try self.pad(8);
    }
};

test "marshal alignment" {
    var m = Marshal.init(std.testing.allocator);
    defer m.deinit();
    try m.putByte(1);
    try m.putU32(0xAABBCCDD);
    try std.testing.expectEqual(@as(usize, 8), m.buf.items.len);
    try std.testing.expectEqual(@as(u8, 0xDD), m.buf.items[4]);
}
