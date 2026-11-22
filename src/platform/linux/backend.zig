//! The Linux backend (docs/PLATFORM.md): Wayland windows, D-Bus and the
//! xdg-desktop-portal, PipeWire, GNOME Shell, KWin and wlroots. The core
//! reaches it only through src/platform/api.zig; runtime choices among
//! desktops happen in here.

pub const sys = @import("sys.zig");
