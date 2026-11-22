//! Keyboard translation for the Wayland window: evdev code + compositor
//! modifier state -> keysym and UTF-8 text in the user's real layout.
//!
//! libxkbcommon is dlopen'ed at runtime (zero build dependencies, like
//! libpipewire). When it is missing, or the compositor sends no usable
//! keymap, translation falls back to a built-in US table. Dead keys and
//! Compose sequences use the compose table of the locale in
//! LC_ALL / LC_CTYPE / LANG.
//!
//! Key repeat is driven by `Repeat`, a pure deadline tracker the window
//! polls with a monotonic clock (tests feed it a fake one).
//!
//! This file re-exports keyboard/: xkb (library binding), translator
//! (`Keyboard`), keysyms, us_layout (fallback) and repeat.

const xkb = @import("keyboard/xkb.zig");
const translator = @import("keyboard/translator.zig");
const keysyms = @import("keyboard/keysyms.zig");
const us_layout = @import("keyboard/us_layout.zig");
const repeat = @import("keyboard/repeat.zig");

pub const RuleNames = xkb.RuleNames;
pub const available = xkb.available;
pub const XK = keysyms.XK;
pub const keysymLabel = keysyms.keysymLabel;
pub const Translated = translator.Translated;
pub const Keyboard = translator.Keyboard;
pub const Repeat = repeat.Repeat;
pub const monotonicMs = repeat.monotonicMs;

// Reach every submodule's tests (a `test {}` block would count as one).
comptime {
    _ = xkb;
    _ = translator;
    _ = keysyms;
    _ = us_layout;
    _ = repeat;
}
