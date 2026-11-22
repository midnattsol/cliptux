//! KWin's windows for app/winrects.zig: a one-off KWin script, loaded
//! through org.kde.kwin.Scripting (open to any session client, unlike
//! ScreenShot2), lists the windows of the current desktop topmost first
//! and calls this connection back with their frames; then it is unloaded.
//! The callback carries a random token only the script (a 0600 file of
//! ours) knows, so nobody else on the bus can pass windows off as KWin's.

const std = @import("std");
const dbus = @import("../../platform/linux/dbus.zig");
const sys = @import("../../platform/linux/sys.zig");
const env_mod = @import("../env.zig");

const iface = "dev.shotlet.WinRects";
const obj_path = "/dev/shotlet/WinRects";

/// KWin 5 and 6 alike: normal windows and dialogs, not minimized, on the
/// current desktop, not Shotlet's own floating windows (titled
/// "shotlet:ROLE").
const script_fmt =
    \\(function () {{
    \\    var out = [];
    \\    var list = workspace.stackingOrder;
    \\    var cur = workspace.currentDesktop;
    \\    var here = function (w) {{
    \\        if (w.onAllDesktops) return true;
    \\        if (w.desktops === undefined) return typeof w.desktop !== "number" || w.desktop === cur;
    \\        for (var k = 0; k < w.desktops.length; k++)
    \\            if (w.desktops[k] === cur || (cur && w.desktops[k].id === cur.id)) return true;
    \\        return false;
    \\    }};
    \\    for (var i = list.length - 1; i >= 0 && out.length < 256; i--) {{
    \\        var w = list[i];
    \\        if (!w || !(w.normalWindow || w.dialog) || w.minimized || w.deleted || !here(w)) continue;
    \\        if (String(w.caption).indexOf("shotlet:") === 0) continue;
    \\        var g = w.frameGeometry;
    \\        out.push(Math.round(g.x), Math.round(g.y), Math.round(g.width), Math.round(g.height));
    \\    }}
    \\    callDBus("{s}", "{s}", "{s}", "Rects", "{s} " + out.join(","));
    \\}})();
    \\
;

/// [x, y, w, h, ...] logical, into `out`; empty when KWin does not
/// answer in time.
pub fn fetch(gpa: std.mem.Allocator, env: env_mod.Env, conn: *dbus.Connection, out: []i32) []const i32 {
    var tok_raw: [8]u8 = undefined;
    sys.getRandom(&tok_raw);
    var tok_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&tok_buf, "{x}", .{std.mem.readInt(u64, &tok_raw, .little)}) catch return &.{};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/shotlet-windows-{s}.js", .{ env.runtime_dir, token }) catch return &.{};
    var src_buf: [2048]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, script_fmt, .{ conn.unique_name, obj_path, iface, token }) catch return &.{};
    sys.writeFileExclusive(path, src, 0o600) catch return &.{};
    defer sys.unlink(path) catch {};
    var name_buf: [48]u8 = undefined;
    const plugin = std.fmt.bufPrint(&name_buf, "shotlet-windows-{s}", .{token}) catch return &.{};
    const id = loadScript(gpa, conn, path, plugin) catch |err| {
        std.log.info("windows: KWin scripting unavailable ({t})", .{err});
        return &.{};
    };
    defer unload(gpa, conn, plugin);
    runScript(gpa, conn, id) catch |err| {
        std.log.info("windows: KWin did not run the script ({t})", .{err});
        return &.{};
    };
    return awaitRects(gpa, conn, token, out);
}

/// Scripting.loadScript(path, plugin): the script's id.
fn loadScript(gpa: std.mem.Allocator, conn: *dbus.Connection, path: []const u8, plugin: []const u8) !i32 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(path);
    try m.putString(plugin);
    var reply = try callKwin(gpa, conn, "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", m.buf.items);
    defer reply.deinit(gpa);
    var r = reply.reader();
    const id: i32 = @bitCast(try r.readU32());
    if (id < 0) return error.NotLoaded;
    return id;
}

