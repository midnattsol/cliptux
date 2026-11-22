//! Text recognition in the editor, on a worker thread: Copy text puts the
//! selection's text on the clipboard, Redact sensitive data covers what
//! it finds; `shotlet text` copies the text of the region selected and
//! closes. Without libtesseract both say how to install it.

const std = @import("std");
const ocr = @import("../../platform/api.zig").ocr;
const page_mod = @import("../../ocr/page.zig");
const reflow = @import("../../ocr/reflow.zig");
const shapes = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const redact = @import("redact.zig");
const launch = @import("launch.zig");

const Editor = editor_mod.Editor;
const Rect = shapes.Rect;

pub const Purpose = enum { copy_text, redact };

pub const install_hint = "Needs Tesseract: apt install tesseract-ocr, dnf install tesseract or pacman -S tesseract";

pub const Job = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    purpose: Purpose = .copy_text,
    alloc: std.mem.Allocator = undefined,
    region: Rect = Rect.empty,
    scale: u32 = 1,
    pixels: []u32 = &.{},
    page: ?page_mod.Page = null,

    fn work(self: *Job) void {
        defer self.done.store(true, .release);
        const w: u32 = @intCast(self.region.w * @as(i32, @intCast(self.scale)));
        const h: u32 = @intCast(self.region.h * @as(i32, @intCast(self.scale)));
        const tsv = ocr.recognizeTsv(self.alloc, self.pixels, w, h, 96 * self.scale) orelse return;
        defer self.alloc.free(tsv);
        var p = page_mod.parseTsv(self.alloc, tsv) catch return;
        p.mapBoxes(self.scale, self.region.x, self.region.y);
        self.page = p;
    }

    fn release(self: *Job) void {
        if (self.thread) |t| t.join();
        self.thread = null;
        self.alloc.free(self.pixels);
        self.pixels = &.{};
        if (self.page) |*p| p.deinit(self.alloc);
        self.page = null;
    }
};

pub fn available() bool {
    return ocr.available();
}

/// Read the selection (or the whole picture) in the background.
pub fn start(ed: *Editor, purpose: Purpose) !void {
    const job = &ed.tools.ocr;
    ed.needs_render = true;
    if (job.thread != null) return;
    if (!ocr.available()) {
        std.log.warn("text recognition: no libtesseract. Debian/Ubuntu: apt install tesseract-ocr; Fedora: dnf install tesseract; Arch: pacman -S tesseract", .{});
        ed.tools.toast.show(.problem, install_hint, 6000);
        return;
    }
    try ed.settle();
    const r = ed.doc.exportRect();
    if (r.w < 4 or r.h < 4) return;
    job.release();
    job.* = .{ .purpose = purpose, .alloc = ed.alloc, .region = r, .scale = page_mod.scaleFor(@intCast(r.w), @intCast(r.h)) };
    job.pixels = try page_mod.prepare(ed.alloc, ed.img.pixels, ed.img.width, r, job.scale);
    job.thread = try std.Thread.spawn(.{}, Job.work, .{job});
    ed.tools.toast.show(.busy, if (purpose == .copy_text) "Reading text\u{2026}" else "Looking for sensitive data\u{2026}", 0);
}

/// A finished job: copy its text or redact what it found.
pub fn poll(ed: *Editor) !void {
    const job = &ed.tools.ocr;
    if (job.thread == null or !job.done.load(.acquire)) return;
    job.thread.?.join();
    job.thread = null;
    defer job.release();
    ed.needs_render = true;
    const p = job.page orelse {
        ed.tools.toast.show(.problem, "Text recognition failed", 3000);
        return;
    };
    switch (job.purpose) {
        .copy_text => try copyText(ed, p.words),
        .redact => try redact.apply(ed, p.words),
    }
}

pub fn busy(ed: *const Editor) bool {
    return ed.tools.ocr.thread != null;
}

pub fn deinit(ed: *Editor) void {
    ed.tools.ocr.release();
}

fn copyText(ed: *Editor, words: []const page_mod.Word) !void {
    const text = try reflow.reflow(ed.alloc, words);
    if (text.len == 0) {
        ed.alloc.free(text);
        std.log.info("copy text: no text found", .{});
        ed.tools.toast.show(.info, "No text found", 2400);
        return;
    }
    const first = firstLine(text);
    var msg: [200]u8 = undefined;
    const say = std.fmt.bufPrint(&msg, "Copied: {s}", .{first}) catch "Copied";
    std.log.info("copy text: {d} bytes, {d} lines", .{ text.len, std.mem.count(u8, text, "\n") + 1 });
    ed.win.setClipboardText(text) catch |e| {
        ed.alloc.free(text);
        std.log.warn("copy text failed: {t}", .{e});
        ed.tools.toast.show(.problem, "Copy failed", 2400);
        return;
    };
    ed.tools.toast.show(.done, say, 2400);
    if (ed.tools.text_capture) {
        // done: a toast of its own says so once the editor is gone
        if (launch.env) |env| @import("../../app/keep.zig").spawnSelf(env, &.{ "toast", "Copied", firstLineZ(&msg, first) });
        ed.finish(.copied);
    }
}

fn firstLine(text: []const u8) []const u8 {
    const l = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return l[0..@min(l.len, 120)];
}

fn firstLineZ(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    std.mem.copyForwards(u8, buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

test "first lines" {
    try std.testing.expectEqualStrings("one", firstLine("one\ntwo"));
    try std.testing.expectEqualStrings("only", firstLine("only"));
}
