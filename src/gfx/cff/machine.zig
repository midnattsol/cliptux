//! The Type 2 charstring interpreter: runs a glyph's charstring (and the
//! subroutines it calls) and emits its outline into a sink. On the text
//! hot path: operator groups are small inline helpers of one loop.
//! Machine(Sink) only declares the state; the operations below take
//! `self: anytype`, always a *Machine(Sink).

const std = @import("std");
const cff = @import("../cff.zig");
const Cff = cff.Cff;
const Index = cff.Index;
const rd8 = cff.rd8;
const rd16 = cff.rd16;
const rdN = cff.rdN;

fn bias(n: u32) i32 {
    return if (n < 1240) 107 else if (n < 33900) 1131 else 32768;
}

/// Interpreter state for one glyph, emitting into a `Sink` (moveTo,
/// lineTo, cubicTo, close).
pub fn Machine(comptime Sink: type) type {
    return struct {
        cff: *const Cff,
        lsubrs: Index,
        sink: Sink,
        stack: [48]f64 = undefined,
        sp: usize = 0,
        x: f64 = 0,
        y: f64 = 0,
        nstems: usize = 0,
        seen_width: bool = false,
        open: bool = false,
        ops: u32 = 0,
        done: bool = false,

        /// Runs `code` (a charstring) at subr nesting `depth`.
        pub const run = runCharstring;
        pub const closePath = closeOpenPath;
    };
}

const max_ops = 200_000;

/// Sinks may fail with BadGlyph (too complex) or OutOfMemory.
const RunError = error{ BadCff, BadGlyph, OutOfMemory };

/// What the interpreter does after an operator.
const Flow = enum {
    /// clear the operand stack and go on
    clear,
    /// go on keeping the stack (operands a subr left there)
    keep,
    /// return from this (sub)charstring
    ret,
};

fn push(self: anytype, v: f64) !void {
    if (self.sp >= self.stack.len) return error.BadCff;
    self.stack[self.sp] = v;
    self.sp += 1;
}

/// The first stack-clearing operator may carry the advance width as
/// an extra leading operand; drop it (we use hmtx).
fn args(self: anytype, odd_means_width: bool) []const f64 {
    var s: []const f64 = self.stack[0..self.sp];
    if (!self.seen_width) {
        self.seen_width = true;
        if (odd_means_width and s.len > 0) s = s[1..];
    }
    return s;
}

fn closeOpenPath(self: anytype) !void {
    if (self.open) try self.sink.close();
    self.open = false;
}

fn moveTo(self: anytype, dx: f64, dy: f64) !void {
    try closeOpenPath(self);
    self.x += dx;
    self.y += dy;
    try self.sink.moveTo(self.x, self.y);
    self.open = true;
}

fn lineTo(self: anytype, dx: f64, dy: f64) !void {
    if (!self.open) try moveTo(self, 0, 0);
    self.x += dx;
    self.y += dy;
    try self.sink.lineTo(self.x, self.y);
}

fn curveTo(self: anytype, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) !void {
    if (!self.open) try moveTo(self, 0, 0);
    const x1 = self.x + dx1;
    const y1 = self.y + dy1;
    const x2 = x1 + dx2;
    const y2 = y1 + dy2;
    self.x = x2 + dx3;
    self.y = y2 + dy3;
    try self.sink.cubicTo(x1, y1, x2, y2, self.x, self.y);
}

fn stems(self: anytype) void {
    const s = args(self, self.sp % 2 == 1);
    self.nstems += s.len / 2;
    self.sp = 0;
}

fn runCharstring(self: anytype, code: []const u8, depth: u8) RunError!void {
    if (depth > 10) return error.BadCff;
    var i: usize = 0;
    while (i < code.len and !self.done) {
        self.ops += 1;
        if (self.ops > max_ops) return error.BadCff;
        const b = code[i];
        i += 1;
        if (b >= 32 or b == 28) {
            i = try pushOperand(self, code, i, b);
            continue;
        }
        switch (try operator(self, code, &i, b, depth)) {
            .clear => self.sp = 0,
            .keep => {},
            .ret => return,
        }
    }
}

