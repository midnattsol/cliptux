//! The screen recording seam of the contract (api/record.zig): a source
//! of an area's pictures and sound, delivered to callbacks on threads of
//! its own, and the shell's own recording controls where it has them.

const std = @import("std");
const types = @import("../api/record.zig");
const desktop = @import("desktop.zig");
const config = @import("../../app/config.zig");
const region = @import("../../record/region.zig");

pub const Want = types.Want;
pub const VideoFormat = types.VideoFormat;
pub const Raw = types.Raw;
pub const VideoFn = types.VideoFn;
pub const AudioFn = types.AudioFn;
pub const AudioSource = types.AudioSource;
pub const audio_rate = types.audio_rate;

/// The pictures and sound of a source.
pub const Stream = struct {
    /// Deliver the pictures of stream `node` to `cb`.
    pub fn addVideo(self: *Stream, node: u32, cb: VideoFn, ctx: *anyopaque) error{Unavailable}!void {
        _ = .{ self, node, cb, ctx };
        return error.Unavailable;
    }
    /// Deliver `which` sound to `cb`.
    pub fn addAudio(self: *Stream, which: AudioSource, cb: AudioFn, ctx: *anyopaque) error{Unavailable}!void {
        _ = .{ self, which, cb, ctx };
        return error.Unavailable;
    }
    /// Whether a stream reported an error.
    pub fn failed(self: *const Stream) bool {
        _ = self;
        return true;
    }
    pub fn videoFrames(self: *const Stream) u64 {
        _ = self;
        return 0;
    }
    pub fn close(self: *Stream, gpa: std.mem.Allocator) void {
        _ = .{ self, gpa };
    }
};

/// An opened source: its stream and video node, the stream's logical
/// rectangle and the part of it to keep.
pub const Source = struct {
    cap: *Stream,
    node: u32,
    stream_rect: region.Rect,
    crop: ?region.Rect,

    pub fn label(self: *const Source) []const u8 {
        _ = self;
        return "";
    }
    /// After the engine stopped.
    pub fn close(self: *Source, gpa: std.mem.Allocator, s: *desktop.Session) void {
        _ = .{ self, gpa, s };
    }
};
pub const Opened = union(enum) { ok: Source, cancelled, failed: anyerror };

/// Open the source for `want` (asking for consent where needed; what lets
/// the next one skip asking is kept in `cfg`).
pub fn open(gpa: std.mem.Allocator, s: *desktop.Session, home: []const u8, cfg: *config.Config, want: Want) Opened {
    _ = .{ gpa, s, home, cfg, want };
    return .{ .failed = error.Unavailable };
}
/// The shell shows its own stop button for recordings.
pub fn shellHasControls(gpa: std.mem.Allocator, s: *desktop.Session) bool {
    _ = .{ gpa, s };
    return false;
}
/// Put the area picker up in the shell; true when it did.
pub fn pickInShell(gpa: std.mem.Allocator, s: *desktop.Session) bool {
    _ = .{ gpa, s };
    return false;
}
/// Listen for the shell's stop requests.
pub fn watchStop(s: *desktop.Session) error{Unavailable}!void {
    _ = s;
}
/// True when the session asked to stop since the last call.
pub fn pollStop(s: *desktop.Session, gpa: std.mem.Allocator) bool {
    _ = .{ s, gpa };
    return false;
}