/// Run script `id`: /Scripting/ScriptN on KWin 6, /N on KWin 5.
fn runScript(gpa: std.mem.Allocator, conn: *dbus.Connection, id: i32) !void {
    var buf: [48]u8 = undefined;
    for ([_]bool{ true, false }) |kwin6| {
        const obj = if (kwin6) try std.fmt.bufPrint(&buf, "/Scripting/Script{d}", .{id}) else try std.fmt.bufPrint(&buf, "/{d}", .{id});
        var reply = callKwin(gpa, conn, obj, "org.kde.kwin.Script", "run", "", &.{}) catch continue;
        reply.deinit(gpa);
        return;
    }
    return error.NoScriptObject;
}

fn unload(gpa: std.mem.Allocator, conn: *dbus.Connection, plugin: []const u8) void {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(plugin) catch return;
    var reply = callKwin(gpa, conn, "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", m.buf.items) catch return;
    reply.deinit(gpa);
}

/// A call to KWin; an error reply is an error.
fn callKwin(gpa: std.mem.Allocator, conn: *dbus.Connection, path: []const u8, interface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !dbus.Message {
    const serial = try conn.callMethod("org.kde.KWin", path, interface, member, sig, body);
    var reply = try conn.waitReplyOrError(serial, 1000);
    if (reply.type == .@"error") {
        reply.deinit(gpa);
        return error.Refused;
    }
    return reply;
}

/// The script's call back, with our token; other messages are put back.
fn awaitRects(gpa: std.mem.Allocator, conn: *dbus.Connection, token: []const u8, out: []i32) []const i32 {
    const deadline = sys.monoMs() + 1000;
    var skipped: std.ArrayList(dbus.Message) = .empty;
    defer {
        for (skipped.items) |msg| conn.pending.append(gpa, msg) catch {
            var mm = msg;
            mm.deinit(gpa);
        };
        skipped.deinit(gpa);
    }
    while (true) {
        var msg = (conn.nextMessageDeadline(deadline) catch return &.{}) orelse {
            std.log.info("windows: KWin's script did not answer", .{});
            return &.{};
        };
        if (!msg.isCall(iface, "Rects")) {
            skipped.append(gpa, msg) catch msg.deinit(gpa);
            continue;
        }
        defer msg.deinit(gpa);
        conn.replyTo(&msg, "", &.{}) catch {};
        var r = msg.reader();
        const s = r.readString() catch return &.{};
        if (parse(s, token, out)) |flat| return flat;
    }
}

/// "TOKEN x,y,w,h,..." into `out`; null when the token is not ours.
pub fn parse(s: []const u8, token: []const u8, out: []i32) ?[]const i32 {
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse return null;
    if (!std.mem.eql(u8, s[0..sp], token)) return null;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s[sp + 1 ..], ',');
    while (it.next()) |v| {
        if (n == out.len) break;
        out[n] = std.fmt.parseInt(i32, v, 10) catch return out[0 .. n / 4 * 4];
        n += 1;
    }
    return out[0 .. n / 4 * 4];
}

test "the script's answer counts only with our token" {
    var out: [8]i32 = undefined;
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, parse("ab12 1,2,3,4,5", "ab12", &out).?);
    try std.testing.expect(parse("zz 1,2,3,4", "ab12", &out) == null);
    try std.testing.expectEqual(@as(usize, 0), parse("ab12 ", "ab12", &out).?.len);
    try std.testing.expectEqual(@as(usize, 8), parse("t 1,2,3,4,5,6,7,8,9,10,11,12", "t", &out).?.len);
}

test "the script is filled in" {
    var buf: [2048]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, script_fmt, .{ ":1.42", obj_path, iface, "beef" });
    try std.testing.expect(std.mem.indexOf(u8, s, "callDBus(\":1.42\", \"/dev/shotlet/WinRects\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"beef \" + out.join") != null);
}