/// Pushes the number encoded by `b` and the bytes from `i`;
/// returns the offset after it.
inline fn pushOperand(self: anytype, code: []const u8, i: usize, b: u8) RunError!usize {
    if (b == 28) {
        try push(self, @floatFromInt(@as(i16, @bitCast(try rd16(code, i)))));
        return i + 2;
    }
    if (b <= 246) {
        try push(self, @floatFromInt(@as(i32, b) - 139));
        return i;
    } else if (b <= 250) {
        try push(self, @floatFromInt((@as(i32, b) - 247) * 256 + @as(i32, try rd8(code, i)) + 108));
        return i + 1;
    } else if (b <= 254) {
        try push(self, @floatFromInt(-(@as(i32, b) - 251) * 256 - @as(i32, try rd8(code, i)) - 108));
        return i + 1;
    }
    const v: i32 = @bitCast(try rdN(code, i, 4));
    try push(self, @as(f64, @floatFromInt(v)) / 65536.0);
    return i + 4;
}

/// Runs operator `b`; `i` is past it and may advance over its
/// inline data (hint masks, the escaped operator byte).
inline fn operator(self: anytype, code: []const u8, i: *usize, b: u8, depth: u8) RunError!Flow {
    const s = self.stack[0..self.sp];
    switch (b) {
        1, 3, 18, 23 => stems(self), // hstem vstem hstemhm vstemhm
        19, 20 => try hintMask(self, code, i), // hintmask cntrmask
        21, 22, 4 => try moveOp(self, b), // rmoveto hmoveto vmoveto
        5, 6, 7 => try lineOp(self, b, s), // rlineto hlineto vlineto
        8, 24, 25 => try rcurveOp(self, b, s), // rrcurveto rcurveline rlinecurve
        26, 27 => try hvvhCurveTo(self, b == 27, s), // vvcurveto hhcurveto
        30, 31 => try alternatingCurveTo(self, b == 31, s), // vhcurveto hvcurveto
        10, 29 => { // callsubr callgsubr
            try callSubr(self, if (b == 10) self.lsubrs else self.cff.gsubrs, depth);
            return .keep; // operands left by the subr stay on the stack
        },
        11 => return .ret, // return
        14 => { // endchar
            _ = args(self, self.sp == 1 or self.sp == 5);
            try closeOpenPath(self);
            self.done = true;
        },
        12 => {
            const op2 = try rd8(code, i.*);
            i.* += 1;
            try escape(self, op2, s);
        },
        else => {}, // reserved
    }
    return .clear;
}

/// hintmask/cntrmask: an implicit vstem first, then skip the mask.
inline fn hintMask(self: anytype, code: []const u8, i: *usize) RunError!void {
    if (self.sp > 0) stems(self);
    self.seen_width = true;
    i.* += (self.nstems + 7) / 8;
    if (i.* > code.len) return error.BadCff;
}

inline fn moveOp(self: anytype, b: u8) RunError!void {
    if (b == 21) { // rmoveto
        const a = args(self, self.sp > 2);
        if (a.len < 2) return error.BadCff;
        return moveTo(self, a[0], a[1]);
    }
    const a = args(self, self.sp > 1);
    if (a.len < 1) return error.BadCff;
    if (b == 22) try moveTo(self, a[0], 0) else try moveTo(self, 0, a[0]);
}

/// rlineto; hlineto and vlineto alternate direction.
inline fn lineOp(self: anytype, b: u8, s: []const f64) RunError!void {
    if (b == 5) {
        var k: usize = 0;
        while (k + 1 < s.len) : (k += 2) try lineTo(self, s[k], s[k + 1]);
        return;
    }
    var horiz = b == 6;
    for (s) |v| {
        if (horiz) try lineTo(self, v, 0) else try lineTo(self, 0, v);
        horiz = !horiz;
    }
}

/// rrcurveto, rcurveline (curves then a line), rlinecurve (lines
/// then a curve).
inline fn rcurveOp(self: anytype, b: u8, s: []const f64) RunError!void {
    if (b != 8 and s.len < 8) return error.BadCff;
    switch (b) {
        8 => try curves(self, s),
        24 => {
            try curves(self, s[0 .. s.len - 2]);
            try lineTo(self, s[s.len - 2], s[s.len - 1]);
        },
        else => {
            var k: usize = 0;
            while (k + 1 < s.len - 6) : (k += 2) try lineTo(self, s[k], s[k + 1]);
            const c = s[s.len - 6 ..];
            try curveTo(self, c[0], c[1], c[2], c[3], c[4], c[5]);
        },
    }
}

