//! GNOME integration: the Shotlet GNOME Shell extension (gnome-extension/
//! in the source tree, embedded in the binary) places the quick-access
//! thumbnail and keeps it and pins above other windows, which a Wayland
//! client cannot do on mutter (no layer shell there).
//!
//!     shotlet gnome-integration status|install|uninstall
//!
//! install asks GNOME Shell to install it from extensions.gnome.org
//! (InstallRemoteExtension: GNOME asks for confirmation and loads it at
//! once); when that is not possible it copies the bundled extension to
//! ~/.local/share/gnome-shell/extensions and enables it. GNOME Shell on
//! Wayland only discovers a newly copied extension at the next login:
//! install then lists it in enabled-extensions itself, and the rest of
//! the setup runs once it is loaded (gnome/next_login, pending_setup).
//!
//! The extension also captures without prompts (see its extension.js):
//! its own shortcut, and dev.shotlet.Shell1.Capture() for Shotlet's tray
//! and a `shotlet` run from a terminal. Once it is active, install points
//! it at this binary and offers to move custom shortcuts that run shotlet
//! to the extension's shortcut (uninstall puts them back).
//!
//!     shotlet gnome-integration shortcut [ACCEL... | none]
//!     shotlet gnome-integration shortcut MODE [ACCEL... | none]
//!
//! Facade over gnome/: extension (GNOME Shell's view of it, install,
//! files), capture (asking it to capture, its shortcut), custom (custom
//! shortcuts that run shotlet), screenshot_keys (GNOME's own screenshot
//! keys), setup (install end to end) and cli.

const extension = @import("gnome/extension.zig");
const capture = @import("gnome/capture.zig");
const custom = @import("gnome/custom.zig");
const setup = @import("gnome/setup.zig");
const cli = @import("gnome/cli.zig");
const install_state = @import("gnome/install_state.zig");

pub const uuid = extension.uuid;
pub const bus_name = extension.bus_name;
pub const ext_schema_id = extension.ext_schema_id;
pub const isGnome = extension.isGnome;
pub const extensionActive = extension.extensionActive;
pub const shellState = extension.shellState;
pub const writeBundled = extension.writeBundled;
pub const schemaDir = extension.schemaDir;
pub const InstallResult = extension.InstallResult;
pub const InstallState = install_state.State;
pub const installState = install_state.read;

pub const CaptureRequest = capture.CaptureRequest;
pub const requestCapture = capture.requestCapture;
pub const CaptureInfo = capture.CaptureInfo;
pub const captureInfo = capture.captureInfo;

pub const isShotletCommand = custom.isShotletCommand;
pub const sameAccel = @import("accel.zig").sameAccel;

pub const MoveShortcuts = setup.MoveShortcuts;
pub const install = setup.install;
/// A line for the Settings window about the last install.
pub const note = setup.note;

pub const runCli = cli.runCli;
/// The extension runs: finish an install that waited for the next login.
pub const finishPendingSetup = @import("gnome/pending_setup.zig").finish;

comptime {
    _ = extension;
    _ = capture;
    _ = custom;
    _ = @import("gnome/screenshot_keys.zig");
    _ = setup;
    _ = install_state;
    _ = @import("gnome/pending_setup.zig");
    _ = @import("gnome/next_login.zig");
    _ = @import("gnome/shell_settings.zig");
    _ = cli;
}
