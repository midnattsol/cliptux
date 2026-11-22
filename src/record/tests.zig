//! The screen recorder's unit tests, in one place for main.zig.

test {
    _ = @import("../encode/quantize.zig");
    _ = @import("../encode/lzw.zig");
    _ = @import("../encode/gif.zig");
    _ = @import("../encode/gifdec.zig");
    _ = @import("../encode/yuv.zig");
    _ = @import("../encode/av.zig");
    _ = @import("../encode/av_mp4.zig");
    _ = @import("../encode/proc.zig");
    _ = @import("../encode/ffmpeg_proc.zig");
    _ = @import("../encode/sink.zig");
    _ = @import("timeline.zig");
    _ = @import("region.zig");
    _ = @import("sync.zig");
    _ = @import("../platform/linux/pwstream.zig");
    _ = @import("audio.zig");
    _ = @import("frames.zig");
    _ = @import("strip.zig");
    _ = @import("engine.zig");
    _ = @import("settings.zig");
    _ = @import("keepvid.zig");
    _ = @import("ctlsock.zig");
    _ = @import("../platform/linux/record/source.zig");
    _ = @import("cli.zig");
    _ = @import("run.zig");
    _ = @import("files.zig");
    _ = @import("quickvid.zig");
    _ = @import("../ui/recui/vidcard.zig");
    _ = @import("trim.zig");
    _ = @import("../ui/recui/trimui.zig");
    _ = @import("../ui/recui/trim_draw.zig");
    _ = @import("../ui/recui/settings_rec.zig");
    _ = @import("../ui/settings_steps.zig");
    _ = @import("../ui/recui/control.zig");
    _ = @import("../ui/recui/control_draw.zig");
    _ = @import("../ui/recui/glyphs.zig");
    _ = @import("../ui/recui/picker.zig");
    _ = @import("../ui/recui/picker_bar.zig");
    _ = @import("../ui/recui/picker_sel.zig");
}
