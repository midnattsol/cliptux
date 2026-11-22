//! The compile-only backend: every declaration the core may use, with its
//! type and no behaviour. It is the platform contract (api/contract.zig
//! checks real backends against it) and what `zig build check-portable`
//! builds the core with for Windows and macOS. Never shipped: a build
//! selects it only with -Dplatform-stub. A port starts by copying it.

pub const sys = @import("sys.zig");
pub const libs = @import("libs.zig");
pub const fonts = @import("fonts.zig");
