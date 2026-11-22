//! Our clipboard selection: claiming it with text or an image (PNG,
//! possibly encoded in the background), serving reads, and letting go.

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const png = @import("../../../gfx/png.zig");
const window = @import("../window.zig");
const events = @import("events.zig");

const Window = window.Window;

/// Raw pixels on the clipboard, PNG-encoded on a worker thread.
const ClipboardImage = struct {
    alloc: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    png_data: []u8 = &.{},
    encode_failed: bool = false,
    thread: ?std.Thread = null,

    fn create(alloc: std.mem.Allocator, pixels: []u32, width: u32, height: u32) !*ClipboardImage {
        const self = try alloc.create(ClipboardImage);
        self.* = .{ .alloc = alloc, .pixels = pixels, .width = width, .height = height };
        errdefer alloc.destroy(self);
        self.thread = try std.Thread.spawn(.{}, encodeWorker, .{self});
        return self;
    }

    fn deinit(self: *ClipboardImage) void {
        if (self.thread) |thread| thread.join();
        self.alloc.free(self.png_data);
        self.alloc.free(self.pixels);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn waitPng(self: *ClipboardImage) ![]const u8 {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.encode_failed) return error.ClipboardEncodeFailed;
        return self.png_data;
    }

    fn encodeWorker(self: *ClipboardImage) void {
        self.png_data = png.encode(self.alloc, self.pixels, self.width, self.height) catch {
            self.encode_failed = true;
            return;
        };
    }
};

/// The selection we own. Its payloads are Window.clipboard_text and
/// Window.clipboard_png, or `image` while it encodes.
pub const Clipboard = struct {
    /// wl_data_source of our selection; 0 when we own none
    source: u32 = 0,
    image: ?*ClipboardImage = null,
};

pub fn hasClipboard(w: *const Window) bool {
    return w.clipboard.source != 0;
}

/// The PNG we offer on the clipboard (encoding it first if needed);
/// null when we offer none or text.
pub fn clipboardPng(w: *Window) ?[]const u8 {
    if (w.clipboard.source == 0) return null;
    if (w.clipboard.image) |image| return image.waitPng() catch null;
    if (w.clipboard_png.len > 0) return w.clipboard_png;
    return null;
}

/// Claim the clipboard selection with an already-encoded image/png data
/// source. Takes ownership of data on success. Call while the window still
/// has focus (serial must be fresh).
pub fn setClipboardPng(w: *Window, data: []u8) !void {
    try claimClipboardSource(w, &.{"image/png"});
    w.clipboard_png = data;
}

/// Claim the clipboard selection immediately, then encode the raw image in
/// the background. Takes ownership of pixels on success.
pub fn setClipboardImage(w: *Window, pixels: []u32, width: u32, height: u32) !void {
    const image = try ClipboardImage.create(w.alloc, pixels, width, height);
    errdefer image.deinit();
    try claimClipboardSource(w, &.{"image/png"});
    w.clipboard.image = image;
}

/// Put UTF-8 text on the clipboard. Takes ownership of `data` on
/// success.
pub fn setClipboardText(w: *Window, data: []u8) !void {
    try claimClipboardSource(w, &.{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" });
    w.clipboard_text = data;
}

/// Offer a new selection of `mimes`, dropping the previous one and its
/// payloads; the caller then sets the payload.
pub fn claimClipboardSource(w: *Window, mimes: []const []const u8) !void {
    const g = &w.globals;
    if (g.ddm == 0 or w.data_device.id == 0) return error.NoDataDevice;
    const c = &w.conn;
    const source = c.newId();
    try c.request(g.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
    for (mimes) |m| try c.request(source, wl.wl_data_source.offer, &.{.{ .string = m }});
    try c.request(w.data_device.id, wl.wl_data_device.set_selection, &.{ .{ .object = source }, .{ .uint = w.input_serial } });
    try c.flush();

    dropSource(w);
    w.clipboard.source = source;
}

/// Serve clipboard reads until another client replaces the selection.
/// Blocks; safe to call after closeWindow().
pub fn serveClipboard(w: *Window) !void {
    while (w.clipboard.source != 0) {
        const ev = try w.conn.readEvent();
        try events.handleEvent(w, ev);
        w.queue.clearRetainingCapacity();
    }
}

/// wl_data_source events of our selection.
pub fn handleSource(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_data_source.ev_send => {
            const mime = try r.string();
            if (w.conn.takeFd()) |fd| {
                defer sys.close(fd);
                const data = payloadFor(w, mime) orelse return;
                sys.writeAllBlocking(fd, data) catch |err| switch (err) {
                    error.BrokenPipe, error.ConnectionReset => {},
                    else => std.log.warn("clipboard send failed: {t}", .{err}),
                };
            }
        },
        wl.wl_data_source.ev_cancelled => dropSource(w),
        else => {},
    }
}

/// What to send for `mime`: video/* and image/gif get the file in
/// clipboard_png, the rest the text (its uri) when there is text, else
/// the image; null when encoding the image failed.
fn payloadFor(w: *Window, mime: []const u8) ?[]const u8 {
    const media = std.mem.startsWith(u8, mime, "video/") or std.mem.startsWith(u8, mime, "image/gif");
    if (w.clipboard_text.len > 0 and !media) return w.clipboard_text;
    if (w.clipboard.image) |image| return image.waitPng() catch |err| {
        std.log.warn("clipboard encode failed: {t}", .{err});
        return null;
    };
    return w.clipboard_png;
}

/// Give up the selection and free its payloads.
pub fn dropSource(w: *Window) void {
    if (w.clipboard.source != 0) {
        w.conn.request(w.clipboard.source, wl.wl_data_source.destroy, &.{}) catch {};
        w.clipboard.source = 0;
    }
    if (w.clipboard_text.len > 0) {
        w.alloc.free(w.clipboard_text);
        w.clipboard_text = &.{};
    }
    if (w.clipboard_png.len > 0) {
        w.alloc.free(w.clipboard_png);
        w.clipboard_png = &.{};
    }
    if (w.clipboard.image) |image| {
        image.deinit();
        w.clipboard.image = null;
    }
    w.conn.flush() catch {};
}
