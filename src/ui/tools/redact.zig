//! Redact sensitive data (Ctrl+Shift+R, More menu): what the detectors
//! find in the recognised text becomes ordinary redaction annotations,
//! one undo step, to review, move or delete like any other.

const std = @import("std");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const Word = @import("../../ocr/page.zig").Word;
const locate = @import("../../redact/locate.zig");

const Editor = editor_mod.Editor;
const Rect = shapes.Rect;
const Tool = shapes.Tool;

/// Blur or pixelate when that is the redaction tool in use, else solid.
fn style(ed: *const Editor) Tool {
    return if (ed.tool == .blur or ed.tool == .pixelate) ed.tool else .redact;
}

pub fn apply(ed: *Editor, words: []const Word) !void {
    const hits = try locate.find(ed.alloc, words, 3);
    defer ed.alloc.free(hits);
    if (hits.len == 0) {
        std.log.info("redact: nothing sensitive found", .{});
        ed.tools.toast.show(.info, "Nothing sensitive found", 2400);
        return;
    }
    try ed.settle();
    try ed.doc.checkpoint();
    var area = Rect.empty;
    var n: usize = 0;
    for (hits) |h| {
        const r = Rect.intersect(h.box, ed.doc.imageRect()) orelse continue;
        _ = try ed.doc.add(.{
            .tool = style(ed),
            .color = 0xFF1C1C1E,
            .thickness = ed.imgThickness(),
            .p0 = .{ .x = r.x, .y = r.y },
            .p1 = .{ .x = r.right(), .y = r.bottom() },
        });
        area = Rect.unite(area, r);
        n += 1;
        std.log.info("redact: {t} at {d},{d} {d}x{d}", .{ h.kind, r.x, r.y, r.w, r.h });
    }
    try ed.recompose(area);
    var msg: [64]u8 = undefined;
    ed.tools.toast.show(.done, std.fmt.bufPrint(&msg, "Redacted {d} item{s}: review them, Ctrl+Z undoes", .{ n, if (n == 1) "" else "s" }) catch "Redacted", 3500);
}
