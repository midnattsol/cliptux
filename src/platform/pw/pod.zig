//! Hand-built SPA pods: the EnumFormat and crop Meta params we send, and a
//! bounds-checked walker over the object pods PipeWire sends back.

const std = @import("std");
const abi = @import("abi.zig");
const capture = @import("capture.zig");

const VideoFormat = abi.VideoFormat;

/// Little-endian u32 writer for hand-built SPA pods; refuses to overflow.
pub const PodWriter = struct {
    buf: []u8,
    pos: usize = 0,
    overflow: bool = false,

    pub fn put(self: *PodWriter, v: u32) void {
        if (self.pos + 4 > self.buf.len) {
            self.overflow = true;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    /// Patch the leading pod size and return the pod, or null on overflow.
    pub fn finish(self: *PodWriter) ?[]const u8 {
        if (self.overflow or self.pos < 8) return null;
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.pos - 8), .little);
        return self.buf[0..self.pos];
    }
};

/// Object pod header; the body size is patched by finish.
fn putObjectHeader(w: *PodWriter, object_type: u32, param_id: u32) void {
    w.put(0);
    w.put(abi.SPA_TYPE_Object);
    w.put(object_type);
    w.put(param_id);
}

/// A property holding one 4-byte value of `value_type`, padded to 8.
fn putScalarProp(w: *PodWriter, key: u32, value_type: u32, value: u32) void {
    w.put(key);
    w.put(0); // flags
    w.put(4);
    w.put(value_type);
    w.put(value);
    w.put(0); // pad
}

/// A Range choice property over 8-byte values (Rectangle or Fraction):
/// default, min, max.
fn putRangeProp(w: *PodWriter, key: u32, child_type: u32, values: [3][2]u32) void {
    w.put(key);
    w.put(0); // flags
    w.put(40); // 8 meta + 8 child + 3*8 values
    w.put(abi.SPA_TYPE_Choice);
    w.put(abi.SPA_CHOICE_Range);
    w.put(0);
    w.put(8); // child size
    w.put(child_type);
    for (values) |v| {
        w.put(v[0]);
        w.put(v[1]);
    }
}

/// format: enum choice over the 32-bit formats we can swizzle.
fn putVideoFormatChoice(w: *PodWriter) void {
    w.put(abi.SPA_FORMAT_VIDEO_format);
    w.put(0);
    w.put(36); // choice body: 8 meta + 8 child + 5*4 values
    w.put(abi.SPA_TYPE_Choice);
    w.put(abi.SPA_CHOICE_Enum);
    w.put(0);
    w.put(4); // child size
    w.put(abi.SPA_TYPE_Id);
    w.put(@backingInt(VideoFormat.BGRA)); // default
    w.put(@backingInt(VideoFormat.BGRA));
    w.put(@backingInt(VideoFormat.BGRx));
    w.put(@backingInt(VideoFormat.RGBA));
    w.put(@backingInt(VideoFormat.RGBx));
    w.put(0); // pad to 8
}

/// Build the EnumFormat pod: raw video in BGRA/BGRx/RGBA/RGBx at any size.
pub fn buildFormatPod(buf: []u8) ?[]const u8 {
    var w = PodWriter{ .buf = buf };
    putObjectHeader(&w, abi.SPA_TYPE_OBJECT_Format, abi.SPA_PARAM_EnumFormat);
    putScalarProp(&w, abi.SPA_FORMAT_mediaType, abi.SPA_TYPE_Id, abi.SPA_MEDIA_TYPE_video);
    putScalarProp(&w, abi.SPA_FORMAT_mediaSubtype, abi.SPA_TYPE_Id, abi.SPA_MEDIA_SUBTYPE_raw);
    putVideoFormatChoice(&w);
    // size: range 1x1 .. 16384x16384
    putRangeProp(&w, abi.SPA_FORMAT_VIDEO_size, abi.SPA_TYPE_Rectangle, .{ .{ 1920, 1080 }, .{ 1, 1 }, .{ 16384, 16384 } });
    // framerate: range 0/1 .. 1000/1 (variable)
    putRangeProp(&w, abi.SPA_FORMAT_VIDEO_framerate, abi.SPA_TYPE_Fraction, .{ .{ 25, 1 }, .{ 0, 1 }, .{ 1000, 1 } });
    return w.finish();
}

/// Build a Meta param asking the producer to attach VideoCrop regions.
pub fn buildCropMetaPod(buf: []u8) ?[]const u8 {
    var w = PodWriter{ .buf = buf };
    putObjectHeader(&w, abi.SPA_TYPE_OBJECT_ParamMeta, abi.SPA_PARAM_Meta);
    putScalarProp(&w, abi.SPA_PARAM_META_type, abi.SPA_TYPE_Id, abi.SPA_META_VideoCrop);
    putScalarProp(&w, abi.SPA_PARAM_META_size, abi.SPA_TYPE_Int, @sizeOf(abi.SpaMetaRegion));
    return w.finish();
}

