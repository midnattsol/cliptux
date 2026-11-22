//! The magnifier's keys and wheel (editor_ui/loupe.zig): while it shows
//! in the capture screen, C copies the pixel's colour as `#RRGGBB` (the
//! label says so), and the wheel or - = zoom it (the colour picker's
//! lens zooms too). C is matched like the mode strip's letters, by the
//! key's place (where a US layout has it). While the magnifier shows it
//! wins over C for crop: there is no selection to crop yet, or one is
//! being dragged.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const config = @import("../../app/config.zig");
const ui = @import("../editor_ui.zig");
const color = @import("../tools/color.zig");

const Editor = editor.Editor;

/// A key while the magnifier shows. True when taken.
pub fn onKey(ed: *Editor, k: window.Key) !bool {
    if (k.ctrl or k.alt or !ui.loupeWanted(ed)) return false;
    switch (k.code) {
        .c => {
            if (k.shift or !ui.loupeCapturing(ed)) return false;
            try copy(ed);
        },
        .minus, .kp_minus => zoomBy(ed, -1),
        .equal, .kp_plus => zoomBy(ed, 1),
        else => return false,
    }
    return true;
}

/// Wheel notches while the magnifier shows (up, positive, zooms in). True when
/// taken.
pub fn onScroll(ed: *Editor, steps: i32) bool {
    if (steps == 0 or !ui.loupeWanted(ed)) return false;
    zoomBy(ed, steps);
    return true;
}

/// `d` zoom levels in (out when negative), within config.loupe_zooms.
fn zoomBy(ed: *Editor, d: i32) void {
    const levels = config.loupe_zooms;
    const cur = std.mem.indexOfScalar(u8, &levels, ed.loupe.zoom) orelse 1;
    const next: usize = @intCast(std.math.clamp(@as(i32, @intCast(cur)) + d, 0, levels.len - 1));
    if (levels[next] == ed.loupe.zoom) return;
    ed.loupe.zoom = levels[next];
    std.log.info("magnifier: zoom {d}x", .{ed.loupe.zoom});
    ed.needs_render = true;
}

/// The pixel's colour to the clipboard, "Copied" in the label.
fn copy(ed: *Editor) !void {
    const c = ui.loupeColor(ed) orelse return;
    var buf: [16]u8 = undefined;
    const hex = color.hex(&buf, c);
    const owned = try ed.alloc.dupe(u8, hex);
    ed.win.setClipboardText(owned) catch |e| {
        ed.alloc.free(owned);
        std.log.warn("magnifier: copy failed: {t}", .{e});
        return;
    };
    std.log.info("magnifier: copied {s}", .{hex});
    ed.tools.history.add(c);
    ui.loupeCopied(ed);
}
