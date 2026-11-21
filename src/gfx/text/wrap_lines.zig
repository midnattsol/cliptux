//! Wrapping paragraphs into lines with the shaped widths, with a small
//! cache of recent results.

const std = @import("std");
const ttf = @import("../ttf.zig");
const bidi = @import("../bidi.zig");
const render = @import("../render.zig");
const wrap_mod = @import("../wrap.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const measure = @import("measure.zig");

const Canvas = render.Canvas;
const Style = state_mod.Style;

pub const Line = wrap_mod.Line;

const MeasureCtx = struct { size: f64, style: Style, para: []const u8, dir: bidi.Direction };

/// Width of `sub` (a slice of the paragraph) as part of the shaped
/// paragraph, so joining forms at a break are the unbroken word's.
fn measureFor(ctx: MeasureCtx, sub: []const u8) f64 {
    const a = @intFromPtr(sub.ptr) - @intFromPtr(ctx.para.ptr);
    const st = if (state_mod.state) |*p| p else return @floatFromInt(Canvas.textWidth(state_mod.bitmapScale(ctx.size), sub));
    if (!(ctx.size > 0 and ctx.size <= ttf.max_size_px)) return 0;
    layout.ensureShaped(st, ctx.size, ctx.style, ctx.para, ctx.dir) catch return @floatFromInt(measure.widthStyled(ctx.size, ctx.style, sub));
    return layout.rangeAdvance(st, a, a + sub.len);
}

const WrapKey = struct { hash: u64, len: usize, size: u64, style: Style, max_w: i32, dir: bidi.Direction };
const WrapEntry = struct { key: WrapKey, lines: []Line };
var wrap_cache: [8]?WrapEntry = @splat(null);
var wrap_next: usize = 0;
var wrap_alloc: ?std.mem.Allocator = null;

pub fn clearCache() void {
    const a = wrap_alloc orelse return;
    for (&wrap_cache) |*e| {
        if (e.*) |x| a.free(x.lines);
        e.* = null;
    }
}

fn cached(key: WrapKey) ?[]Line {
    for (wrap_cache) |e| {
        const x = e orelse continue;
        if (std.meta.eql(x.key, key)) return x.lines;
    }
    return null;
}

/// Remember a copy of `lines` for `key`, evicting the oldest entry.
fn remember(alloc: std.mem.Allocator, key: WrapKey, lines: []const Line) void {
    const copy = alloc.dupe(Line, lines) catch return;
    wrap_alloc = alloc;
    if (wrap_cache[wrap_next]) |old| alloc.free(old.lines);
    wrap_cache[wrap_next] = .{ .key = key, .lines = copy };
    wrap_next = (wrap_next + 1) % wrap_cache.len;
}

/// Visual lines of paragraph `s` (no newlines) in a box `max_w` pixels
/// wide: breaks after spaces and hyphens and around CJK, long words cut
/// between graphemes (see wrap.zig). Appended to `out`. Recent results are
/// cached, since boxes are laid out on every frame.
pub fn wrapLines(alloc: std.mem.Allocator, size_px: f64, style: Style, s: []const u8, max_w: i32, dir: bidi.Direction, out: *std.ArrayList(Line)) !void {
    const key: WrapKey = .{ .hash = std.hash.Wyhash.hash(0, s), .len = s.len, .size = @bitCast(size_px), .style = style, .max_w = max_w, .dir = dir };
    const cacheable = state_mod.state != null;
    if (cacheable) if (cached(key)) |lines| return out.appendSlice(alloc, lines);
    const first = out.items.len;
    try wrap_mod.wrap(alloc, s, @floatFromInt(max_w), MeasureCtx{ .size = size_px, .style = style, .para = s, .dir = dir }, measureFor, out);
    if (cacheable) remember(state_mod.state.?.alloc, key, out.items[first..]);
}
