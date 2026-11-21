//! Resolution of one isolating run sequence: weak types W1-W7, bracket
//! pairs N0, neutrals N1/N2, and the implicit levels I1/I2.

const classes = @import("classes.zig");
const brackets = @import("brackets.zig");
const Class = classes.Class;

/// W1-W7, N0-N2 on one isolating run sequence (`sos`, `eos`: the
/// directions at its ends; `e`: its embedding direction).
pub fn resolveSequence(cps: []const u21, types: []Class, sos: u1, eos: u1, e: u1) void {
    resolveWeak(types, sos);
    brackets.resolveBrackets(cps, types, e, sos);
    resolveNeutrals(types, sos, eos, e);
}

/// I1/I2.
pub fn implicitLevel(base: u8, t: Class) u8 {
    if (base % 2 == 0) {
        if (t == .R) return base + 1;
        if (t == .AN or t == .EN) return base + 2;
    } else if (t == .L or t == .EN or t == .AN) return base + 1;
    return base;
}

/// W1-W7.
fn resolveWeak(types: []Class, sos: u1) void {
    const e: Class = if (sos == 0) .L else .R;
    absorbMarks(types, e);
    arabicNumbers(types, e);
    for (types) |*t| {
        if (t.* == .AL) t.* = .R; // W3
    }
    joinSeparators(types);
    joinTerminators(types);
    // W6: remaining separators and terminators -> ON
    for (types) |*t| switch (t.*) {
        .ES, .ET, .CS => t.* = .ON,
        else => {},
    };
    europeanAfterLeft(types, e);
}

/// W1: NSM (and BN: formatting codes, ZWJ...) take the type of the
/// previous character (`e`, the sos type, at the start; ON after an
/// isolate).
fn absorbMarks(types: []Class, e: Class) void {
    var prev: Class = e;
    for (types) |*t| {
        if (t.* == .NSM or t.* == .BN) {
            t.* = if (prev == .LRI or prev == .RLI or prev == .FSI or prev == .PDI) .ON else prev;
        } else prev = t.*;
    }
}

/// W2: EN after AL (looking back to the last strong) -> AN.
fn arabicNumbers(types: []Class, e: Class) void {
    var last_strong: Class = e;
    for (types) |*t| {
        switch (t.*) {
            .L, .R, .AL => last_strong = t.*,
            .EN => if (last_strong == .AL) {
                t.* = .AN;
            },
            else => {},
        }
    }
}

/// W4: single separator between two numbers of the same kind.
fn joinSeparators(types: []Class) void {
    var i: usize = 1;
    while (i + 1 < types.len) : (i += 1) {
        const a = types[i - 1];
        const b = types[i + 1];
        if (types[i] == .ES and a == .EN and b == .EN) types[i] = .EN;
        if (types[i] == .CS and a == b and (a == .EN or a == .AN)) types[i] = a;
    }
}

/// W5: ET sequences next to EN become EN.
fn joinTerminators(types: []Class) void {
    const n = types.len;
    var i: usize = 0;
    while (i < n) {
        if (types[i] != .ET) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and types[j] == .ET) j += 1;
        const touches = (i > 0 and types[i - 1] == .EN) or (j < n and types[j] == .EN);
        if (touches) @memset(types[i..j], .EN);
        i = j;
    }
}

/// W7: EN after L (or sos L) -> L.
fn europeanAfterLeft(types: []Class, e: Class) void {
    var last_strong: Class = e;
    for (types) |*t| switch (t.*) {
        .L, .R => last_strong = t.*,
        .EN => if (last_strong == .L) {
            t.* = .L;
        },
        else => {},
    };
}

/// N1/N2: runs of neutrals take the surrounding direction when both
/// sides agree (numbers count as R), else the embedding direction.
fn resolveNeutrals(types: []Class, sos: u1, eos: u1, e_dir: u1) void {
    const n = types.len;
    const e: Class = if (e_dir == 0) .L else .R;
    var i: usize = 0;
    while (i < n) {
        if (!classes.isNeutral(types[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and classes.isNeutral(types[j])) j += 1;
        const before: u1 = if (i == 0) sos else classes.strongDir(types[i - 1]) orelse sos;
        const after: u1 = if (j == n) eos else classes.strongDir(types[j]) orelse eos;
        const d: Class = if (before == after) (if (before == 0) .L else .R) else e;
        @memset(types[i..j], d);
        i = j;
    }
}
