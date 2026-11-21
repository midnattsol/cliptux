//! Process identity and lifecycle (daemonizing, exit).

const std = @import("std");
const linux = std.os.linux;
const check = @import("common.zig").check;

pub fn getuid() u32 {
    return linux.getuid();
}

pub fn fork() !i32 {
    const rc = linux.fork();
    _ = try check(rc);
    return @intCast(rc);
}

pub fn setsid() void {
    _ = linux.setsid();
}

pub fn chdirRoot() void {
    _ = linux.chdir("/");
}

pub fn exitProcess(code: u8) noreturn {
    linux.exit(code);
}
