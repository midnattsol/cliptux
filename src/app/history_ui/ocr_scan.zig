//! Background OCR of the kept captures that were never read, so the
//! panel's search field can find them by their text.

const std = @import("std");
const history = @import("../history.zig");
const ocr = @import("../../platform/api.zig").ocr;
const SpinLock = @import("../../ocr/spinlock.zig").SpinLock;
const sys = @import("../../platform/api.zig").sys;
const png = @import("../../gfx/png.zig");
const Panel = @import("panel.zig").Panel;

/// Background OCR of entries that were never read.
pub const Ocr = struct {
    mutex: SpinLock = .{},
    /// ids whose text was just written to their meta
    done: std.ArrayList(history.Id) = .empty,
    finished: bool = false,
    /// the panel said how many were read (once finished)
    reported: bool = false,
    thread: ?std.Thread = null,
    stop: bool = false,

    fn worker(self: *Ocr, gpa: std.mem.Allocator, root: []const u8, ids: []history.Id) void {
        defer gpa.free(ids);
        for (ids) |id| {
            if (@atomicLoad(bool, &self.stop, .acquire)) break;
            readOne(gpa, root, id.slice()) catch |err| std.log.info("ocr of {s} failed: {t}", .{ id.slice(), err });
            self.mutex.lock();
            self.done.append(gpa, id) catch {};
            self.mutex.unlock();
        }
        self.mutex.lock();
        self.finished = true;
        self.mutex.unlock();
    }

    fn readOne(gpa: std.mem.Allocator, root: []const u8, id: []const u8) !void {
        var pbuf: [1200]u8 = undefined;
        const data = try sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, "image.png"), 512 * 1024 * 1024);
        defer gpa.free(data);
        var img = try png.decode(gpa, data);
        defer img.deinit(gpa);
        const t = ocr.recognize(gpa, img.pixels, img.width, img.height) orelse "";
        defer if (t.len > 0) gpa.free(t);
        std.log.debug("history: text of {s}: {s}", .{ id, t[0..@min(t.len, 80)] });
        var meta = try history.readMeta(gpa, root, id);
        defer meta.deinit(gpa);
        if (meta.ocr) |o| gpa.free(o);
        meta.ocr = try gpa.dupe(u8, t);
        try history.writeMeta(gpa, root, id, &meta);
    }

    /// Stop the worker (after the capture it is reading) and free.
    pub fn deinit(self: *Ocr, gpa: std.mem.Allocator) void {
        if (self.thread) |t| {
            @atomicStore(bool, &self.stop, true, .release);
            t.join();
        }
        self.done.deinit(gpa);
    }
};

/// Read the text of the captures that have none, on a thread.
pub fn startOcr(self: *Panel) void {
    if (!self.searchable) return;
    var ids: std.ArrayList(history.Id) = .empty;
    for (self.items.items) |it| if (it.entry.meta.ocr == null) ids.append(self.gpa, it.entry.id) catch {};
    if (ids.items.len == 0) {
        ids.deinit(self.gpa);
        return;
    }
    const owned = ids.toOwnedSlice(self.gpa) catch return;
    self.ocr_state.thread = std.Thread.spawn(.{}, Ocr.worker, .{ &self.ocr_state, self.gpa, self.root(), owned }) catch {
        self.gpa.free(owned);
        return;
    };
}

/// Pick up text the OCR thread wrote.
pub fn pollOcr(self: *Panel) void {
    self.ocr_state.mutex.lock();
    defer self.ocr_state.mutex.unlock();
    if (self.ocr_state.finished and !self.ocr_state.reported and self.ocr_state.done.items.len == 0) {
        self.ocr_state.reported = true;
        reportRead(self);
    }
    if (self.ocr_state.done.items.len == 0) return;
    for (self.ocr_state.done.items) |id| reloadMeta(self, id);
    self.ocr_state.done.clearRetainingCapacity();
    if (self.search.items.len > 0) self.filter();
}

/// Log how many captures have text, once the worker is through.
fn reportRead(self: *const Panel) void {
    var n: usize = 0;
    for (self.items.items) |it| {
        if (it.entry.meta.ocr) |t| if (t.len > 0) {
            n += 1;
        };
    }
    std.log.info("history: read the text of {d} captures", .{n});
}

/// Reload the meta (with its new text) of the items with this id.
fn reloadMeta(self: *Panel, id: history.Id) void {
    for (self.items.items) |*it| {
        if (!std.mem.eql(u8, it.entry.id.slice(), id.slice())) continue;
        var m = history.readMeta(self.gpa, self.root(), id.slice()) catch continue;
        it.entry.meta.deinit(self.gpa);
        it.entry.meta = m;
        m = .{};
    }
}
