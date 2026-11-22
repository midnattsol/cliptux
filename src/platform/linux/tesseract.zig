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
    TessBaseAPIGetTsvText: *const fn (Handle, c_int) callconv(.c) ?[*:0]u8,
    TessBaseAPISetSourceResolution: *const fn (Handle, c_int) callconv(.c) void,
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

/// Languages to recognise: $SHOTLET_OCR_LANG (e.g. "eng+spa"), else the
/// desktop's language plus English ("spa+eng" under es_ES), else eng.
fn languages(buf: *[32]u8) [:0]const u8 {
    if (std.c.getenv("SHOTLET_OCR_LANG")) |l| return std.mem.span(l);
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const v = std.mem.span(std.c.getenv(name) orelse continue);
        if (v.len == 0) continue;
        return localeLanguages(buf, v);
    }
    return "eng";
}

/// Tesseract's language names for a POSIX locale ("es_ES.UTF-8"), with
/// English as a second language for the Latin text every screen has.
fn localeLanguages(buf: *[32]u8, locale: []const u8) [:0]const u8 {
    const code = locale[0 .. std.mem.indexOfAny(u8, locale, "_.@") orelse locale.len];
    const table = [_][2][]const u8{
        .{ "es", "spa" }, .{ "ca", "cat" },     .{ "gl", "glg" }, .{ "eu", "eus" },
        .{ "pt", "por" }, .{ "fr", "fra" },     .{ "it", "ita" }, .{ "de", "deu" },
        .{ "nl", "nld" }, .{ "sv", "swe" },     .{ "nb", "nor" }, .{ "nn", "nor" },
        .{ "no", "nor" }, .{ "da", "dan" },     .{ "fi", "fin" }, .{ "pl", "pol" },
        .{ "cs", "ces" }, .{ "ru", "rus" },     .{ "uk", "ukr" }, .{ "tr", "tur" },
        .{ "el", "ell" }, .{ "hu", "hun" },     .{ "ro", "ron" }, .{ "ja", "jpn" },
        .{ "ko", "kor" }, .{ "zh", "chi_sim" },
    };
    for (table) |e| {
        if (std.mem.eql(u8, code, e[0])) return std.mem.printSentinel(buf, "{s}+eng", .{e[1]}, 0) catch "eng";
    }
    return "eng";
}

test "languages follow the locale, with English" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("spa+eng", localeLanguages(&buf, "es_ES.UTF-8"));
    try std.testing.expectEqualStrings("deu+eng", localeLanguages(&buf, "de"));
    try std.testing.expectEqualStrings("eng", localeLanguages(&buf, "C.UTF-8"));
    try std.testing.expectEqualStrings("eng", localeLanguages(&buf, "en_US.UTF-8"));
}

/// Text in an 0xAARRGGBB image (owned UTF-8), or null when Tesseract is
/// missing or fails. Slow (hundreds of ms): call from a worker thread.
pub fn recognize(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32) ?[]u8 {
    return run(alloc, pixels, width, height, .text, 0);
}

/// Every word with its box, as Tesseract's TSV (parsed by
/// src/ocr/page.zig); `ppi` is the image's resolution (0: unknown).
pub fn recognizeTsv(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, ppi: u32) ?[]u8 {
    return run(alloc, pixels, width, height, .tsv, ppi);
}

fn run(alloc: std.mem.Allocator, pixels: []const u32, width: u32, height: u32, what: enum { text, tsv }, ppi: u32) ?[]u8 {
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
    var lbuf: [32]u8 = undefined;
    const langs = languages(&lbuf);
    if (a.TessBaseAPIInit3(h, null, langs.ptr) != 0) {
        // the locale's language data may not be installed: English alone
        if (std.mem.eql(u8, langs, "eng") or a.TessBaseAPIInit3(h, null, "eng") != 0) {
            std.log.info("tesseract has no data for {s}", .{langs});
            return null;
        }
        std.log.info("tesseract has no data for {s}; reading English only", .{langs});
    }
    defer a.TessBaseAPIEnd(h);
    a.TessBaseAPISetImage(h, rgb.ptr, @intCast(width), @intCast(height), 3, @intCast(width * 3));
    if (ppi > 0) a.TessBaseAPISetSourceResolution(h, @intCast(ppi));
    const out = (if (what == .tsv) a.TessBaseAPIGetTsvText(h, 0) else a.TessBaseAPIGetUTF8Text(h)) orelse return null;
    defer a.TessDeleteText(out);
    return alloc.dupe(u8, std.mem.trim(u8, std.mem.span(out), " \t\r\n")) catch null;
}

/// Search for every word of `query` in `hay`, ignoring case and the
/// accents of Latin letters: "cancion" finds "Canción", "ESPAÑA" finds
/// "españa" (recognised text often gets accents wrong anyway).
pub fn matches(hay: []const u8, query: []const u8) bool {
    var hbuf: [8192]u8 = undefined;
    var qbuf: [256]u8 = undefined;
    const h = fold(&hbuf, hay);
    var words = std.mem.tokenizeAny(u8, fold(&qbuf, query), " \t");
    while (words.next()) |w| {
        if (std.mem.indexOf(u8, h, w) == null) return false;
    }
    return true;
}

/// Lowercase ASCII with Latin-1 and Latin Extended-A letters reduced to
/// their base letter; other text is copied as is. Cut at `buf`'s size.
fn fold(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (len > 1 and i + len <= s.len) {
            if (std.unicode.utf8Decode(s[i..][0..len])) |cp| {
                if (baseLetter(cp)) |b| {
                    buf[n] = b;
                    n += 1;
                    i += len;
                    continue;
                }
            } else |_| {}
            if (n + len > buf.len) break;
            @memcpy(buf[n..][0..len], s[i..][0..len]);
            n += len;
            i += len;
            continue;
        }
        buf[n] = std.ascii.toLower(s[i]);
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

/// The unaccented lowercase letter of an accented Latin one.
fn baseLetter(cp: u21) ?u8 {
    // U+00C0..U+00FF, by code point (0 where there is no plain letter)
    const latin1 = "aaaaaaaceeeeiiii" ++ "dnooooo\x00ouuuuyts" ++ "aaaaaaaceeeeiiii" ++ "dnooooo\x00ouuuuyty";
    if (cp >= 0xC0 and cp <= 0xFF) {
        const b = latin1[cp - 0xC0];
        return if (b == 0) null else b;
    }
    // U+0100..U+017F come in upper/lower pairs, mostly
    const ext_a = "aaaaaaccccccccdddd" ++ "eeeeeeeeeegggggggghhhh" ++ "iiiiiiiiiijjjjkkk" ++ "llllllllllnnnnnnnnn" ++ "oooooooorrrrrrssssssss" ++ "ttttttuuuuuuuuuuuuwwyyyzzzzzzs";
    if (cp >= 0x100 and cp <= 0x17F) return ext_a[cp - 0x100];
    return null;
}

test "search matches every word, ignoring case and accents" {
    try std.testing.expect(matches("Hello World\nfoo", "world HELLO"));
    try std.testing.expect(!matches("Hello World", "world bar"));
    try std.testing.expect(matches("anything", ""));
    try std.testing.expect(matches("Canción del año en España", "cancion ESPAÑA ano"));
    try std.testing.expect(matches("CANCIÓN", "canción"));
    try std.testing.expect(matches("Łódź, Žluťoučký", "lodz zlutoucky"));
    try std.testing.expect(!matches("Canción", "cantion"));
    // other scripts are compared as they are
    try std.testing.expect(matches("日本語のテキスト", "テキスト"));
}
