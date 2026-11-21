//! Input-method composition (zwp_text_input_v3): committed text becomes
//! key-like events with code 0, preedit changes a `.key` with preedit set
//! (see the top of window.zig).

const std = @import("std");
const wl = @import("../../platform/wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");

const Window = window.Window;
const Key = window.Key;
const Rect = window.Rect;

pub const TextInput = struct {
    /// zwp_text_input_v3; 0 without the protocol
    id: u32 = 0,
    focus: bool = false,
    /// surface index with text-input focus
    surface: u8 = 0,
    /// the caller wants composition (setTextInput) / it is enabled
    want: bool = false,
    enabled: bool = false,
    /// caret rectangle in buffer pixels of the focused surface
    rect: ?Rect = null,
    // commit and preedit strings collected until done
    pending_commit: [512]u8 = undefined,
    pending_commit_len: usize = 0,
    pending_preedit: [256]u8 = undefined,
    pending_preedit_len: usize = 0,
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,
};

/// Bytes of `s` that fit in `max` without splitting a UTF-8 sequence
/// (at least one whole character when s is non-empty, unless malformed).
pub fn utf8Chunk(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    // back up over continuation bytes to a character boundary
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    if (n == 0) {
        // a single character longer than max cannot happen for max >= 4;
        // skip the malformed run instead of looping forever
        n = max;
    }
    return n;
}

/// Create the seat's text input when the protocol is offered.
pub fn ensureObject(w: *Window) !void {
    const mgr = w.globals.ti_manager;
    if (mgr == 0 or w.globals.seat == 0 or w.text_input.id != 0) return;
    w.text_input.id = w.conn.newId();
    try w.conn.request(mgr, wl.zwp_text_input_manager_v3.get_text_input, &.{ .{ .new_id = w.text_input.id }, .{ .object = w.globals.seat } });
}

pub fn destroy(w: *Window) void {
    if (w.text_input.id == 0) return;
    w.conn.request(w.text_input.id, wl.zwp_text_input_v3.destroy, &.{}) catch {};
    w.text_input.id = 0;
}

/// Enable or disable input-method composition. Call with true while
/// the user edits text, passing the caret rectangle in buffer pixels of
/// the focused surface (null keeps the last one); false when editing
/// ends. No-op when the compositor lacks zwp_text_input_manager_v3.
pub fn setTextInput(w: *Window, enabled: bool, cursor_rect: ?Rect) !void {
    const ti = &w.text_input;
    if (cursor_rect) |rc| ti.rect = rc;
    const changed = enabled != ti.want;
    ti.want = enabled;
    if (ti.id == 0 or !ti.focus) return;
    if (!changed and !enabled) return;
    try sendState(w, changed);
}

/// Whether IME composition is available (protocol bound).
pub fn hasTextInput(w: *const Window) bool {
    return w.text_input.id != 0;
}

/// The IME preedit string being composed (empty when none).
pub fn preedit(w: *const Window) []const u8 {
    return w.text_input.preedit_buf[0..w.text_input.preedit_len];
}

fn sendState(w: *Window, reenable: bool) !void {
    const c = &w.conn;
    const ti = &w.text_input;
    if (ti.want) {
        if (reenable or !ti.enabled) {
            try c.request(ti.id, wl.zwp_text_input_v3.enable, &.{});
            ti.enabled = true;
        }
        if (ti.rect) |rc| {
            const f = @as(f64, @floatFromInt(w.surfaces[ti.surface].scale120)) / 120.0;
            const lr = logicalRect(rc, f);
            try c.request(ti.id, wl.zwp_text_input_v3.set_cursor_rectangle, &.{
                .{ .int = lr.x }, .{ .int = lr.y }, .{ .int = lr.w }, .{ .int = lr.h },
            });
        }
    } else if (ti.enabled) {
        try c.request(ti.id, wl.zwp_text_input_v3.disable, &.{});
        ti.enabled = false;
        try setPreedit(w, "");
    }
    try c.request(ti.id, wl.zwp_text_input_v3.commit, &.{});
    try c.flush();
}

fn logicalRect(rc: Rect, f: f64) Rect {
    const d = if (f > 0) f else 1.0;
    return .{
        .x = @intFromFloat(@floor(@as(f64, @floatFromInt(rc.x)) / d)),
        .y = @intFromFloat(@floor(@as(f64, @floatFromInt(rc.y)) / d)),
        .w = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(rc.w)) / d)))),
        .h = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(rc.h)) / d)))),
    };
}

/// zwp_text_input_v3 events.
pub fn handleEvent(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    const ti = &w.text_input;
    switch (opcode) {
        wl.zwp_text_input_v3.ev_enter => {
            ti.focus = true;
            ti.surface = surface.indexOf(w, try r.uint()) orelse 0;
            ti.enabled = false;
            if (ti.want) try sendState(w, true);
        },
        wl.zwp_text_input_v3.ev_leave => {
            ti.focus = false;
            ti.enabled = false;
            try setPreedit(w, "");
        },
        wl.zwp_text_input_v3.ev_preedit_string => {
            const s = try r.string();
            ti.pending_preedit_len = @min(s.len, ti.pending_preedit.len);
            @memcpy(ti.pending_preedit[0..ti.pending_preedit_len], s[0..ti.pending_preedit_len]);
        },
        wl.zwp_text_input_v3.ev_commit_string => {
            const s = try r.string();
            const room = ti.pending_commit.len - ti.pending_commit_len;
            const n = @min(s.len, room);
            @memcpy(ti.pending_commit[ti.pending_commit_len..][0..n], s[0..n]);
            ti.pending_commit_len += n;
        },
        wl.zwp_text_input_v3.ev_done => try onDone(w),
        else => {}, // delete_surrounding_text: no surrounding text is sent
    }
}

