//! The screen recorder's unit tests, in one place for main.zig.

test {
    _ = @import("../encode/quantize.zig");
    _ = @import("../encode/lzw.zig");
    _ = @import("../encode/gif.zig");
    _ = @import("../encode/gifdec.zig");
    _ = @import("../encode/yuv.zig");
    _ = @import("../encode/av.zig");
    _ = @import("../encode/av_mp4.zig");
}
