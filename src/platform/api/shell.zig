//! The shell integration seam's platform-neutral types. A desktop shell
//! integration (Linux: the Shotlet GNOME Shell extension) captures
//! without prompts, owns the global shortcuts, and keeps floating windows
//! above the others where the desktop offers no other way.

/// The integration as Settings shows it.
pub const State = enum {
    /// this desktop has none
    unsupported,
    active,
    /// installed; active after the next login
    installed,
    missing,
    failed,
};

/// How the integration captures: whether it does, the shortcut it holds
/// (or that the system's own screenshot tool holds instead: `blocked`).
pub const CaptureInfo = struct {
    capture: bool = false,
    shortcut_buf: [64]u8 = undefined,
    shortcut_len: usize = 0,
    blocked: bool = false,

    pub fn shortcut(self: *const CaptureInfo) ?[]const u8 {
        return if (self.shortcut_len > 0) self.shortcut_buf[0..self.shortcut_len] else null;
    }
};

/// How the Settings window speaks of the integration and of the desktop's
/// own shortcuts: the backend's words, as its desktop names things.
pub const Words = struct {
    /// the integration's group: "GNOME integration"
    title: []const u8 = "Desktop integration",
    /// what gets installed: "Shell extension"
    part: []const u8 = "Desktop integration",
    /// the command that manages it: "shotlet gnome-integration"
    command: []const u8 = "",
    /// the desktop's own screenshot tool, when it holds the key the
    /// integration would take: "GNOME\u{2019}s screenshot key"
    system_key: []const u8 = "The desktop\u{2019}s screenshot key",
    /// where people bind a key to a command:
    /// "GNOME Settings \u{203A} Keyboard \u{203A} Custom Shortcuts"
    custom_shortcuts: []const u8 = "Your desktop\u{2019}s keyboard settings",
};

/// The answer to asking the integration to take a capture itself.
pub const Handoff = enum { started, declined, unavailable };

/// A capture the integration took and started Shotlet on (`shotlet
/// --from-shell ID ...`): where its pieces are.
pub const HandedCapture = struct {
    id: []const u8,
    monitors: []const u8 = "",
    pieces: []const u8 = "",
    /// the key press, on the monotonic clock, in ms
    t0_ms: ?i64 = null,
};
