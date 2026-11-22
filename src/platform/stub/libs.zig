//! Optional shared libraries of the contract: a library by base name and
//! the major versions Shotlet knows, opened at run time.

/// An opened library: its symbols by name.
pub const Lib = struct {
    pub fn lookup(self: *Lib, comptime T: type, name: [:0]const u8) ?T {
        _ = .{ self, name };
        return null;
    }
    pub fn close(self: *Lib) void {
        _ = self;
    }
};

/// The first of `base` at one of `versions` that opens (an empty version
/// is the unversioned name); null when none does.
pub fn open(base: []const u8, versions: []const []const u8) ?Lib {
    _ = .{ base, versions };
    return null;
}
