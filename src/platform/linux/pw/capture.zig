//! One capture stream's state and its PipeWire callbacks: learn the
//! negotiated format, then copy the first good buffer's valid area into a
//! tight pixel array. Callbacks run on PipeWire's loop thread.

const std = @import("std");
const abi = @import("abi.zig");
const pod = @import("pod.zig");
const pw = @import("../pw.zig");

const VideoFormat = abi.VideoFormat;
const SpaMetaRegion = abi.SpaMetaRegion;

pub const Frame = struct {
    width: u32,
    height: u32,
    /// 0xAARRGGBB; allocated with page_allocator
    pixels: []u32,

    pub fn deinit(self: *Frame) void {
        std.heap.page_allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const Ctx = struct {
    loop: ?*anyopaque = null,
    stream: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    /// tight 4-byte pixels of the (cropped) frame; page_allocator
    pixels: ?[]u32 = null,
    out_w: u32 = 0,
    out_h: u32 = 0,
    done: bool = false,
    failed: bool = false,
};

/// The listener every capture stream registers, with its Ctx as data.
pub const events = abi.StreamEvents{
    .state_changed = onStateChanged,
    .param_changed = onParamChanged,
    .process = onProcess,
};

pub fn visitFormat(ctx: *Ctx, key: u32, vt: u32, val: []const u8) void {
    if (key == abi.SPA_FORMAT_VIDEO_format and vt == abi.SPA_TYPE_Id and val.len >= 4) {
        ctx.format = std.mem.readInt(u32, val[0..4], .little);
    } else if (key == abi.SPA_FORMAT_VIDEO_size and vt == abi.SPA_TYPE_Rectangle and val.len >= 8) {
        ctx.width = std.mem.readInt(u32, val[0..4], .little);
        ctx.height = std.mem.readInt(u32, val[4..8], .little);
    }
}

fn onParamChanged(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    std.log.debug("pw param_changed id={d} param={}", .{ id, param != null });
    if (id != abi.SPA_PARAM_Format or param == null) return;
    // parse the negotiated format object pod
    const head: [*]const u8 = @ptrCast(param.?);
    const body_size = std.mem.readInt(u32, head[0..4], .little);
    if (body_size > 64 * 1024) return;
    pod.forEachProp(head[0 .. 8 + @as(usize, body_size)], ctx, visitFormat);

    // ask for crop regions: some producers send a larger buffer and mark
    // the valid area with SPA_META_VideoCrop
    var meta_buf: [96]u8 align(8) = undefined;
    if (pod.buildCropMetaPod(&meta_buf)) |meta| {
        const params = [_][*]const u8{meta.ptr};
        _ = pw.api.stream_update_params(ctx.stream, &params, 1);
    }
}

fn onStateChanged(data: ?*anyopaque, old: c_int, new: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    std.log.debug("pw state {d} -> {d}", .{ old, new });
    if (new == abi.PW_STREAM_STATE_ERROR) {
        std.log.warn("pipewire stream error: {s}", .{if (msg) |m| std.mem.span(m) else "?"});
        ctx.failed = true;
        pw.api.thread_loop_signal(ctx.loop, false);
    }
}

/// The valid area of a buffer: its VideoCrop region when the producer
/// attached a sensible one, else the whole negotiated frame.
pub fn cropRegion(sb: *const abi.SpaBuffer, width: u32, height: u32) SpaMetaRegion {
    const full = SpaMetaRegion{ .x = 0, .y = 0, .width = width, .height = height };
    const metas = sb.metas orelse return full;
    for (metas[0..sb.n_metas]) |m| {
        if (m.type != abi.SPA_META_VideoCrop or m.size < @sizeOf(SpaMetaRegion)) continue;
        const r: *const SpaMetaRegion = @ptrCast(@alignCast(m.data orelse continue));
        if (r.width == 0 or r.height == 0 or r.x < 0 or r.y < 0) return full;
        const x: u32 = @intCast(r.x);
        const y: u32 = @intCast(r.y);
        if (x >= width or y >= height or r.width > width - x or r.height > height - y) return full;
        return r.*;
    }
    return full;
}

/// Where a buffer's valid area sits in its mapped memory.
const Source = struct {
    base: [*]const u8,
    /// byte offset of the crop's first pixel
    first: usize,
    stride: usize,
    crop: SpaMetaRegion,
};

/// Locate the valid area of a buffer, or null to skip the buffer (empty,
/// corrupted, unmapped, or smaller than the frame it claims to hold).
inline fn frameSource(ctx: *const Ctx, sb: *const abi.SpaBuffer) ?Source {
    if (sb.n_datas < 1) return null;
    const d = sb.datas.?[0];
    const chunk = d.chunk orelse return null;
    // an empty or corrupted buffer is skipped; the next one will do
    if (chunk.size == 0 or (chunk.flags & abi.SPA_CHUNK_FLAG_CORRUPTED) != 0) {
        std.log.debug("pw: skipping empty/corrupted buffer", .{});
        return null;
    }
    const src_base: [*]const u8 = @ptrCast(d.data orelse return null);
    if (ctx.width == 0 or ctx.height == 0) return null;
    const stride: usize = if (chunk.stride > 0) @intCast(chunk.stride) else ctx.width * 4;
    if (stride < @as(usize, ctx.width) * 4) return null;
    const crop = cropRegion(sb, ctx.width, ctx.height);
    // never read past the mapped buffer or the chunk, whatever they claim
    const avail = @min(@as(usize, d.maxsize), @as(usize, chunk.offset) + chunk.size);
    const first = @as(usize, chunk.offset) + @as(usize, @intCast(crop.y)) * stride + @as(usize, @intCast(crop.x)) * 4;
    const needed = first + (@as(usize, crop.height) - 1) * stride + @as(usize, crop.width) * 4;
    if (needed > avail) {
        std.log.debug("pw: buffer smaller than the frame ({d} < {d}); skipping", .{ avail, needed });
        return null;
    }
    return .{ .base = src_base, .first = first, .stride = stride, .crop = crop };
}

/// Copy the valid area row by row into a new tight pixel array, then
/// mark the ctx done (or failed when out of memory) and wake the waiter.
fn copyFrame(ctx: *Ctx, src: Source) void {
    const crop = src.crop;
    const n: usize = @as(usize, crop.width) * crop.height;
    const pixels = std.heap.page_allocator.alloc(u32, n) catch {
        ctx.failed = true;
        pw.api.thread_loop_signal(ctx.loop, false);
        return;
    };
    const dst_bytes = std.mem.sliceAsBytes(pixels);
    const row_bytes = @as(usize, crop.width) * 4;
    var y: usize = 0;
    while (y < crop.height) : (y += 1) {
        const src_row = src.base[src.first + y * src.stride ..][0..row_bytes];
        @memcpy(dst_bytes[y * row_bytes ..][0..row_bytes], src_row);
    }
    ctx.pixels = pixels;
    ctx.out_w = crop.width;
    ctx.out_h = crop.height;
    ctx.done = true;
    pw.api.thread_loop_signal(ctx.loop, false);
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    const stream = ctx.stream orelse return;
    const b = pw.api.stream_dequeue_buffer(stream) orelse return;
    defer _ = pw.api.stream_queue_buffer(stream, b);
    if (ctx.done or ctx.failed) return;
    const sb = b.buffer orelse return;
    const src = frameSource(ctx, sb) orelse return;
    copyFrame(ctx, src);
}

/// Turn a captured ctx into an opaque 0xAARRGGBB Frame (in place); frees
/// the pixels on an unsupported format.
pub fn finishFrame(ctx: *Ctx) !Frame {
    const pixels = ctx.pixels.?;
    switch (@as(VideoFormat, @fromBackingInt(@intCast(ctx.format)))) {
        .BGRA, .BGRx => for (pixels) |*p| {
            p.* |= 0xFF000000;
        },
        .RGBA, .RGBx => for (pixels) |*p| {
            const v = p.*;
            p.* = 0xFF000000 | ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF);
        },
        else => {
            std.heap.page_allocator.free(pixels);
            return error.UnsupportedFormat;
        },
    }
    return .{ .width = ctx.out_w, .height = ctx.out_h, .pixels = pixels };
}

test "crop meta pod and crop region validation" {
    var buf: [64]u8 align(8) = undefined;
    const p = pod.buildCropMetaPod(&buf).?;
    try std.testing.expectEqual(@as(usize, 64), p.len);
    try std.testing.expectEqual(abi.SPA_TYPE_OBJECT_ParamMeta, std.mem.readInt(u32, p[8..12], .little));
    try std.testing.expectEqual(abi.SPA_META_VideoCrop, std.mem.readInt(u32, p[32..36], .little));

    var region = SpaMetaRegion{ .x = 10, .y = 20, .width = 100, .height = 50 };
    var metas = [_]abi.SpaMeta{.{ .type = abi.SPA_META_VideoCrop, .size = @sizeOf(SpaMetaRegion), .data = &region }};
    var sb = abi.SpaBuffer{ .n_metas = 1, .n_datas = 0, .metas = &metas, .datas = null };
    const r = cropRegion(&sb, 200, 100);
    try std.testing.expectEqual(@as(u32, 100), r.width);
    try std.testing.expectEqual(@as(i32, 20), r.y);
    // out of bounds falls back to the full frame
    region.width = 300;
    try std.testing.expectEqual(@as(u32, 200), cropRegion(&sb, 200, 100).width);
}
