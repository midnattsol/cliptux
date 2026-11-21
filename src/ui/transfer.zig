//! Clipboard and drag-and-drop payloads: bounded reads from a data
//! offer's pipe, the types a dragged capture offers, file URI lists.

const std = @import("std");
const sys = @import("../platform/sys.zig");

/// Read `fd` until EOF, `max_bytes` or the deadline, whichever comes
/// first; a cut never splits a UTF-8 sequence. Caller owns the bytes.
pub fn readBounded(alloc: std.mem.Allocator, fd: sys.fd_t, max_bytes: usize, deadline_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (out.items.len < max_bytes) {
        if (!try sys.waitReadable(fd, deadline_ms)) break; // timed out
        const n = try sys.read(fd, buf[0..@min(buf.len, max_bytes - out.items.len)]);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    if (out.items.len == max_bytes) {
        // drop a trailing partial character
        var i = out.items.len;
        while (i > 0 and (out.items[i - 1] & 0xC0) == 0x80) i -= 1;
        if (i > 0 and out.items[i - 1] >= 0xC0) {
            const need = std.unicode.utf8ByteSequenceLength(out.items[i - 1]) catch 1;
            if (out.items.len - (i - 1) < need) out.shrinkRetainingCapacity(i - 1);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "bounded reads stop at EOF, the size limit and the deadline" {
    const alloc = std.testing.allocator;
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    try sys.writeAll(fds[1], "ab\xc3\xb1cd"); // "abñcd"
    // limit cuts inside "ñ": the partial character is dropped
    const cut = try readBounded(alloc, fds[0], 3, sys.monoMs() + 1000);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("ab", cut);
    // nothing more arrives and the writer stays open: the deadline ends it
    const rest = try readBounded(alloc, fds[0], 100, sys.monoMs() + 50);
    defer alloc.free(rest);
    try std.testing.expectEqualStrings("\xb1cd", rest);
    sys.close(fds[1]);
    const eof = try readBounded(alloc, fds[0], 100, sys.monoMs() + 1000);
    defer alloc.free(eof);
    try std.testing.expectEqual(@as(usize, 0), eof.len);
}

/// MIME types a dragged image offers, best first.
pub const drag_mimes = [_][]const u8{ "image/png", "text/uri-list" };

/// Which payload answers a request for `mime` (null: not offered).
pub fn dragPayloadFor(mime: []const u8) ?enum { png, uri_list } {
    if (std.mem.eql(u8, mime, "image/png")) return .png;
    if (std.mem.eql(u8, mime, "text/uri-list")) return .uri_list;
    return null;
}

/// text/uri-list body for a local file: file:// URI with every byte
/// outside RFC 3986's unreserved set and '/' percent-encoded, CRLF ended.
pub fn fileUriList(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        if (plain) try out.append(alloc, c) else try out.print(alloc, "%{X:0>2}", .{c});
    }
    try out.appendSlice(alloc, "\r\n");
    return out.toOwnedSlice(alloc);
}

test "drag MIME types map to their payloads" {
    const t = std.testing;
    try t.expectEqual(.png, dragPayloadFor("image/png").?);
    try t.expectEqual(.uri_list, dragPayloadFor("text/uri-list").?);
    try t.expect(dragPayloadFor("text/plain") == null);
    try t.expect(dragPayloadFor("image/png;x") == null);
    try t.expect(dragPayloadFor("") == null);
    for (drag_mimes) |m| try t.expect(dragPayloadFor(m) != null);
    const u = try fileUriList(t.allocator, "/home/a b/Imágenes/shot#1.png");
    defer t.allocator.free(u);
    try t.expectEqualStrings("file:///home/a%20b/Im%C3%A1genes/shot%231.png\r\n", u);
}
