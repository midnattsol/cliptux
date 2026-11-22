//! The parser against the real command table.

const std = @import("std");
const parse = @import("parse.zig");
const t = std.testing;

var arena_state: std.heap.ArenaAllocator = undefined;

fn run(args: []const [:0]const u8) !parse.Outcome {
    return parse.parse(arena_state.allocator(), args);
}

fn setup() void {
    arena_state = .init(t.allocator);
}

fn expectRest(out: parse.Outcome, want: []const []const u8) !void {
    try t.expectEqual(want.len, out.run.rest.len);
    for (want, out.run.rest) |a, b| try t.expectEqualStrings(a, b);
}

test "no arguments: the default capture" {
    setup();
    defer arena_state.deinit();
    const o = try run(&.{});
    try t.expectEqual(.shot, o.run.id());
}

test "long options: --opt value and --opt=value, in order" {
    setup();
    defer arena_state.deinit();
    const a = try run(&.{ "record", "--gif", "--fps", "12", "--region=1,2,3,4" });
    try t.expectEqual(.record, a.run.id());
    try expectRest(a, &.{ "--gif", "--fps", "12", "--region", "1,2,3,4" });
    try t.expectEqualStrings("12", a.run.value("fps").?);
    try t.expect(a.run.flag("gif") and !a.run.flag("mp4"));
}

test "short options and aliases" {
    setup();
    defer arena_state.deinit();
    const a = try run(&.{ "--daemon", "-f" });
    try t.expectEqual(.daemon, a.run.id());
    try t.expect(a.run.flag("foreground"));
    const b = try run(&.{ "daemon", "--foreground" });
    try t.expect(b.run.flag("foreground"));
    try t.expectEqual(.unknown_option, (try run(&.{ "daemon", "-x" })).fail.kind);
}

test "-- ends the options" {
    setup();
    defer arena_state.deinit();
    const a = try run(&.{ "edit", "--", "--odd-name.png" });
    try t.expectEqual(.edit, a.run.id());
    try t.expectEqualStrings("--odd-name.png", a.run.positionals[0]);
    try t.expectEqual(.extra_arg, (try run(&.{ "pin", "--", "a.png", "b.png" })).fail.kind);
}

test "subcommands and their options" {
    setup();
    defer arena_state.deinit();
    const a = try run(&.{ "permissions", "reset", "--dry-run" });
    try t.expectEqual(.permissions_reset, a.run.id());
    try t.expect(a.run.flag("dry-run"));
    try t.expectEqual(.permissions, (try run(&.{"permissions"})).run.id());
    try t.expectEqual(.history_clear, (try run(&.{ "history", "clear" })).run.id());
    const s = try run(&.{ "gnome-integration", "shortcut", "window", "Super+W" });
    try t.expectEqual(.gnome_shortcut, s.run.id());
    try expectRest(s, &.{ "window", "Super+W" });
    const f = (try run(&.{ "permissions", "rest" })).fail;
    try t.expectEqual(.unknown_command, f.kind);
    try t.expectEqualStrings("reset", f.suggestion.?);
}

test "help, at any level" {
    setup();
    defer arena_state.deinit();
    try t.expectEqual(.overview, std.meta.activeTag(try run(&.{"--help"})));
    try t.expectEqual(.overview, std.meta.activeTag(try run(&.{"-h"})));
    try t.expectEqual(.overview, std.meta.activeTag(try run(&.{"help"})));
    try t.expectEqual(.version, std.meta.activeTag(try run(&.{"-V"})));
    const a = try run(&.{ "permissions", "--help" });
    try t.expectEqualStrings("permissions", a.help.leaf().?.name);
    const b = try run(&.{ "gnome-integration", "install", "-h" });
    try t.expectEqualStrings("install", b.help.leaf().?.name);
    try t.expectEqual(@as(usize, 2), b.help.len);
    const c = try run(&.{ "help", "permissions", "reset" });
    try t.expectEqualStrings("reset", c.help.leaf().?.name);
    try t.expectEqual(.unknown_command, (try run(&.{ "help", "nope" })).fail.kind);
}

test "unknown commands and options, with suggestions" {
    setup();
    defer arena_state.deinit();
    const a = (try run(&.{"screnshot"})).fail;
    try t.expectEqual(.unknown_command, a.kind);
    const b = (try run(&.{"setings"})).fail;
    try t.expectEqualStrings("settings", b.suggestion.?);
    const c = (try run(&.{ "record", "--secnds", "3" })).fail;
    try t.expectEqual(.unknown_option, c.kind);
    try t.expectEqualStrings("--seconds", c.suggestion.?);
    try t.expectEqual(.unknown_option, (try run(&.{"--bogus"})).fail.kind);
    // plumbing options are accepted but never suggested
    try t.expectEqual(@as(?[]const u8, null), (try run(&.{ "shot", "--mod" })).fail.suggestion);
}

test "values are checked" {
    setup();
    defer arena_state.deinit();
    try t.expectEqual(.missing_value, (try run(&.{ "record", "--region" })).fail.kind);
    try t.expectEqual(.bad_value, (try run(&.{ "record", "--seconds", "soon" })).fail.kind);
    try t.expectEqual(.bad_value, (try run(&.{ "record", "--format", "avi" })).fail.kind);
    try t.expectEqual(.bad_value, (try run(&.{ "fullscreen", "--delay", "99" })).fail.kind);
    try t.expectEqual(.unexpected_value, (try run(&.{ "record", "--gif=yes" })).fail.kind);
    try t.expectEqual(.missing_arg, (try run(&.{"edit"})).fail.kind);
    try t.expectEqual(.extra_arg, (try run(&.{ "settings", "now" })).fail.kind);
}

test "the invocations Shotlet, its extension and the e2e suites use" {
    setup();
    defer arena_state.deinit();
    const ext = try run(&.{ "--from-shell", "7", "--monitors", "0,0,1920,1080,1", "--pieces", "x", "--t0", "123", "--mode", "window", "--pointer", "-20,300", "--then", "record" });
    try t.expectEqual(.shot, ext.run.id());
    try t.expect(ext.run.shell_launch);
    try expectRest(ext, &.{ "--from-shell", "7", "--monitors", "0,0,1920,1080,1", "--pieces", "x", "--t0", "123", "--mode", "window", "--pointer", "-20,300", "--then", "record" });
    const tm = try run(&.{ "timer", "3" });
    try expectRest(tm, &.{"3"});
    try t.expectEqual(.text, (try run(&.{ "text", "--from", "a.png" })).run.id());
    try t.expectEqual(.shot, (try run(&.{ "shot", "--from", "a.png", "--sel", "0,0,10,10", "--smoke", "1500" })).run.id());
    try t.expectEqual(.edit, (try run(&.{ "edit", "/root", "20250101-1" })).run.id());
    const trim = try run(&.{ "trim", "/root", "id", "--range", "1000,2500", "--export" });
    try expectRest(trim, &.{ "/root", "id", "--range", "1000,2500", "--export" });
    try t.expectEqual(.gnome_install, (try run(&.{ "gnome-integration", "install" })).run.id());
    try t.expectEqual(.gnome_shortcut, (try run(&.{ "gnome-integration", "shortcut", "screens", "none" })).run.id());
    const rec = try run(&.{ "record", "--region", "200,150,480,320", "--seconds", "4", "--no-countdown", "--no-control", "--clicks", "--keys", "--mic", "--system-audio" });
    try t.expectEqual(.record, rec.run.id());
    try t.expectEqual(.settings, (try run(&.{ "settings", "--smoke", "800" })).run.id());
}
