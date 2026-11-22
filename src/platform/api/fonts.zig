//! Font discovery's platform-neutral types: which UI face is wanted, and
//! the font file a backend found for it.

const std = @import("std");

/// The UI faces: the sans-serif family in four weights, and monospace.
pub const Query = enum { sans, sans_medium, sans_semibold, sans_bold, mono };

/// A font file (and the face's index in a collection); the path is owned.
pub const Face = struct {
    path: []u8,
    index: u32 = 0,

    pub fn deinit(self: Face, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};
