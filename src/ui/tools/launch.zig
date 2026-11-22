//! How the editor was started, set by the command before it runs (the
//! editor is opened from several places; these few settings ride along).

const Env = @import("../../app/env.zig").Env;

/// the process environment (to start `shotlet pin` and the like)
pub var env: ?Env = null;
/// `shotlet text`: select a region, its text goes to the clipboard
pub var text_capture = false;
/// start with the whole picture selected (an opened file)
pub var select_all = false;

const std = @import("std");
const sys = @import("../../platform/linux/sys.zig");

/// With the GNOME integration the shell takes the screenshot and starts a
/// new shotlet on it: a text capture leaves a note for that one.
fn notePath(buf: []u8, runtime_dir: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet-next-capture", .{runtime_dir});
}

pub fn handOff(runtime_dir: []const u8) void {
    if (!text_capture) return;
    var buf: [512]u8 = undefined;
    const path = notePath(&buf, runtime_dir) catch return;
    var line: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "text {d}\n", .{sys.monoMs()}) catch return;
    sys.unlink(path) catch {};
    sys.writeFileExclusive(path, s, 0o600) catch {};
}

/// The note, when fresh (the last few seconds), sets the mode.
pub fn takeHandOff(runtime_dir: []const u8) void {
    var buf: [512]u8 = undefined;
    const path = notePath(&buf, runtime_dir) catch return;
    // no allocator: a FixedBufferAllocator smaller than an ArrayList's
    // first growth (a cache line, 128 bytes on x86_64) failed every read
    var mem: [64]u8 = undefined;
    const data = sys.readFileBuf(path, &mem) catch return;
    sys.unlink(path) catch {};
    if (parseNote(data, sys.monoMs())) text_capture = true;
}

fn parseNote(data: []const u8, now: i64) bool {
    var it = std.mem.tokenizeAny(u8, data, " \n");
    if (!std.mem.eql(u8, it.next() orelse return false, "text")) return false;
    const t = std.fmt.parseInt(i64, it.next() orelse return false, 10) catch return false;
    return now - t >= 0 and now - t < 10_000;
}

test "a text capture's note reaches the shotlet the shell starts" {
    const gpa = std.testing.allocator;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-test");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    defer text_capture = false;
    text_capture = true;
    handOff(dir);
    text_capture = false;
    takeHandOff(dir);
    try std.testing.expect(text_capture);
    // taken once: the next shell capture is a plain one
    text_capture = false;
    takeHandOff(dir);
    try std.testing.expect(!text_capture);
}

test "a capture note is honoured only while fresh" {
    try std.testing.expect(parseNote("text 1000\n", 5000));
    try std.testing.expect(!parseNote("text 1000\n", 20000));
    try std.testing.expect(!parseNote("edit 1000\n", 1500));
    try std.testing.expect(!parseNote("text x", 1500));
}
