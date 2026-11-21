//! The Settings window's capture permissions: the capture row's line
//! (the path now and the last capture's) and Reset permissions, which
//! does what `shotlet permissions reset` does (app/perms/reset.zig) and
//! shows a short line about it.

const std = @import("std");
const capture_path = @import("../../app/capture_path.zig");
const reset = @import("../../app/perms/reset.zig");
const model = @import("model.zig");
const w = @import("widgets.zig");
const App = @import("app.zig").App;

/// The line about the last reset.
pub const Note = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn text(n: *const Note) ?[]const u8 {
        return if (n.len > 0) n.buf[0..n.len] else null;
    }

    fn set(n: *Note, s: []const u8) void {
        n.len = @min(s.len, n.buf.len);
        @memcpy(n.buf[0..n.len], s[0..n.len]);
    }
};

/// The capture row's line: how captures go now, and how the last went.
pub fn captureLine(st: *const model.State, buf: []u8) []const u8 {
    const now = if (st.capture.capture) "Through the GNOME integration (no prompts)" else "Through the screen-sharing portal";
    const last = st.last_path orelse return now;
    const how = switch (last) {
        .gnome => "the GNOME integration",
        .direct => "directly",
        .portal => "the portal",
    };
    return std.fmt.bufPrint(buf, "{s}; last capture: {s}", .{ now, how }) catch now;
}

/// The Reset permissions row.
pub fn drawRow(ui: *w.Ui, card: *w.Card, row_h: i32, note: *const Note) !void {
    const r = w.rowBegin(ui, card, row_h);
    w.rowTitle(ui, r, "Permissions", note.text() orelse "Forget them: the next capture asks again");
    try w.chipButton(ui, r, .reset_permissions, null, "Reset permissions", false);
}

/// Reset: forget the restore token and Shotlet's portal permissions.
pub fn resetAll(app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const o = reset.run(arena_state.allocator(), app.st.env, app.busPtr(), false);
    // the window's copy of the config must not write the token back
    app.cfg.setScToken("");
    var buf: [96]u8 = undefined;
    app.st.perm_note.set(reset.summary(o, &buf));
    std.log.info("permissions reset from Settings: {s}", .{app.st.perm_note.text().?});
    app.st.dirty = true;
}
