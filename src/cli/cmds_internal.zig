//! The table's internal commands: Shotlet starts them itself (the
//! thumbnail, the video thumbnail, the trimmer, toasts), the build runs
//! man-page, and test-* are for development. Hidden from the help and
//! the completions; their arguments reach them unchecked.

const spec = @import("spec.zig");

fn internal(comptime id: spec.Id, comptime name: []const u8, comptime usage: []const u8, comptime summary: []const u8) spec.Command {
    return .{
        .id = id,
        .name = name,
        .group = .internal,
        .summary = summary,
        .usage = &.{usage},
        .passthrough = true,
        .examples = &.{.{ .cmd = usage, .what = summary }},
    };
}

pub const list = [_]spec.Command{
    internal(.quick, "quick", "quick ROOT ID [READY-FD]", "The floating thumbnail of a history entry"),
    internal(.quick_video, "quick-video", "quick-video ROOT ID", "The floating thumbnail of a recording"),
    internal(.trim, "trim", "trim ROOT ID [--range A,B] [--export]", "The recording trimmer"),
    internal(.toast, "toast", "toast TITLE [BODY]", "A short notice on the screen"),
    internal(.man_page, "man-page", "man-page", "Print the man page (roff)"),
    internal(.test_window, "test-window", "test-window", "A test window for 3 seconds"),
    internal(.test_grab, "test-grab", "test-grab", "Grab every monitor through the portal to a PNG"),
    internal(.test_font, "test-font", "test-font [LINES [OUT.png [FONT.ttf]]]", "Render sample text to a PNG"),
    internal(.test_decode, "test-decode", "test-decode FILE", "Decode and re-encode a PNG"),
};