/// Relative curves, six operands each.
inline fn curves(self: anytype, s: []const f64) RunError!void {
    var k: usize = 0;
    while (k + 5 < s.len) : (k += 6) try curveTo(self, s[k], s[k + 1], s[k + 2], s[k + 3], s[k + 4], s[k + 5]);
}

/// hhcurveto (`horiz`) or vvcurveto: curves that start and end
/// along one axis, an odd first operand bending the first one.
inline fn hvvhCurveTo(self: anytype, horiz: bool, s: []const f64) RunError!void {
    var k: usize = 0;
    var f: f64 = 0;
    if (s.len % 2 == 1) {
        f = s[0];
        k = 1;
    }
    while (k + 3 < s.len) : (k += 4) {
        if (horiz) {
            try curveTo(self, s[k], f, s[k + 1], s[k + 2], s[k + 3], 0);
        } else {
            try curveTo(self, f, s[k], s[k + 1], s[k + 2], 0, s[k + 3]);
        }
        f = 0;
    }
}

/// hvcurveto (`horiz` first) or vhcurveto: curves alternating
/// between horizontal and vertical tangents.
inline fn alternatingCurveTo(self: anytype, first_horiz: bool, s: []const f64) RunError!void {
    var horiz = first_horiz;
    var k: usize = 0;
    while (k + 3 < s.len) : (k += 4) {
        const last: f64 = if (s.len - k == 5) s[k + 4] else 0;
        if (horiz) {
            try curveTo(self, s[k], 0, s[k + 1], s[k + 2], last, s[k + 3]);
        } else {
            try curveTo(self, 0, s[k], s[k + 1], s[k + 2], s[k + 3], last);
        }
        horiz = !horiz;
    }
}

/// Pops a biased subr number and runs that subr of `idx`.
fn callSubr(self: anytype, idx: Index, depth: u8) RunError!void {
    if (self.sp < 1) return error.BadCff;
    self.sp -= 1;
    const n = self.stack[self.sp];
    if (!(n > -40000 and n < 40000)) return error.BadCff;
    const k = @as(i32, @intFromFloat(n)) + bias(idx.count);
    if (k < 0) return error.BadCff;
    try runCharstring(self, try idx.get(@intCast(k)), depth + 1);
}

fn escape(self: anytype, op: u8, s: []const f64) RunError!void {
    switch (op) {
        35 => { // flex
            if (s.len < 12) return error.BadCff;
            try curveTo(self, s[0], s[1], s[2], s[3], s[4], s[5]);
            try curveTo(self, s[6], s[7], s[8], s[9], s[10], s[11]);
        },
        34 => { // hflex
            if (s.len < 7) return error.BadCff;
            try curveTo(self, s[0], 0, s[1], s[2], s[3], 0);
            try curveTo(self, s[4], 0, s[5], -s[2], s[6], 0);
        },
        36 => { // hflex1
            if (s.len < 9) return error.BadCff;
            try curveTo(self, s[0], s[1], s[2], s[3], s[4], 0);
            try curveTo(self, s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
        },
        37 => try flex1(self, s),
        else => {}, // arithmetic and storage operators: unused in practice
    }
}

/// flex1: the last point moves along the larger overall delta.
fn flex1(self: anytype, s: []const f64) RunError!void {
    if (s.len < 11) return error.BadCff;
    var dx: f64 = 0;
    var dy: f64 = 0;
    var k: usize = 0;
    while (k < 10) : (k += 2) {
        dx += s[k];
        dy += s[k + 1];
    }
    try curveTo(self, s[0], s[1], s[2], s[3], s[4], s[5]);
    if (@abs(dx) > @abs(dy)) {
        try curveTo(self, s[6], s[7], s[8], s[9], s[10], -dy);
    } else {
        try curveTo(self, s[6], s[7], s[8], s[9], -dx, s[10]);
    }
}
