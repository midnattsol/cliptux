//! The compile-only backend: every declaration the core may use, with its
//! type and no behaviour. It is the platform contract (api/contract.zig
//! checks real backends against it) and what `zig build check-portable`
//! builds the core with for Windows and macOS. Never shipped: a build
//! selects it only with -Dplatform-stub. A port starts by copying it.

const std = @import("std");
const Env = @import("../../app/env.zig").Env;

pub const sys = @import("sys.zig");
pub const window = @import("window.zig");
pub const desktop = @import("desktop.zig");
pub const shell = @import("shell.zig");
pub const capture = @import("capture.zig");
pub const record = @import("record.zig");
pub const libs = @import("libs.zig");
pub const proc = @import("proc.zig");
pub const fonts = @import("fonts.zig");
pub const ocr = @import("ocr.zig");

/// Development commands (`shotlet test-window` ...); false when `cmd` is
/// none of them.
pub fn devtools(gpa: std.mem.Allocator, env: Env, cmd: []const u8, args: []const [:0]const u8) error{Unavailable}!bool {
    _ = .{ gpa, env, cmd, args };
    return false;
}
