//! Compact Font Format (the 'CFF ' table of OpenType 'OTTO' fonts): INDEX
//! and DICT parsing plus a Type 2 charstring interpreter that emits cubic
//! outlines. Covers name-keyed and CID-keyed fonts (FDArray/FDSelect), which
//! is what Noto CJK, Cantarell and Source fonts use. CFF2 (variable) is not
//! supported. Every read is bounds-checked: font files are untrusted input.
//! The charstring interpreter lives in cff/machine.zig.

const std = @import("std");
const Machine = @import("cff/machine.zig").Machine;

pub const Error = error{BadCff};

pub fn rd8(d: []const u8, off: usize) Error!u8 {
    if (off >= d.len) return error.BadCff;
    return d[off];
}

pub fn rd16(d: []const u8, off: usize) Error!u16 {
    if (off > d.len or d.len - off < 2) return error.BadCff;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

pub fn rdN(d: []const u8, off: usize, n: u8) Error!u32 {
    if (off > d.len or d.len - off < n) return error.BadCff;
    var v: u32 = 0;
    for (d[off..][0..n]) |b| v = (v << 8) | b;
    return v;
}

/// A CFF INDEX: `count` objects addressed by 1-based offsets.
pub const Index = struct {
    data: []const u8 = &.{},
    count: u32 = 0,
    off_size: u8 = 1,
    offsets: usize = 0, // start of the offset array
    base: usize = 0, // offsets are relative to base + 1

    /// Parse the INDEX at `off`; returns it and the offset just past it.
    fn parse(d: []const u8, off: usize) Error!struct { Index, usize } {
        const count = try rd16(d, off);
        if (count == 0) return .{ .{ .data = d }, off + 2 };
        const off_size = try rd8(d, off + 2);
        if (off_size < 1 or off_size > 4) return error.BadCff;
        const offsets = off + 3;
        const arr_len = (@as(usize, count) + 1) * off_size;
        if (offsets > d.len or d.len - offsets < arr_len) return error.BadCff;
        const base = offsets + arr_len - 1;
        const last = try rdN(d, offsets + @as(usize, count) * off_size, off_size);
        if (last < 1 or last > d.len - base) return error.BadCff;
        return .{
            .{ .data = d, .count = count, .off_size = off_size, .offsets = offsets, .base = base },
            base + last,
        };
    }

    pub fn get(self: Index, i: u32) Error![]const u8 {
        if (i >= self.count) return error.BadCff;
        const a = try rdN(self.data, self.offsets + @as(usize, i) * self.off_size, self.off_size);
        const b = try rdN(self.data, self.offsets + (@as(usize, i) + 1) * self.off_size, self.off_size);
        if (a < 1 or b < a or b > self.data.len - self.base) return error.BadCff;
        return self.data[self.base + a .. self.base + b];
    }
};

/// Operands of one DICT operator.
const DictEntry = struct {
    op: u16,
    args: [48]f64,
    n: usize,
};

/// Iterate a DICT, calling back on the first occurrence of `want`.
fn dictFind(d: []const u8, want: u16) Error!?DictEntry {
    var e: DictEntry = .{ .op = 0, .args = undefined, .n = 0 };
    var i: usize = 0;
    while (i < d.len) {
        const b = d[i];
        if (b <= 21) {
            var op: u16 = b;
            i += 1;
            if (b == 12) {
                op = 0x0C00 | @as(u16, try rd8(d, i));
                i += 1;
            }
            if (op == want) {
                e.op = op;
                return e;
            }
            e.n = 0;
            continue;
        }
        var v: f64 = 0;
        if (b == 28) {
            v = @floatFromInt(@as(i16, @bitCast(try rd16(d, i + 1))));
            i += 3;
        } else if (b == 29) {
            v = @floatFromInt(@as(i32, @bitCast(try rdN(d, i + 1, 4))));
            i += 5;
        } else if (b == 30) {
            // real number: skip nibbles until the 0xf terminator; the
            // operators we read never take reals
            i += 1;
            while (true) {
                const nb = try rd8(d, i);
                i += 1;
                if (nb & 0x0F == 0x0F or nb >> 4 == 0x0F) break;
            }
        } else if (b >= 32 and b <= 246) {
            v = @floatFromInt(@as(i32, b) - 139);
            i += 1;
        } else if (b >= 247 and b <= 250) {
            v = @floatFromInt((@as(i32, b) - 247) * 256 + @as(i32, try rd8(d, i + 1)) + 108);
            i += 2;
        } else if (b >= 251 and b <= 254) {
            v = @floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, try rd8(d, i + 1)) - 108);
            i += 2;
        } else {
            return error.BadCff; // 22..27, 31, 255 are reserved in DICTs
        }
        if (e.n >= e.args.len) return error.BadCff;
        e.args[e.n] = v;
        e.n += 1;
    }
    return null;
}

