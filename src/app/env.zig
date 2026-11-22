//! Process environment handed down from main to every subsystem, and the
//! XDG base directories derived from it.

const std = @import("std");

pub const Env = struct {
    /// where the desktop session's services are: the backend's, opaque
    /// here (api.desktop.addresses fills it)
    session: @import("../platform/api.zig").desktop.Addresses,
    runtime_dir: []const u8,
    home: []const u8,
    /// the parent's complete environment, passed on to children unchanged
    envp: [*:null]const ?[*:0]const u8 = &empty_envp,
    /// TZ, when set (see clock.zig)
    tz: ?[]const u8 = null,
};

const empty_envp = [_:null]?[*:0]const u8{};

/// XDG base directories, set once by main. Kept process-wide because some
/// callers (the Settings window) only receive `home`.
pub const Xdg = struct {
    /// XDG_CONFIG_HOME, only when it is an absolute path (the spec says
    /// relative values are invalid and must be ignored)
    config_home: ?[]const u8 = null,
    /// XDG_STATE_HOME, same rule
    state_home: ?[]const u8 = null,
    /// XDG_PICTURES_DIR from the environment, if exported
    pictures_dir: ?[]const u8 = null,
    /// XDG_CACHE_HOME, absolute only
    cache_home: ?[]const u8 = null,
};

pub var xdg: Xdg = .{};

/// Keep a value only when it is a non-empty absolute path.
pub fn absolute(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    if (s.len == 0 or s[0] != '/') return null;
    return s;
}

/// $XDG_CONFIG_HOME, or ~/.config.
pub fn configHome(buf: []u8, home: []const u8) ![]u8 {
    if (xdg.config_home) |d| return std.fmt.bufPrint(buf, "{s}", .{d});
    return std.fmt.bufPrint(buf, "{s}/.config", .{home});
}

/// $XDG_CONFIG_HOME/shotlet, or ~/.config/shotlet.
pub fn configDir(buf: []u8, home: []const u8) ![]u8 {
    if (xdg.config_home) |d| return std.fmt.bufPrint(buf, "{s}/shotlet", .{d});
    return std.fmt.bufPrint(buf, "{s}/.config/shotlet", .{home});
}

/// $XDG_STATE_HOME/shotlet, or ~/.local/state/shotlet.
pub fn stateDir(buf: []u8, home: []const u8) ![]u8 {
    if (xdg.state_home) |d| return std.fmt.bufPrint(buf, "{s}/shotlet", .{d});
    return std.fmt.bufPrint(buf, "{s}/.local/state/shotlet", .{home});
}

/// $XDG_CACHE_HOME/shotlet, or ~/.cache/shotlet.
pub fn cacheDir(buf: []u8, home: []const u8) ![]u8 {
    if (xdg.cache_home) |d| return std.fmt.bufPrint(buf, "{s}/shotlet", .{d});
    return std.fmt.bufPrint(buf, "{s}/.cache/shotlet", .{home});
}

/// Expand a leading `~/`, `$HOME/` or `${HOME}/` (and a bare `~`/`$HOME`).
pub fn expandHome(buf: []u8, home: []const u8, path: []const u8) ![]u8 {
    const prefixes = [_][]const u8{ "~", "$HOME", "${HOME}" };
    for (prefixes) |p| {
        if (std.mem.eql(u8, path, p)) return std.fmt.bufPrint(buf, "{s}", .{home});
        if (path.len > p.len and std.mem.startsWith(u8, path, p) and path[p.len] == '/')
            return std.fmt.bufPrint(buf, "{s}{s}", .{ home, path[p.len..] });
    }
    return std.fmt.bufPrint(buf, "{s}", .{path});
}

/// The user's Pictures directory: $XDG_PICTURES_DIR, then the entry in
/// $XDG_CONFIG_HOME/user-dirs.dirs (localized, e.g. "Imágenes"), then
/// ~/Pictures. A value equal to $HOME means "disabled" per the spec, so it
/// falls through to ~/Pictures rather than saving into $HOME.
pub fn picturesDir(alloc: std.mem.Allocator, buf: []u8, home: []const u8) ![]u8 {
    if (xdg.pictures_dir) |d| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, d, "/"), std.mem.trimEnd(u8, home, "/")))
            return std.fmt.bufPrint(buf, "{s}", .{d});
    }
    var path_buf: [1024]u8 = undefined;
    var cfg_home_buf: [1024]u8 = undefined;
    const cfg_home = try configHome(&cfg_home_buf, home);
    const dirs_path = try std.fmt.bufPrint(&path_buf, "{s}/user-dirs.dirs", .{cfg_home});
    if (@import("../platform/api.zig").sys.readFileAlloc(alloc, dirs_path, 64 * 1024)) |data| {
        defer alloc.free(data);
        if (parseUserDir(data, "XDG_PICTURES_DIR", home, buf)) |p| return p;
    } else |_| {}
    return std.fmt.bufPrint(buf, "{s}/Pictures", .{home});
}

/// Find `NAME="$HOME/x"` or `NAME="/abs"` in a user-dirs.dirs file.
pub fn parseUserDir(data: []const u8, name: []const u8, home: []const u8, buf: []u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        var rest = std.mem.trimStart(u8, trimmed[name.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len >= 2 and rest[0] == '"') {
            const close = std.mem.lastIndexOfScalar(u8, rest, '"') orelse continue;
            if (close == 0) continue;
            rest = rest[1..close];
        }
        // the file is shell syntax: unescape \" \\ \$ \`
        var tmp: [1024]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len and n < tmp.len) : (i += 1) {
            if (rest[i] == '\\' and i + 1 < rest.len) i += 1;
            tmp[n] = rest[i];
            n += 1;
        }
        const value = tmp[0..n];
        if (std.mem.eql(u8, std.mem.trimEnd(u8, value, "/"), "$HOME")) return null;
        if (std.mem.startsWith(u8, value, "$HOME/"))
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, value["$HOME/".len..] }) catch null;
        if (value.len > 0 and value[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{value}) catch null;
        return null;
    }
    return null;
}

test "user-dirs parsing" {
    var buf: [256]u8 = undefined;
    const data =
        \\# comment
        \\XDG_DESKTOP_DIR="$HOME/Escritorio"
        \\XDG_PICTURES_DIR="$HOME/Im\"ágenes"
        \\
    ;
    try std.testing.expectEqualStrings("/home/u/Im\"ágenes", parseUserDir(data, "XDG_PICTURES_DIR", "/home/u", &buf).?);
    try std.testing.expectEqualStrings("/data/pics", parseUserDir("XDG_PICTURES_DIR=\"/data/pics\"", "XDG_PICTURES_DIR", "/h", &buf).?);
    try std.testing.expect(parseUserDir("XDG_PICTURES_DIR=\"$HOME/\"", "XDG_PICTURES_DIR", "/h", &buf) == null);
    try std.testing.expect(parseUserDir("XDG_PICTURES_DIRX=\"/x\"", "XDG_PICTURES_DIR", "/h", &buf) == null);
}

test "home expansion" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/h/shots", try expandHome(&buf, "/h", "~/shots"));
    try std.testing.expectEqualStrings("/h/shots", try expandHome(&buf, "/h", "$HOME/shots"));
    try std.testing.expectEqualStrings("/h", try expandHome(&buf, "/h", "~"));
    try std.testing.expectEqualStrings("~x/y", try expandHome(&buf, "/h", "~x/y"));
}
