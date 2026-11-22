//! The desktop seam's platform-neutral types: the appearance the system
//! asks for, and what a file dialog answered.

/// What the system asks for: dark or light, an accent colour (null: the
/// default blue), animations (false: reduce motion).
pub const Appearance = struct {
    dark: bool = false,
    accent: ?u32 = null,
    animations: bool = true,
};

/// A save dialog's suggestions.
pub const SaveOptions = struct {
    title: []const u8 = "Save Screenshot",
    current_name: []const u8,
    current_folder: ?[]const u8 = null,
};

/// A file dialog's answer: the chosen local path (owned), cancelled, or
/// no dialog on this desktop.
pub const Choice = union(enum) {
    chosen: []u8,
    cancelled,
    unavailable,
};
