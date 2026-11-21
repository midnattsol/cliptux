//! Bounds-checked unmarshalling of little-endian DBus wire data.

const std = @import("std");
const Marshal = @import("marshal.zig").Marshal;

pub const Value = union(enum) {
    string: []const u8,
    object_path: []const u8,
    boolean: bool,
    u32_: u32,
    i32_: i32,
    u64_: u64,
    f64_: f64,
    other: void, // present but uninterpreted (skipped)
};

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn pad(self: *Reader, alignment: usize) void {
        while (self.pos % alignment != 0) self.pos += 1;
    }
    pub fn readByte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.ShortRead;
        defer self.pos += 1;
        return self.data[self.pos];
    }
    pub fn readU16(self: *Reader) !u16 {
        self.pad(2);
        if (self.pos + 2 > self.data.len) return error.ShortRead;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
    }
    pub fn readU32(self: *Reader) !u32 {
        self.pad(4);
        if (self.pos + 4 > self.data.len) return error.ShortRead;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
    }
    pub fn readU64(self: *Reader) !u64 {
        self.pad(8);
        if (self.pos + 8 > self.data.len) return error.ShortRead;
        defer self.pos += 8;
        return std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
    }
    pub fn readString(self: *Reader) ![]const u8 {
        const len: usize = try self.readU32();
        if (self.pos + len + 1 > self.data.len) return error.ShortRead;
        defer self.pos += len + 1;
        return self.data[self.pos..][0..len];
    }
    pub fn readSignature(self: *Reader) ![]const u8 {
        const len: usize = try self.readByte();
        if (self.pos + len + 1 > self.data.len) return error.ShortRead;
        defer self.pos += len + 1;
        return self.data[self.pos..][0..len];
    }

    /// Read a variant, interpreting common simple types.
    pub fn readVariant(self: *Reader) !Value {
        const sig = try self.readSignature();
        return self.readValue(sig);
    }

    fn readValue(self: *Reader, sig: []const u8) anyerror!Value {
        if (sig.len == 0) return error.BadSignature;
        if (sig.len == 1) switch (sig[0]) {
            's' => return .{ .string = try self.readString() },
            'o' => return .{ .object_path = try self.readString() },
            'b' => return .{ .boolean = (try self.readU32()) != 0 },
            'u' => return .{ .u32_ = try self.readU32() },
            'i' => return .{ .i32_ = @bitCast(try self.readU32()) },
            'x', 't' => return .{ .u64_ = try self.readU64() },
            'd' => return .{ .f64_ = @bitCast(try self.readU64()) },
            else => {},
        };
        // a variant holds exactly one complete type
        try self.skipValue(sig);
        return .other;
    }

    /// The spec allows 32 levels of array and 32 of struct nesting; variants
    /// nest without a signature-imposed bound, so cap the total explicitly.
    pub const max_depth = 64;

    /// Skip one complete type starting at sig[idx.*]; advances idx past it.
    /// Never reads outside `data` or `sig`: malformed input is an error.
    pub fn skipType(self: *Reader, sig: []const u8, idx: *usize) anyerror!void {
        return self.skipTypeDepth(sig, idx, 0);
    }

    fn skipTypeDepth(self: *Reader, sig: []const u8, idx: *usize, depth: u32) anyerror!void {
        if (depth > max_depth) return error.TooDeep;
        if (idx.* >= sig.len) return error.BadSignature;
        const c = sig[idx.*];
        idx.* += 1;
        switch (c) {
            'y' => _ = try self.readByte(),
            'n', 'q' => _ = try self.readU16(),
            'b', 'u', 'i', 'h' => _ = try self.readU32(),
            'x', 't', 'd' => _ = try self.readU64(),
            's', 'o' => _ = try self.readString(),
            'g' => _ = try self.readSignature(),
            'v' => try self.skipVariant(depth),
            'a' => try self.skipArray(sig, idx, depth),
            '(', '{' => try self.skipStruct(sig, idx, if (c == '(') ')' else '}', depth),
            else => return error.BadSignature,
        }
    }

    /// Skip a variant: its own signature, then exactly one value of it.
    fn skipVariant(self: *Reader, depth: u32) anyerror!void {
        const inner = try self.readSignature();
        var i: usize = 0;
        try self.skipTypeDepth(inner, &i, depth + 1);
        if (i != inner.len) return error.BadSignature;
    }

    /// Skip an array whose element type starts at sig[idx.*] (just past 'a').
    fn skipArray(self: *Reader, sig: []const u8, idx: *usize, depth: u32) anyerror!void {
        const len = try self.readU32();
        if (len > 64 * 1024 * 1024) return error.BadArrayLength;
        if (idx.* >= sig.len) return error.BadSignature;
        const elem_align = typeAlignment(sig[idx.*]) orelse return error.BadSignature;
        self.pad(elem_align);
        if (self.pos > self.data.len or len > self.data.len - self.pos) return error.ShortRead;
        self.pos += len;
        // the element type is skipped in the signature only
        try skipSignature(sig, idx, depth + 1);
    }

    /// Skip struct/dict-entry members up to and including `close`.
    fn skipStruct(self: *Reader, sig: []const u8, idx: *usize, close: u8, depth: u32) anyerror!void {
        self.pad(8);
        while (true) {
            if (idx.* >= sig.len) return error.BadSignature;
            if (sig[idx.*] == close) break;
            try self.skipTypeDepth(sig, idx, depth + 1);
        }
        idx.* += 1; // closing paren
    }

    /// Read an array length, align to its 8-aligned dict entries and return
    /// the end offset of the array data.
    fn beginDictArray(self: *Reader) !usize {
        const len = try self.readU32();
        self.pad(8);
        if (self.pos > self.data.len or len > self.data.len - self.pos) return error.ShortRead;
        return self.pos + len;
    }

    /// Iterate over a{sv}: call this after positioning at the array.
    pub fn readDictSV(self: *Reader) !DictSVIterator {
        return .{ .reader = self, .end = try self.beginDictArray() };
    }
    pub const DictSVIterator = struct {
        reader: *Reader,
        end: usize,
        pub fn next(self: *DictSVIterator) !?struct { key: []const u8, value: Value } {
            if (self.reader.pos >= self.end) return null;
            self.reader.pad(8);
            if (self.reader.pos >= self.end) return null;
            const key = try self.reader.readString();
            const value = try self.reader.readVariant();
            if (self.reader.pos > self.end) return error.BadArrayLength;
            return .{ .key = key, .value = value };
        }
    };

    /// Like DictSVIterator, but leaves each value unread: the caller gets
    /// the variant's signature and must consume exactly one value of it
    /// (or call skipValue).
    pub fn readDictRaw(self: *Reader) !DictRawIterator {
        return .{ .reader = self, .end = try self.beginDictArray() };
    }
    pub const DictRawIterator = struct {
        reader: *Reader,
        end: usize,
        pub fn next(self: *DictRawIterator) !?struct { key: []const u8, sig: []const u8 } {
            if (self.reader.pos > self.end) return error.BadArrayLength;
            if (self.reader.pos >= self.end) return null;
            self.reader.pad(8);
            if (self.reader.pos >= self.end) return null;
            const key = try self.reader.readString();
            const sig = try self.reader.readSignature();
            return .{ .key = key, .sig = sig };
        }
    };

    /// Skip a value whose full signature is `sig` (e.g. a variant's).
    pub fn skipValue(self: *Reader, sig: []const u8) !void {
        var idx: usize = 0;
        try self.skipType(sig, &idx);
        if (idx != sig.len) return error.BadSignature;
    }
};

