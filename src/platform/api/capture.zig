//! The capture seam's platform-neutral types.

/// How the last capture got its pixels, for Settings and `shotlet
/// permissions`: the shell integration, the compositor directly, or a
/// portal (with its permission).
pub const Path = enum {
    direct,
    portal,
    shell,
};

/// Whether a scrolling capture can run here, asked before the person
/// picks a region: it needs frames of the region while the content
/// scrolls, from the shell integration or the compositor directly.
pub const ScrollSupport = enum {
    available,
    /// the shell integration would do it: installed, it loads at the
    /// next login
    shell_needs_login,
    /// the shell integration would do it: not installed (or disabled)
    shell_missing,
    /// the shell integration would do it: installed but not running
    /// (turned off, failed, out of date)
    shell_off,
    /// neither the shell integration nor direct capture here
    unsupported,
};
