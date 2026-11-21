//! The recorder's module of the GNOME Shell extension (recorder.js),
//! built into the binary for `shotlet gnome-integration install` along
//! with the rest (gnome.zig).

pub const modules = [_][2][]const u8{
    .{ "recorder.js", @embedFile("gnome_ext_recorder_js") },
};