/// Walk an object pod and call `visit(key, value_type, value_bytes)` for
/// each property, unwrapping fixated Choice values. Bounds-checked.
pub fn forEachProp(pod: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32, u32, []const u8) void) void {
    if (pod.len < 16) return;
    const body_size = std.mem.readInt(u32, pod[0..4], .little);
    const pod_type = std.mem.readInt(u32, pod[4..8], .little);
    if (pod_type != abi.SPA_TYPE_Object or body_size < 8) return;
    const end: usize = @min(pod.len, 8 + @as(usize, body_size));
    var pos: usize = 16; // skip pod header + object type/id
    while (pos + 16 <= end) {
        const key = std.mem.readInt(u32, pod[pos..][0..4], .little);
        const vsize: usize = std.mem.readInt(u32, pod[pos + 8 ..][0..4], .little);
        const vtype = std.mem.readInt(u32, pod[pos + 12 ..][0..4], .little);
        const vdata = pos + 16;
        if (vsize > end - vdata) break;
        // values may arrive wrapped in a Choice pod (None = fixated);
        // the payload then starts after choice meta (8) + child header (8)
        var val = pod[vdata..][0..vsize];
        var vt = vtype;
        if (vtype == abi.SPA_TYPE_Choice and vsize >= 20) {
            vt = std.mem.readInt(u32, pod[vdata + 12 ..][0..4], .little); // child type
            val = pod[vdata + 16 .. vdata + vsize];
        }
        visit(ctx, key, vt, val);
        pos = vdata + std.mem.alignForward(usize, vsize, 8);
    }
}

test "format pod is a well-formed EnumFormat object" {
    var buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&buf).?;
    try std.testing.expectEqual(@as(usize, 0), pod.len % 8);
    try std.testing.expectEqual(@as(u32, @intCast(pod.len - 8)), std.mem.readInt(u32, pod[0..4], .little));
    try std.testing.expectEqual(abi.SPA_TYPE_Object, std.mem.readInt(u32, pod[4..8], .little));
    try std.testing.expectEqual(abi.SPA_TYPE_OBJECT_Format, std.mem.readInt(u32, pod[8..12], .little));
    try std.testing.expectEqual(abi.SPA_PARAM_EnumFormat, std.mem.readInt(u32, pod[12..16], .little));

    // walking it finds every property at an 8-aligned offset
    const Seen = struct {
        keys: [8]u32 = undefined,
        n: usize = 0,
        fn visit(self: *@This(), key: u32, vt: u32, val: []const u8) void {
            _ = vt;
            _ = val;
            self.keys[self.n] = key;
            self.n += 1;
        }
    };
    var seen = Seen{};
    forEachProp(pod, &seen, Seen.visit);
    try std.testing.expectEqual(@as(usize, 5), seen.n);
    try std.testing.expectEqualSlices(u32, &.{
        abi.SPA_FORMAT_mediaType,
        abi.SPA_FORMAT_mediaSubtype,
        abi.SPA_FORMAT_VIDEO_format,
        abi.SPA_FORMAT_VIDEO_size,
        abi.SPA_FORMAT_VIDEO_framerate,
    }, seen.keys[0..5]);

    // a negotiated format pod (choices unwrapped) feeds the ctx
    var ctx = capture.Ctx{};
    forEachProp(pod, &ctx, capture.visitFormat);
    try std.testing.expectEqual(@as(u32, @backingInt(VideoFormat.BGRA)), ctx.format);
    try std.testing.expectEqual(@as(u32, 1920), ctx.width);
    try std.testing.expectEqual(@as(u32, 1080), ctx.height);

    // too small a buffer is reported, never overrun
    var tiny: [40]u8 align(8) = undefined;
    try std.testing.expect(buildFormatPod(&tiny) == null);
}

test "truncated or garbage pods are walked safely" {
    var buf: [256]u8 align(8) = undefined;
    const pod = buildFormatPod(&buf).?;
    var ctx = capture.Ctx{};
    var cut: usize = 0;
    while (cut < pod.len) : (cut += 4) forEachProp(pod[0..cut], &ctx, capture.visitFormat);
    var junk: [128]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (0..2000) |_| {
        prng.random().bytes(&junk);
        std.mem.writeInt(u32, junk[4..8], abi.SPA_TYPE_Object, .little);
        forEachProp(&junk, &ctx, capture.visitFormat);
    }
}
