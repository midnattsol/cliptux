//! DBus server address lists (DBUS_SESSION_BUS_ADDRESS).

const std = @import("std");

/// One transport from a DBus address list.
pub const Address = union(enum) {
    path: []const u8,
    abstract: []const u8,
};

/// Parse a DBus server address list ("unix:path=/run/user/1000/bus;
/// unix:abstract=/tmp/dbus-x,guid=..."), percent-decoding values into
/// `buf`. Returns the unix transports in order; other transports (tcp,
/// launchd, ...) are skipped.
pub fn parseAddresses(addr: []const u8, buf: []u8, out: []Address) ![]Address {
    var n: usize = 0;
    var used: usize = 0;
    var entries = std.mem.splitScalar(u8, addr, ';');
    while (entries.next()) |entry| {
        if (n == out.len) break;
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
        if (!std.mem.eql(u8, entry[0..colon], "unix")) continue;
        if (parseUnixEntry(entry[colon + 1 ..], buf, &used)) |a| {
            out[n] = a;
            n += 1;
        }
    }
    return out[0..n];
}

/// First usable path= or abstract= key of a unix entry's key=value list,
/// decoded into buf[used.*..] (`used` advances past the decoded bytes).
fn parseUnixEntry(kv_list: []const u8, buf: []u8, used: *usize) ?Address {
    var kvs = std.mem.splitScalar(u8, kv_list, ',');
    while (kvs.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const is_path = std.mem.eql(u8, key, "path");
        const is_abstract = std.mem.eql(u8, key, "abstract");
        if (!is_path and !is_abstract) continue;
        const value = unescapeAddressValue(kv[eq + 1 ..], buf[used.*..]) catch continue;
        used.* += value.len;
        if (value.len == 0) continue;
        return if (is_path) .{ .path = value } else .{ .abstract = value };
    }
    return null;
}

fn unescapeAddressValue(v: []const u8, out: []u8) ![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (n == out.len) return error.AddressTooLong;
        if (v[i] == '%') {
            if (i + 2 >= v.len) return error.BadAddress;
            const hi = std.fmt.charToDigit(v[i + 1], 16) catch return error.BadAddress;
            const lo = std.fmt.charToDigit(v[i + 2], 16) catch return error.BadAddress;
            out[n] = hi * 16 + lo;
            i += 2;
        } else {
            out[n] = v[i];
        }
        n += 1;
    }
    return out[0..n];
}

test "bus address lists, abstract sockets and escapes" {
    var buf: [512]u8 = undefined;
    var out: [8]Address = undefined;
    const got = try parseAddresses(
        "tcp:host=x,port=1;unix:abstract=/tmp/dbus-AbC,guid=12;unix:path=/run/user/1000/My%20Bus,guid=34;unix:path=/bad%2",
        &buf,
        &out,
    );
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/tmp/dbus-AbC", got[0].abstract);
    try std.testing.expectEqualStrings("/run/user/1000/My Bus", got[1].path);

    const none = try parseAddresses("tcp:host=localhost;garbage", &buf, &out);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
