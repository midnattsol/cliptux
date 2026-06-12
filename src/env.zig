//! Process environment handed down from main to every subsystem.

pub const Env = struct {
    bus_addr: []const u8,
    runtime_dir: []const u8,
    wayland_display: []const u8,
    home: []const u8,
};
