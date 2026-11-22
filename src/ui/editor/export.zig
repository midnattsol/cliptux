//! The result: the selection exported (with beautify) as pixels or a
//! PNG, copied to the clipboard; and the dev frame/export dumps.

const std = @import("std");
const editor = @import("../editor.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/sys.zig");
const doc_mod = @import("../doc.zig");
const tools = @import("../tools/mod.zig");
const session = @import("session.zig");
const history = @import("history.zig");
const commands = @import("commands.zig");

const Editor = editor.Editor;

fn exportPixels(ed: *Editor) !doc_mod.Exported {
    try history.settle(ed);
    return tools.exportPixels(ed);
}

pub fn exportPng(ed: *Editor) ![]u8 {
    const exported = try exportPixels(ed);
    defer ed.alloc.free(exported.pixels);
    // RGBA only for a transparent beautify background; everything else
    // stays RGB as before
    const see_through = ed.beautify.enabled and ed.beautify.background().transparent();
    return png.encodeWith(ed.alloc, exported.pixels, exported.width, exported.height, .{ .alpha = if (see_through or ed.keep_alpha) .auto else .never });
}

pub fn copyToClipboard(ed: *Editor) !void {
    const exported = try exportPixels(ed);
    ed.win.setClipboardImage(exported.pixels, exported.width, exported.height) catch |err| {
        ed.alloc.free(exported.pixels);
        std.log.warn("copy failed: {t}", .{err});
        showCopyNotice(ed, .failed, 2400);
        return;
    };
    // like Flameshot, GNOME and CleanShot's overlay: copying finishes
    commands.finish(ed, .copied);
}

/// Show `notice` for `duration_ms`.
fn showCopyNotice(ed: *Editor, notice: editor.CopyNotice, duration_ms: i64) void {
    ed.copy_notice = notice;
    ed.copy_notice_hide_at_ms = session.nowMs() + duration_ms;
    ed.needs_render = true;
}

// --- dev hooks: frame dumps ---

/// SHOTLET_EDITOR_DUMP: every pane's last frame and the export.
pub fn dumpAtExit(ed: *Editor, prefix: []const u8) void {
    var buf: [1024]u8 = undefined;
    for (0..ed.n_panes) |i| {
        ed.pane_i = @intCast(i);
        const frame_path = (if (i == 0)
            std.fmt.bufPrint(&buf, "{s}-frame.png", .{prefix})
        else
            std.fmt.bufPrint(&buf, "{s}-frame-{d}.png", .{ prefix, i })) catch return;
        dumpFrame(ed, frame_path);
    }
    var buf2: [1024]u8 = undefined;
    const export_path = std.fmt.bufPrint(&buf2, "{s}-export.png", .{prefix}) catch return;
    dumpExport(ed, export_path);
}

/// The current pane's last frame as a PNG at `path`.
pub fn dumpFrame(ed: *Editor, path: []const u8) void {
    if (ed.pn().last_frame.len == 0) return;
    const data = png.encode(ed.alloc, ed.pn().last_frame, ed.pn().width, ed.pn().height) catch return;
    defer ed.alloc.free(data);
    sys.writeFile(path, data) catch |e| std.log.warn("dump {s}: {t}", .{ path, e });
}

/// The export as a PNG at `path`.
pub fn dumpExport(ed: *Editor, path: []const u8) void {
    const data = exportPng(ed) catch return;
    defer ed.alloc.free(data);
    sys.writeFile(path, data) catch |e| std.log.warn("dump {s}: {t}", .{ path, e });
}
