//! The Linux backend (docs/PLATFORM.md): Wayland windows, D-Bus and the
//! xdg-desktop-portal, PipeWire, GNOME Shell, KWin and wlroots. The core
//! reaches it only through src/platform/api.zig; runtime choices among
//! desktops happen in here.

pub const sys = @import("sys.zig");
pub const libs = @import("libs.zig");
pub const fonts = @import("fonts.zig");

// Reach every module's tests.
comptime {
    _ = sys;
    _ = libs;
    _ = fonts;
}
