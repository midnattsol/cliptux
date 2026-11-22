//! "Show in Files": the file manager (org.freedesktop.FileManager1, which
//! Nautilus, Dolphin, Nemo and others implement) opens the folder with
//! the file selected.

const std = @import("std");
const dbus = @import("../platform/linux/dbus.zig");
const transfer = @import("../ui/transfer.zig");

/// Ask the file manager to show `path`. Fire and forget: only a failure
/// to send is an error.
pub fn showItem(alloc: std.mem.Allocator, conn: *dbus.Connection, path: []const u8) !void {
    const list = try transfer.fileUriList(alloc, path);
    defer alloc.free(list);
    const uri = std.mem.trimEnd(u8, list, "\r\n");
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(4);
    try m.putString(uri);
    m.endArray(arr);
    try m.putString(""); // startup id
    _ = try conn.callMethod("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", "ass", m.buf.items);
}
