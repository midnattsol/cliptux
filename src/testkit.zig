//! The pieces of shotlet that the end-to-end driver (tools/e2e/drive.zig)
//! reuses: one module root so each source file belongs to one module.

pub const dbus = @import("platform/linux/dbus.zig");
pub const pw = @import("platform/linux/pw.zig");
pub const pwstream = @import("platform/linux/pwstream.zig");
pub const sys = @import("platform/api.zig").sys;
pub const png = @import("gfx/png.zig");
pub const window = @import("platform/linux/window.zig");
pub const wayland = @import("platform/linux/wayland.zig");
pub const render = @import("gfx/render.zig");
pub const text = @import("gfx/text.zig");
