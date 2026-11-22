//! `shotlet thumbnail`: the floating thumbnail of the last capture or
//! recording kept, again (from the history, or the thumbnail's cache
//! when the history is off), whatever the thumbnail setting says.

const std = @import("std");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const keep = @import("keep.zig");
const sys = @import("../platform/sys.zig");
const keepvid = @import("../record/keepvid.zig");
const Env = env_mod.Env;

pub fn run(gpa: std.mem.Allocator, env: Env) !void {
    const cfg = config.load(gpa, env.home);
    var root_buf: [1024]u8 = undefined;
    const root = try keep.rootFor(&cfg, env, &root_buf);
    const entries = try history.list(gpa, root);
    defer history.freeList(gpa, entries);
    if (entries.len == 0) {
        sys.writeAll(2, "shotlet: no capture kept yet\n") catch {};
        std.process.exit(1);
    }
    const id = entries[0].id.slice();
    std.log.info("thumbnail: {s} again", .{id});
    if (keepvid.read(gpa, root, id)) |v| {
        gpa.free(v.buf);
        return @import("../record/quickvid.zig").run(gpa, env, root, id);
    }
    return @import("quick.zig").run(gpa, env, root, id, null);
}
