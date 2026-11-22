//! The screen recording seam's platform-neutral types: what to record,
//! and the pictures and sound a source delivers (on its own threads).

const region = @import("../../record/region.zig");

/// What to record: an area of the desktop (logical), and whether the
/// source should show clicks and key presses where it can.
pub const Want = struct {
    area: region.Rect,
    clicks: bool = false,
    keys: bool = false,
};

/// Pixel layouts of the pictures (values: SPA's, as PipeWire names them).
pub const VideoFormat = enum(u32) {
    RGBx = 7,
    BGRx = 8,
    RGBA = 11,
    BGRA = 12,
    _,
};

/// A picture as delivered: the valid area of the frame.
pub const Raw = struct {
    base: [*]const u8,
    /// bytes per row
    stride: usize,
    width: u32,
    height: u32,
    format: VideoFormat,
    /// the monotonic clock (api.sys.monoNs), ns
    time_ns: i64,
};

pub const VideoFn = *const fn (ctx: *anyopaque, raw: *const Raw) void;
/// Interleaved stereo 16-bit samples at `audio_rate`; time of the first.
pub const AudioFn = *const fn (ctx: *anyopaque, samples: []const i16, time_ns: i64) void;

/// The microphone, or what the speakers play.
pub const AudioSource = enum { mic, system };

/// Samples per second of the sound delivered.
pub const audio_rate = 48000;