/// Apply in protocol order: commit text, then the new preedit (cleared
/// unless one was sent with this done).
fn onDone(w: *Window) !void {
    const ti = &w.text_input;
    try queueText(w, ti.pending_commit[0..ti.pending_commit_len]);
    ti.pending_commit_len = 0;
    try setPreedit(w, ti.pending_preedit[0..ti.pending_preedit_len]);
    ti.pending_preedit_len = 0;
}

/// Queue committed IME text as key-like events (code 0).
fn queueText(w: *Window, s: []const u8) !void {
    var rest = s;
    while (rest.len > 0) {
        var key: Key = .{ .code = 0, .pressed = true, .ctrl = false, .shift = false };
        const n = utf8Chunk(rest, key.text_buf.len);
        @memcpy(key.text_buf[0..n], rest[0..n]);
        key.text_len = @intCast(n);
        try w.queue.append(w.alloc, .{ .key = key });
        rest = rest[n..];
    }
}

fn setPreedit(w: *Window, s: []const u8) !void {
    const ti = &w.text_input;
    if (std.mem.eql(u8, s, preedit(w))) return;
    const n = utf8Chunk(s, ti.preedit_buf.len);
    @memcpy(ti.preedit_buf[0..n], s[0..n]);
    ti.preedit_len = n;
    try w.queue.append(w.alloc, .{ .key = .{ .code = 0, .pressed = false, .ctrl = false, .shift = false, .preedit = true } });
}

test "utf8 chunking never splits a character" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 3), utf8Chunk("abc", 16));
    // 15 ASCII + "ñ" (2 bytes): the ñ must move to the next chunk
    const s = "aaaaaaaaaaaaaaañ";
    try t.expectEqual(@as(usize, 15), utf8Chunk(s, 16));
    // "€" is 3 bytes: 16 bytes of 5 euros + 1 -> 15
    try t.expectEqual(@as(usize, 15), utf8Chunk("€€€€€€", 16));
    // malformed continuation run still makes progress
    const junk: [20]u8 = @splat(0x80);
    try t.expect(utf8Chunk(&junk, 16) > 0);
}

test "caret rectangle converts to logical coordinates" {
    const r = logicalRect(.{ .x = 301, .y = 50, .w = 3, .h = 41 }, 2.0);
    try std.testing.expectEqual(Rect{ .x = 150, .y = 25, .w = 2, .h = 21 }, r);
}

fn testWireString(buf: []u8, s: []const u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], @intCast(s.len + 1), .little);
    @memcpy(buf[4..][0..s.len], s);
    const padded = std.mem.alignForward(usize, s.len + 1, 4);
    @memset(buf[4 + s.len .. 4 + padded], 0);
    return buf[0 .. 4 + padded];
}

test "text-input-v3 events become key-like text and preedit" {
    const t = std.testing;
    var win = Window{ .alloc = t.allocator, .conn = undefined };
    defer win.queue.deinit(t.allocator);
    var buf: [128]u8 = undefined;

    // preedit "n" (composition in progress), applied on done
    var r = wl.ArgReader{ .data = testWireString(&buf, "ñ") };
    try handleEvent(&win, wl.zwp_text_input_v3.ev_preedit_string, &r);
    try t.expectEqual(@as(usize, 0), win.queue.items.len); // nothing before done
    r = .{ .data = &[_]u8{ 1, 0, 0, 0 } };
    try handleEvent(&win, wl.zwp_text_input_v3.ev_done, &r);
    try t.expectEqualStrings("ñ", win.preedit());
    try t.expectEqual(@as(usize, 1), win.queue.items.len);
    const pe = win.queue.items[0].key;
    try t.expect(pe.preedit and !pe.pressed and pe.code == 0 and pe.text_len == 0);
    win.queue.clearRetainingCapacity();

    // commit a long string: split at character boundaries, preedit cleared
    const long = "¿Qué tal, señor? ñandú €€€";
    r = .{ .data = testWireString(&buf, long) };
    try handleEvent(&win, wl.zwp_text_input_v3.ev_commit_string, &r);
    r = .{ .data = &[_]u8{ 2, 0, 0, 0 } };
    try handleEvent(&win, wl.zwp_text_input_v3.ev_done, &r);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(t.allocator);
    var saw_preedit_clear = false;
    for (win.queue.items) |ev| {
        const k = ev.key;
        try t.expectEqual(@as(u32, 0), k.code);
        if (k.preedit) {
            saw_preedit_clear = true;
            continue;
        }
        try t.expect(k.pressed);
        try t.expect(std.unicode.utf8ValidateSlice(k.text()));
        try joined.appendSlice(t.allocator, k.text());
    }
    try t.expectEqualStrings(long, joined.items);
    try t.expect(saw_preedit_clear);
    try t.expectEqualStrings("", win.preedit());

    // malformed payload is an error, not a crash
    r = .{ .data = &[_]u8{ 9, 0, 0, 0, 'x' } };
    try t.expectError(error.Malformed, handleEvent(&win, wl.zwp_text_input_v3.ev_commit_string, &r));
}
