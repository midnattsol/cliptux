//! The Linux backend (docs/PLATFORM.md): Wayland windows, D-Bus and the
//! xdg-desktop-portal, PipeWire, GNOME Shell, KWin and wlroots. The core
//! reaches it only through src/platform/api.zig; runtime choices among
//! desktops happen in here.

pub const sys = @import("sys.zig");
pub const window = @import("window.zig");
pub const desktop = @import("desktop.zig");
pub const shell = @import("shell.zig");
pub const capture = @import("capture.zig");
pub const record = @import("record.zig");
pub const devtools = @import("devtools.zig").run;
pub const libs = @import("libs.zig");
pub const proc = @import("proc.zig");
pub const fonts = @import("fonts.zig");
/// Tesseract (portable code over api.libs; another backend may pick
/// another engine)
pub const ocr = @import("../../ocr/tesseract.zig");

// Reach every module's tests.
comptime {
    _ = sys;
    _ = libs;
    _ = proc;
    _ = window;
    _ = desktop;
    _ = shell;
    _ = capture;
    _ = record;
    _ = fonts;
    _ = ocr;
}
