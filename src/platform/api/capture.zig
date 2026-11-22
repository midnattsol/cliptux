//! The capture seam's platform-neutral types.

/// How the last capture got its pixels, for Settings and `shotlet
/// permissions` (kept on disk by its tag name): the shell integration,
/// the compositor directly, or a portal (with its permission).
pub const Path = enum {
    direct,
    portal,
    gnome,

    /// How a capture through it went, for `shotlet permissions`.
    pub fn text(p: Path) []const u8 {
        return switch (p) {
            .gnome => "through the GNOME integration (no permission used)",
            .direct => "directly from the compositor (no permission used)",
            .portal => "through the screen-sharing portal (its permission)",
        };
    }
};
