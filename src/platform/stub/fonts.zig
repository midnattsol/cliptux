//! Font discovery of the contract: the UI faces (api/fonts.zig) and a
//! face covering a codepoint, found where the platform keeps fonts.

const std = @import("std");
const types = @import("../api/fonts.zig");

pub const Query = types.Query;
pub const Face = types.Face;

pub const Db = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Db {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Db) void {
        self.* = undefined;
    }
    /// The best file for a UI face.
    pub fn match(self: *Db, q: Query) ?Face {
        _ = .{ self, q };
        return null;
    }
    /// The `skip`-th candidate for a face, when the best one failed to load.
    pub fn scanMatch(self: *Db, q: Query, skip: usize) ?Face {
        _ = .{ self, q, skip };
        return null;
    }
    /// A face that covers `cp`.
    pub fn forCodepoint(self: *Db, cp: u21) ?Face {
        _ = .{ self, cp };
        return null;
    }
    /// The `i`-th wide-coverage face to try for codepoints the UI font lacks.
    pub fn fallback(self: *Db, i: usize) ?Face {
        _ = .{ self, i };
        return null;
    }
};
