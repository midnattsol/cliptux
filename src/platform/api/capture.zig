//! The capture seam's platform-neutral types.

/// How the last capture got its pixels, for Settings and `shotlet
/// permissions`: the shell integration, the compositor directly, or a
/// portal (with its permission).
pub const Path = enum {
    direct,
    portal,
    shell,
};
