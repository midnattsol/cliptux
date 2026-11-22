//! The pieces of shotlet that the end-to-end drivers (tools/e2e/drive.zig,
//! tools/container/wldrive.zig, tools/e2e/droptarget.zig) reuse: one
//! module root so each source file belongs to one module. The drivers
//! are Linux tools: they take the Linux backend's plumbing as it is.

const native = @import("platform/api.zig").backend.native;

pub const dbus = native.dbus;
pub const pw = native.pw;
pub const pwstream = native.pwstream;
pub const sys = native.sys;
pub const png = @import("gfx/png.zig");
pub const window = native.window;
pub const wayland = native.wayland;
pub const render = @import("gfx/render.zig");
pub const text = @import("gfx/text.zig");