fn dictInt(d: []const u8, op: u16, comptime n: usize) Error!?[n]u32 {
    const e = (try dictFind(d, op)) orelse return null;
    if (e.n < n) return error.BadCff;
    var out: [n]u32 = undefined;
    for (0..n) |k| {
        const v = e.args[e.n - n + k];
        if (!(v >= 0 and v < 1 << 31)) return error.BadCff;
        out[k] = @intFromFloat(v);
    }
    return out;
}

pub const Cff = struct {
    data: []const u8,
    charstrings: Index,
    gsubrs: Index,
    /// local subrs of a name-keyed font
    lsubrs: Index,
    /// CID-keyed fonts: per-glyph font dict selection
    fd_array: Index = .{},
    fd_select: []const u8 = &.{},
    cid: bool = false,

    pub fn parse(d: []const u8) Error!Cff {
        if (d.len < 4 or d[0] != 1) return error.BadCff; // major version 1
        const hdr_size = d[2];
        const name_idx, const after_name = try Index.parse(d, hdr_size);
        _ = name_idx;
        const top_idx, const after_top = try Index.parse(d, after_name);
        _, const after_strings = try Index.parse(d, after_top);
        const gsubrs, _ = try Index.parse(d, after_strings);
        if (top_idx.count < 1) return error.BadCff;
        const top = try top_idx.get(0);

        if (try dictInt(top, 0x0C06, 1)) |t| if (t[0] != 2) return error.BadCff;
        const cs_off = (try dictInt(top, 17, 1)) orelse return error.BadCff;
        const charstrings, _ = try Index.parse(d, cs_off[0]);
        if (charstrings.count == 0) return error.BadCff;

        var out: Cff = .{ .data = d, .charstrings = charstrings, .gsubrs = gsubrs, .lsubrs = .{} };
        if (try dictFind(top, 0x0C1E) != null) { // ROS: CID-keyed
            const fda = (try dictInt(top, 0x0C24, 1)) orelse return error.BadCff;
            const fds = (try dictInt(top, 0x0C25, 1)) orelse return error.BadCff;
            out.fd_array, _ = try Index.parse(d, fda[0]);
            if (fds[0] >= d.len) return error.BadCff;
            out.fd_select = d[fds[0]..];
            out.cid = true;
        } else {
            out.lsubrs = try privateSubrs(d, top);
        }
        return out;
    }

    pub fn numGlyphs(self: *const Cff) u32 {
        return self.charstrings.count;
    }

    fn fdFor(self: *const Cff, gid: u32) Error!u32 {
        const s = self.fd_select;
        const format = try rd8(s, 0);
        if (format == 0) return try rd8(s, 1 + gid);
        if (format != 3) return error.BadCff;
        const n = try rd16(s, 1);
        // ranges: {first u16, fd u8}, then a sentinel u16
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const first = try rd16(s, 3 + mid * 3);
            const next = try rd16(s, 3 + (mid + 1) * 3);
            if (gid < first) {
                hi = mid;
            } else if (gid >= next) {
                lo = mid + 1;
            } else {
                return try rd8(s, 3 + mid * 3 + 2);
            }
        }
        return error.BadCff;
    }

    /// Run the charstring of `gid`, emitting the outline into `sink`
    /// (moveTo/lineTo/cubicTo/close in font units, y up).
    pub fn outline(self: *const Cff, gid: u32, sink: anytype) !void {
        const cs = try self.charstrings.get(gid);
        var lsubrs = self.lsubrs;
        if (self.cid) {
            const fd = try self.fdFor(gid);
            const fd_dict = try self.fd_array.get(fd);
            lsubrs = try privateSubrs(self.data, fd_dict);
        }
        var vm: Machine(@TypeOf(sink)) = .{ .cff = self, .lsubrs = lsubrs, .sink = sink };
        try vm.run(cs, 0);
        try vm.closePath();
    }
};

/// Local subrs referenced from the Private DICT a top or font DICT points to.
fn privateSubrs(d: []const u8, dict: []const u8) Error!Index {
    const priv = (try dictInt(dict, 18, 2)) orelse return .{};
    const size = priv[0];
    const off = priv[1];
    if (off > d.len or d.len - off < size) return error.BadCff;
    const pd = d[off..][0..size];
    const subrs = (try dictInt(pd, 19, 1)) orelse return .{};
    const idx, _ = try Index.parse(d, @as(usize, off) + subrs[0]);
    return idx;
}

test "cff index and dict parsing reject garbage" {
    const junk = [_]u8{ 1, 0, 4, 1, 0xFF, 0xFF, 9, 9 };
    try std.testing.expectError(error.BadCff, Cff.parse(&junk));
    try std.testing.expectError(error.BadCff, Cff.parse(&.{}));
}
