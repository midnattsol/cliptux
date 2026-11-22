//! The screen recording seam on Linux: the source (the GNOME Shell
//! extension's screencast of exactly the area, or a ScreenCast portal
//! session), its PipeWire streams, and the shell's own stop button.

const std = @import("std");
const dbus = @import("dbus.zig");
const gnome = @import("gnome.zig");
const shellrec = @import("gnome/shellrec.zig");
const pwstream = @import("pwstream.zig");
const source = @import("record/source.zig");
const types = @import("../api/record.zig");

pub const Want = types.Want;
pub const VideoFormat = types.VideoFormat;
pub const Raw = types.Raw;
pub const VideoFn = types.VideoFn;
pub const AudioFn = types.AudioFn;
pub const AudioSource = types.AudioSource;
pub const audio_rate = types.audio_rate;

/// The pictures and sound of a source, delivered to callbacks on threads
/// of their own: addVideo(node, ...), addAudio(which, ...), failed(),
/// videoFrames(), close().
pub const Stream = pwstream.Capture;

/// An opened source: `cap` and its video `node`, the stream's logical
/// rectangle and the part to keep; label(), close().
pub const Source = source.Source;
pub const Opened = source.Opened;

/// Open the source for `want` (asking for consent where needed; the
/// restore token is kept in `cfg`).
pub const open = source.open;

/// The shell shows its own stop button for recordings (GNOME's top bar),
/// so no floating control is needed in the picture.
pub fn shellHasControls(gpa: std.mem.Allocator, s: *dbus.Connection) bool {
    return gnome.isGnome() and shellrec.available(gpa, s);
}

/// Put the area picker up in the shell (it captures and starts `shotlet
/// --from-shell ... --then record`); true when it did.
pub fn pickInShell(gpa: std.mem.Allocator, s: *dbus.Connection) bool {
    if (!shellHasControls(gpa, s)) return false;
    if (shellrec.select(gpa, s)) {
        std.log.info("record: the picker is up through the GNOME integration", .{});
        return true;
    } else |err| std.log.info("record: GNOME integration: {t}", .{err});
    return false;
}

/// Listen for the shell's stop requests (its stop button, the record
/// shortcut again).
pub fn watchStop(s: *dbus.Connection) !void {
    return shellrec.watchStop(s);
}

/// What the session sent since the last call, without waiting: true when
/// it asked to stop.
pub fn pollStop(s: *dbus.Connection, gpa: std.mem.Allocator) bool {
    var stop = false;
    var n: usize = 0;
    while (n < 16) : (n += 1) {
        var msg = (s.nextMessageDeadline(@import("sys.zig").monoMs()) catch return false) orelse break;
        defer msg.deinit(gpa);
        if (shellrec.isStopRequest(&msg)) stop = true;
    }
    return stop;
}

comptime {
    _ = source;
    _ = pwstream;
}
