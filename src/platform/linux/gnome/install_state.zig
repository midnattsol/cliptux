//! Where the extension stands, from the files, GNOME Shell's view of it
//! and org.gnome.shell: not installed, installed but disabled, installed
//! and loading at the next login (GNOME Shell on Wayland only discovers
//! new extensions at login), or active.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const Env = @import("../../../app/env.zig").Env;
const extension = @import("extension.zig");
const shell_settings = @import("shell_settings.zig");

pub const State = enum {
    /// GNOME Shell is not reachable
    no_shell,
    not_installed,
    /// installed, not in enabled-extensions
    disabled,
    /// installed and enabled; every user extension is turned off
    user_extensions_off,
    /// installed and enabled; the running shell does not know it yet
    next_login,
    active,
    failed,
    out_of_date,

    /// A line for `gnome-integration status` and `permissions`.
    pub fn text(s: State) []const u8 {
        return switch (s) {
            .no_shell => "GNOME Shell not reachable",
            .not_installed => "not installed (shotlet gnome-integration install)",
            .disabled => "installed but disabled (shotlet gnome-integration install enables it)",
            .user_extensions_off => "installed, but GNOME has user extensions turned off (gsettings set org.gnome.shell disable-user-extensions false)",
            .next_login => "installed, loads at your next login (log out and back in)",
            .active => "active",
            .failed => "error (see journalctl /usr/bin/gnome-shell)",
            .out_of_date => "out of date for this GNOME version",
        };
    }
};

/// What the state is decided from.
pub const Facts = struct {
    /// the extension owns its bus name
    active: bool,
    /// GNOME Shell's state for it (extension.shellState); null: no shell
    shell_state: ?u32,
    /// its files are in the user's extension directory
    files: bool,
    /// in enabled-extensions, not in disabled-extensions
    enabled: bool,
    /// disable-user-extensions is true
    user_extensions_off: bool,
};

pub fn decide(f: Facts) State {
    if (f.active) return .active;
    const st = f.shell_state orelse return .no_shell;
    if (st == 1) return .active;
    if (st == 3) return .failed;
    if (st == 4) return .out_of_date;
    const known = st != 99;
    if (!known and !f.files) return .not_installed;
    if (!f.enabled) return .disabled;
    if (f.user_extensions_off) return .user_extensions_off;
    // known and enabled but not running: GNOME turned it off
    return if (known) .disabled else .next_login;
}

/// The facts as they are now.
pub fn read(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) State {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return decide(.{
        .active = extension.extensionActive(bus),
        .shell_state = extension.shellState(gpa, bus),
        .files = filesPresent(env.home),
        .enabled = shell_settings.enabled(arena, env),
        .user_extensions_off = shell_settings.userExtensionsOff(arena, env),
    });
}

fn filesPresent(home: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const dir = extension.extensionDir(&buf, home) catch return false;
    var p: [1100]u8 = undefined;
    const meta = std.fmt.bufPrint(&p, "{s}/metadata.json", .{dir}) catch return false;
    const fd = sys.openRead(meta) catch return false;
    sys.close(fd);
    return true;
}

test "the extension's states are told apart" {
    const base: Facts = .{ .active = false, .shell_state = 99, .files = false, .enabled = false, .user_extensions_off = false };
    try std.testing.expectEqual(State.not_installed, decide(base));
    var f = base;
    f.files = true;
    try std.testing.expectEqual(State.disabled, decide(f));
    f.enabled = true;
    try std.testing.expectEqual(State.next_login, decide(f));
    f.user_extensions_off = true;
    try std.testing.expectEqual(State.user_extensions_off, decide(f));
    f = base;
    f.active = true;
    try std.testing.expectEqual(State.active, decide(f));
    f = base;
    f.shell_state = 2; // installed system-wide, switched off
    try std.testing.expectEqual(State.disabled, decide(f));
    f.shell_state = 3;
    try std.testing.expectEqual(State.failed, decide(f));
    f.shell_state = null;
    try std.testing.expectEqual(State.no_shell, decide(f));
}
