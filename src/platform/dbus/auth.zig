//! SASL handshake: AUTH EXTERNAL with our uid, then fd-passing negotiation.

const std = @import("std");
const sys = @import("../sys.zig");

/// Run the client side of the handshake on a freshly connected socket,
/// finishing with BEGIN. Each reply must arrive within `timeout_ms` of
/// sending AUTH. Returns whether the bus agreed to pass unix fds.
pub fn authenticate(fd: sys.fd_t, timeout_ms: i64) !bool {
    var msg: [64]u8 = undefined;
    try sys.writeAll(fd, try authExternalCommand(&msg));

    // read one line: "OK <guid>\r\n"
    const deadline = sys.monoMs() + timeout_ms;
    var line: [512]u8 = undefined;
    if (!std.mem.startsWith(u8, try readLine(fd, &line, deadline), "OK ")) return error.AuthFailed;

    // negotiate fd passing (needed for portal OpenPipeWireRemote)
    try sys.writeAll(fd, "NEGOTIATE_UNIX_FD\r\n");
    const unix_fd_ok = std.mem.startsWith(u8, try readLine(fd, &line, deadline), "AGREE_UNIX_FD");
    try sys.writeAll(fd, "BEGIN\r\n");
    return unix_fd_ok;
}

/// "\0AUTH EXTERNAL <hex of decimal uid>\r\n" formatted into `out`.
fn authExternalCommand(out: *[64]u8) ![]const u8 {
    var uidbuf: [16]u8 = undefined;
    const uidstr = try std.fmt.bufPrint(&uidbuf, "{d}", .{sys.getuid()});
    var hexbuf: [32]u8 = undefined;
    var hexlen: usize = 0;
    for (uidstr) |c| {
        _ = try std.fmt.bufPrint(hexbuf[hexlen..], "{x:0>2}", .{c});
        hexlen += 2;
    }
    return std.fmt.bufPrint(out, "\x00AUTH EXTERNAL {s}\r\n", .{hexbuf[0..hexlen]});
}

/// Read one CRLF-terminated line byte by byte (nothing past it may be
/// consumed: binary messages follow BEGIN).
fn readLine(fd: sys.fd_t, line: []u8, deadline: i64) ![]const u8 {
    var n: usize = 0;
    while (true) {
        if (!try sys.waitReadable(fd, deadline)) return error.Timeout;
        const r = try sys.read(fd, line[n .. n + 1]);
        if (r == 0) return error.AuthFailed;
        n += 1;
        if (n >= 2 and line[n - 2] == '\r' and line[n - 1] == '\n') return line[0..n];
        if (n >= line.len) return error.AuthFailed;
    }
}
