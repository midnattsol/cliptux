//! The `gsettings` tool, for the few GNOME settings Shotlet changes when
//! asked to (`shotlet gnome-integration install|uninstall|shortcut`): the
//! extension's own keys and the custom shortcuts that run shotlet. GVariant
//! text is parsed and written here for strings and string arrays only.

const std = @import("std");
const sys = @import("../platform/sys.zig");
const Env = @import("env.zig").Env;

/// Run `gsettings [--schemadir DIR] ARGS...`; its stdout (owned), or an
/// error when it could not run or failed.
pub fn run(gpa: std.mem.Allocator, env: Env, schemadir: ?[]const u8, args: []const []const u8) ![]u8 {
    const linux = std.os.linux;
    var exe_buf: [1024]u8 = undefined;
    const exe = try findInPath(&exe_buf, env, "gsettings");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.append(arena, "gsettings");
    if (schemadir) |d| {
        try argv.append(arena, "--schemadir");
        try argv.append(arena, try arena.dupeSentinel(u8, d, 0));
    }
    for (args) |a| try argv.append(arena, try arena.dupeSentinel(u8, a, 0));
    try argv.append(arena, null);
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);

    const fds = try sys.pipe();
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        sys.close(fds[0]);
        sys.close(fds[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = linux.dup2(fds[1], 1);
        _ = linux.execve(exe.ptr, argv_z, env.envp);
        linux.exit(127);
    }
    sys.close(fds[1]);
    defer sys.close(fds[0]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(fds[0], &buf) catch break;
        if (n == 0) break;
        if (out.items.len + n > 1024 * 1024) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    var status: i32 = 0;
    while (true) {
        const rc = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(rc) != .INTR) break;
    }
    const st: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(st) or linux.W.EXITSTATUS(st) != 0) return error.GsettingsFailed;
    return out.toOwnedSlice(gpa);
}

fn findInPath(buf: []u8, env: Env, name: []const u8) ![:0]const u8 {
    var path: []const u8 = "/usr/local/bin:/usr/bin:/bin";
    var i: usize = 0;
    while (env.envp[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "PATH=")) path = s[5..];
    }
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue;
        const p = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (std.os.linux.errno(std.os.linux.faccessat(std.os.linux.AT.FDCWD, p.ptr, std.os.linux.X_OK, 0)) == .SUCCESS) return p;
    }
    return error.GsettingsMissing;
}

pub fn get(gpa: std.mem.Allocator, env: Env, schemadir: ?[]const u8, schema: []const u8, key: []const u8) ![]u8 {
    return run(gpa, env, schemadir, &.{ "get", schema, key });
}

pub fn set(gpa: std.mem.Allocator, env: Env, schemadir: ?[]const u8, schema: []const u8, key: []const u8, value: []const u8) !void {
    gpa.free(try run(gpa, env, schemadir, &.{ "set", schema, key, value }));
}

pub fn reset(gpa: std.mem.Allocator, env: Env, schemadir: ?[]const u8, schema: []const u8, key: []const u8) !void {
    gpa.free(try run(gpa, env, schemadir, &.{ "reset", schema, key }));
}

// --- GVariant text

/// A string list as gsettings prints it: "['a', \"b'c\"]" or "@as []".
/// The items are owned by `arena`.
pub fn parseStrv(arena: std.mem.Allocator, text: []const u8) ![][]u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "@as")) s = std.mem.trimStart(u8, s[3..], " ");
    if (s.len < 2 or s[0] != '[' or s[s.len - 1] != ']') return error.BadVariant;
    var items: std.ArrayList([]u8) = .empty;
    var i: usize = 1;
    const end = s.len - 1;
    while (true) {
        while (i < end and s[i] == ' ') i += 1;
        if (i >= end) break;
        const str = try parseQuoted(arena, s, &i);
        try items.append(arena, str);
        while (i < end and s[i] == ' ') i += 1;
        if (i >= end) break;
        if (s[i] != ',') return error.BadVariant;
        i += 1;
    }
    return items.toOwnedSlice(arena);
}

/// One string as gsettings prints it: 'a' or "a'b".
pub fn parseString(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    const out = try parseQuoted(arena, s, &i);
    if (i != s.len) return error.BadVariant;
    return out;
}

fn parseQuoted(arena: std.mem.Allocator, s: []const u8, i: *usize) ![]u8 {
    if (i.* >= s.len) return error.BadVariant;
    const q = s[i.*];
    if (q != '\'' and q != '"') return error.BadVariant;
    i.* += 1;
    var out: std.ArrayList(u8) = .empty;
    while (i.* < s.len) {
        const c = s[i.*];
        i.* += 1;
        if (c == q) return out.toOwnedSlice(arena);
        if (c == '\\') {
            if (i.* >= s.len) return error.BadVariant;
            const e = s[i.*];
            i.* += 1;
            try out.append(arena, switch (e) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => e,
            });
        } else try out.append(arena, c);
    }
    return error.BadVariant;
}

/// Quote a string for gsettings set: 'it\'s'.
pub fn quote(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '\'');
    for (s) |c| {
        if (c == '\'' or c == '\\') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
}

/// "['a', 'b']" (owned).
pub fn formatStrv(gpa: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    for (items, 0..) |it, n| {
        if (n > 0) try out.appendSlice(gpa, ", ");
        try quote(&out, gpa, it);
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

pub fn formatString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try quote(&out, gpa, s);
    return out.toOwnedSlice(gpa);
}

test "string lists round-trip through GVariant text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try parseStrv(arena, "['/org/gnome/custom0/', \"it's\", 'a\\\\b']\n");
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqualStrings("/org/gnome/custom0/", a[0]);
    try std.testing.expectEqualStrings("it's", a[1]);
    try std.testing.expectEqualStrings("a\\b", a[2]);
    try std.testing.expectEqual(@as(usize, 0), (try parseStrv(arena, "@as []\n")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseStrv(arena, "[]")).len);
    try std.testing.expectError(error.BadVariant, parseStrv(arena, "['a' 'b']"));
    try std.testing.expectError(error.BadVariant, parseStrv(arena, "['a"));
    try std.testing.expectEqualStrings("<Super>s", try parseString(arena, "'<Super>s'\n"));
    try std.testing.expectError(error.BadVariant, parseString(arena, "'a' x"));

    const f = try formatStrv(std.testing.allocator, &.{ "Print", "it's", "a\\b" });
    defer std.testing.allocator.free(f);
    try std.testing.expectEqualStrings("['Print', 'it\\'s', 'a\\\\b']", f);
    const back = try parseStrv(arena, f);
    try std.testing.expectEqualStrings("it's", back[1]);
    try std.testing.expectEqualStrings("a\\b", back[2]);
}
