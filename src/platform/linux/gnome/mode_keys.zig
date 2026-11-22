//! The GNOME extension's shortcut per capture mode (its settings keys,
//! mode.shortcuts), set in either notation (GTK's or app/accel.zig's)
//! and shown in the neutral one:
//!
//!     shotlet gnome-integration shortcut MODE [KEY... | none]
//!     shotlet gnome-integration shortcut          (lists them too)

const std = @import("std");
const env_mod = @import("../../../app/env.zig");
const gnome = @import("../gnome.zig");
const gsettings = @import("gsettings.zig");
const mode = @import("../../../app/modes/mode.zig");
const gtk_accel = @import("gtk_accel.zig");
const Env = env_mod.Env;

const gnome_shot_keys = [_][]const u8{ "show-screenshot-ui", "screenshot", "screenshot-window", "show-screen-recording-ui" };

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// The extension's settings key for shortcut `name` (mode.shortcuts).
pub fn settingsKey(buf: []u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "area")) return "capture-shortcut";
    return std.fmt.bufPrint(buf, "{s}-shortcut", .{name}) catch unreachable;
}

/// Shortcuts given on the command line (either notation) as the GVariant
/// string list GNOME keeps; "none" is the empty list.
pub fn userStrv(arena: std.mem.Allocator, keys: []const []const u8) ![]const u8 {
    if (keys.len == 1 and std.mem.eql(u8, keys[0], "none")) return gsettings.formatStrv(arena, &.{});
    const gtk = try arena.alloc([]const u8, keys.len);
    for (keys, gtk) |k, *g| {
        if (k.len == 0 or k.len > 60 or std.mem.indexOfAny(u8, k, "'\"\\\n") != null) return error.BadShortcut;
        const buf = try arena.alloc(u8, 96);
        g.* = gtk_accel.fromUser(k, buf) orelse return error.BadShortcut;
    }
    return gsettings.formatStrv(arena, gtk);
}

/// `MODE KEY...`: set that mode's key; `MODE`: show it.
pub fn cli(gpa: std.mem.Allocator, env: Env, schemadir: []const u8, rest: []const []const u8) !void {
    const sc = mode.shortcutNamed(rest[0]).?;
    const keys = rest[1..];
    if (keys.len > 0) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var kbuf: [32]u8 = undefined;
        try gsettings.set(arena, env, schemadir, gnome.ext_schema_id, settingsKey(&kbuf, sc.name), try userStrv(arena, keys));
    }
    try list(gpa, env, schemadir, sc.name);
}

/// The key one of GNOME's screenshot shortcuts (or the area capture)
/// holds that equals `accel` (GTK's notation), if any.
fn takenBy(arena: std.mem.Allocator, env: Env, schemadir: []const u8, sc: mode.Shortcut, accel: []const u8) ?[]const u8 {
    for (gnome_shot_keys) |k| {
        const v = gsettings.get(arena, env, null, "org.gnome.shell.keybindings", k) catch continue;
        const items = gsettings.parseStrv(arena, v) catch continue;
        for (items) |it| if (gtk_accel.same(it, accel)) return "GNOME's screenshot shortcut";
    }
    if (!std.mem.eql(u8, sc.name, "area")) {
        const v = gsettings.get(arena, env, schemadir, gnome.ext_schema_id, "capture-shortcut") catch return null;
        const items = gsettings.parseStrv(arena, v) catch return null;
        for (items) |it| if (gtk_accel.same(it, accel)) return "the area capture's key";
    }
    return null;
}

/// Every mode's key (or only `only`), and whether it is left unbound.
pub fn list(gpa: std.mem.Allocator, env: Env, schemadir: []const u8, only: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (mode.shortcuts) |sc| {
        if (only) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        var kbuf: [32]u8 = undefined;
        const v = gsettings.get(arena, env, schemadir, gnome.ext_schema_id, settingsKey(&kbuf, sc.name)) catch {
            out("  {s}: (unknown: an older extension)\n", .{sc.name});
            continue;
        };
        const items = gsettings.parseStrv(arena, v) catch &.{};
        if (items.len == 0) {
            out("  {s}: none\n", .{sc.name});
            continue;
        }
        var dbuf: [64]u8 = undefined;
        const shown = gtk_accel.display(&dbuf, items[0]);
        const why = takenBy(arena, env, schemadir, sc, items[0]);
        if (why) |w| out("  {s}: {s} (unbound: it is {s})\n", .{ sc.name, shown, w }) else out("  {s}: {s}\n", .{ sc.name, shown });
    }
}

test "each shortcut's default is the extension's, in GTK's notation" {
    const schema = @embedFile("gnome_ext_schema");
    const accel = @import("../../../app/accel.zig");
    for (mode.shortcuts) |sc| {
        var kbuf: [32]u8 = undefined;
        var gbuf: [64]u8 = undefined;
        var tbuf: [64]u8 = undefined;
        var ebuf: [128]u8 = undefined;
        const tag = try std.fmt.bufPrint(&tbuf, "<key name=\"{s}\"", .{settingsKey(&kbuf, sc.name)});
        const at = std.mem.indexOf(u8, schema, tag).?;
        const def = schema[at..][0..std.mem.indexOf(u8, schema[at..], "</default>").?];
        const gtk = gtk_accel.fromNeutral(accel.parse(sc.default).?, &gbuf).?;
        try std.testing.expect(std.mem.indexOf(u8, def, try xmlEscaped(&ebuf, gtk)) != null or
            std.mem.indexOf(u8, def, gtk) != null);
    }
}

fn xmlEscaped(buf: []u8, s: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
    return w.buffered();
}

test "command-line shortcuts in either notation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("['<Ctrl><Alt>w']", try userStrv(arena, &.{"<Ctrl><Alt>w"}));
    try std.testing.expectEqualStrings("['<Ctrl><Alt>w', '<Super>4']", try userStrv(arena, &.{ "Ctrl+Alt+W", "Super+4" }));
    try std.testing.expectEqualStrings("[]", try userStrv(arena, &.{"none"}));
    try std.testing.expectError(error.BadShortcut, userStrv(arena, &.{"it's"}));
    var kbuf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("capture-shortcut", settingsKey(&kbuf, "area"));
    try std.testing.expectEqualStrings("window-shortcut", settingsKey(&kbuf, "window"));
}
