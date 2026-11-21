//! The GNOME Shell extension's files, built into the binary for
//! `shotlet gnome-integration install` (the schemas are in gnome.zig).

pub const File = struct { name: []const u8, data: []const u8 };

pub const files = [_]File{
    .{ .name = "extension.js", .data = @embedFile("gnome_ext_js") },
    .{ .name = "recorder.js", .data = @embedFile("gnome_ext_recorder_js") },
    .{ .name = "metadata.json", .data = @embedFile("gnome_ext_metadata") },
};

pub const js = files[0].data;
pub const metadata = files[2].data;
