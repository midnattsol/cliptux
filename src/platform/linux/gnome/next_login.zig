//! A freshly copied extension the running GNOME Shell does not know yet:
//! EnableExtension does nothing for it, so put it in
//! org.gnome.shell enabled-extensions here (it loads at the next login),
//! make sure GNOME will load user extensions at all (asked), point it at
//! this binary, and record the shortcut answer for the setup that
//! finishes once it runs (pending_setup.zig). Messages go to stderr.

const std = @import("std");
const Env = @import("../../../app/env.zig").Env;
const extension = @import("extension.zig");
const shell_settings = @import("shell_settings.zig");
const pending_setup = @import("pending_setup.zig");
const ask = @import("ask.zig");
const setup = @import("setup.zig");

const out = std.debug.print;

pub fn prepare(gpa: std.mem.Allocator, env: Env, answer: ask.Answer) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    addToEnabled(arena, env);
    userExtensions(arena, env, answer);
    pointAtThisBinary(gpa, arena, env);
    const move = ask.resolve(answer, "Once it loads, give it the Print key (and custom shortcuts that run shotlet)?");
    pending_setup.record(env.home, move);
}

fn addToEnabled(arena: std.mem.Allocator, env: Env) void {
    if (shell_settings.enable(arena, env)) |changed| {
        if (changed) out("Added {s} to GNOME's enabled extensions.\n", .{extension.uuid});
    } else |err| out("Could not add it to GNOME's enabled extensions ({t}):\n" ++
        "  gnome-extensions enable {s}  (after logging in again)\n", .{ err, extension.uuid });
}

/// GNOME loads no user extension while disable-user-extensions is on.
fn userExtensions(arena: std.mem.Allocator, env: Env, answer: ask.Answer) void {
    if (!shell_settings.userExtensionsOff(arena, env)) return;
    out("GNOME has user extensions turned off, so the integration would not load.\n", .{});
    if (!ask.resolve(answer, "Turn user extensions on?")) {
        out("Left off: gsettings set org.gnome.shell disable-user-extensions false turns them on.\n", .{});
        return;
    }
    shell_settings.turnUserExtensionsOn(arena, env) catch |err| {
        out("Could not turn them on ({t}).\n", .{err});
        return;
    };
    out("Turned user extensions on.\n", .{});
}

/// The extension starts this shotlet once it loads.
fn pointAtThisBinary(gpa: std.mem.Allocator, arena: std.mem.Allocator, env: Env) void {
    var sd_buf: [1100]u8 = undefined;
    const sd = extension.schemaDir(gpa, env, null, &sd_buf) catch return;
    var exe_buf: [1024]u8 = undefined;
    setup.pointAt(arena, env, sd, setup.selfExe(&exe_buf) catch "") catch |err|
        std.log.info("could not point the extension at this binary yet ({t})", .{err});
}
