//! Optional text recognition with Tesseract, loaded at run time
//! (libtesseract.so.5 or .so.4) through its C API, so Shotlet keeps zero
//! build dependencies: without the library the history simply has no
//! search field. Pixels are handed over as packed RGB, so Leptonica's own
//! API is not needed (libtesseract pulls it in itself).

const std = @import("std");

const Handle = *opaque {};

const Api = struct {
    TessBaseAPICreate: *const fn () callconv(.c) ?Handle,
    TessBaseAPIDelete: *const fn (Handle) callconv(.c) void,
    TessBaseAPIInit3: *const fn (Handle, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    TessBaseAPISetImage: *const fn (Handle, [*]const u8, c_int, c_int, c_int, c_int) callconv(.c) void,
    TessBaseAPIGetUTF8Text: *const fn (Handle) callconv(.c) ?[*:0]u8,
    TessDeleteText: *const fn ([*:0]u8) callconv(.c) void,
    TessBaseAPIEnd: *const fn (Handle) callconv(.c) void,
};

var lib: ?std.DynLib = null;
var api: ?Api = null;
var tried = false;
var mutex: SpinLock = .{};

/// A small lock for short critical sections between threads.
pub const SpinLock = struct {
    m: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinLock) void {
        while (!self.m.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.m.unlock();
    }
};

/// Tesseract is installed (loads it on first call).
pub fn available() bool {
    mutex.lock();
    defer mutex.unlock();
    if (tried) return api != null;
    tried = true;
    if (std.c.getenv("SHOTLET_NO_OCR") != null) return false;
    for ([_][]const u8{ "libtesseract.so.5", "libtesseract.so.4" }) |name| {
        lib = std.DynLib.open(name) catch continue;
        break;
    }
    var l = &(lib orelse return false);
    var a: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        @field(a, name) = l.lookup(T, name) orelse {
            std.log.info("libtesseract lacks {s}; no text search", .{name});
            return false;
        };
    }
    api = a;
    return true;
}

/// Languages to recognise: $SHOTLET_OCR_LANG (e.g. "eng+spa"), else eng.
fn languages() [*:0]const u8 {
    return std.c.getenv("SHOTLET_OCR_LANG") orelse "eng";
}

/// Text in an 0xAARRGGBB image (owned UTF-8), or null when Tesseract is
/// missing or fails. Slow (hundreds of ms): call from a worker thread.
pub fn recognize(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ?[]u8 {
    if (!available()) return null;
    const a = api.?;
    if (width == 0 or height == 0) return null;
    const rgb = alloc.alloc(u8, @as(usize, width) * height * 3) catch return null;
    defer alloc.free(rgb);
    for (pixels[0 .. @as(usize, width) * height], 0..) |p, i| {
        rgb[i * 3] = @truncate(p >> 16);
        rgb[i * 3 + 1] = @truncate(p >> 8);
        rgb[i * 3 + 2] = @truncate(p);
    }
    const h = a.TessBaseAPICreate() orelse return null;
    defer a.TessBaseAPIDelete(h);
    if (a.TessBaseAPIInit3(h, null, languages()) != 0) {
        std.log.info("tesseract has no data for {s}", .{std.mem.span(languages())});
        return null;
    }
    defer a.TessBaseAPIEnd(h);
    a.TessBaseAPISetImage(h, rgb.ptr, @intCast(width), @intCast(height), 3, @intCast(width * 3));
    const out = a.TessBaseAPIGetUTF8Text(h) orelse return null;
    defer a.TessDeleteText(out);
    return alloc.dupe(u8, std.mem.trim(u8, std.mem.span(out), " \t\r\n")) catch null;
}

/// Case-insensitive (ASCII) search for every word of `query` in `hay`.
pub fn matches(hay: []const u8, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t");
    while (words.next()) |w| {
        if (!containsIgnoreCase(hay, w)) return false;
    }
    return true;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "search matches every word, ignoring case" {
    try std.testing.expect(matches("Hello World\nfoo", "world HELLO"));
    try std.testing.expect(!matches("Hello World", "world bar"));
    try std.testing.expect(matches("anything", ""));
}
