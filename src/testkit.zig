//! The pieces of shotlet that the end-to-end driver (tools/e2e/drive.zig)
//! reuses: one module root so each source file belongs to one module.

pub const dbus = @import("platform/dbus.zig");
pub const pw = @import("platform/pw.zig");
pub const sys = @import("platform/sys.zig");
pub const png = @import("gfx/png.zig");
pub const window = @import("ui/window.zig");
pub const wayland = @import("platform/wayland.zig");
pub const render = @import("gfx/render.zig");
pub const text = @import("gfx/text.zig");