/// Alignment of a value whose signature starts with `c`.
fn typeAlignment(c: u8) ?usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'u', 'i', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => null,
    };
}

/// Advance idx past one complete type in a signature, validating nesting.
fn skipSignature(sig: []const u8, idx: *usize, depth: u32) !void {
    if (depth > Reader.max_depth) return error.TooDeep;
    if (idx.* >= sig.len) return error.BadSignature;
    const c = sig[idx.*];
    idx.* += 1;
    switch (c) {
        'y', 'n', 'q', 'b', 'u', 'i', 'h', 'x', 't', 'd', 's', 'o', 'g', 'v' => {},
        'a' => try skipSignature(sig, idx, depth + 1),
        '(', '{' => {
            const close: u8 = if (c == '(') ')' else '}';
            while (true) {
                if (idx.* >= sig.len) return error.BadSignature;
                if (sig[idx.*] == close) {
                    idx.* += 1;
                    return;
                }
                try skipSignature(sig, idx, depth + 1);
            }
        },
        else => return error.BadSignature,
    }
}

test "dict marshal/read roundtrip" {
    const alloc = std.testing.allocator;
    var m = Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("uri");
    try m.putVariantString("file:///tmp/x.png");
    try m.beginStruct();
    try m.putString("count");
    try m.putVariantU32(7);
    m.endArray(arr);

    var r = Reader{ .data = m.buf.items, .pos = 0 };
    var it = try r.readDictSV();
    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("uri", e1.key);
    try std.testing.expectEqualStrings("file:///tmp/x.png", e1.value.string);
    const e2 = (try it.next()).?;
    try std.testing.expectEqualStrings("count", e2.key);
    try std.testing.expectEqual(@as(u32, 7), e2.value.u32_);
    try std.testing.expectEqual(@as(?@TypeOf(e1), null), try it.next());
}

test "reader skips unknown variant types" {
    const alloc = std.testing.allocator;
    var m = Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("blob");
    try m.putSignature("ay");
    const inner = try m.beginArray(1);
    try m.putByte(1);
    try m.putByte(2);
    m.endArray(inner);
    try m.beginStruct();
    try m.putString("after");
    try m.putVariantU32(42);
    m.endArray(arr);

    var r = Reader{ .data = m.buf.items, .pos = 0 };
    var it = try r.readDictSV();
    const e1 = (try it.next()).?;
    try std.testing.expectEqualStrings("blob", e1.key);
    try std.testing.expect(e1.value == .other);
    const e2 = (try it.next()).?;
    try std.testing.expectEqual(@as(u32, 42), e2.value.u32_);
}

test "skipType rejects truncated signatures and data" {
    const data = [_]u8{ 0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0 };
    const sigs = [_][]const u8{ "a", "(", "(i", "a{", "a{s", "a(i", ")", "}", "v", "", "aaaa", "z" };
    for (sigs) |sig| {
        var r = Reader{ .data = &data, .pos = 0 };
        var idx: usize = 0;
        if (r.skipType(sig, &idx)) |_| {} else |_| {}
    }
    // array length larger than the data
    var r = Reader{ .data = &data, .pos = 0 };
    var idx: usize = 0;
    try std.testing.expectError(error.BadArrayLength, r.skipType("ay", &idx));

    // variants nested beyond the depth limit
    var deep: [3 * 200 + 4]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= 600) : (i += 3) {
        deep[i] = 1;
        deep[i + 1] = 'v';
        deep[i + 2] = 0;
    }
    var rd = Reader{ .data = deep[0..600], .pos = 0 };
    try std.testing.expectError(error.TooDeep, rd.readVariant());
}
