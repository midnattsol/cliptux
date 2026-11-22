//! The table's `record` command (record/cli.zig parses its options).

const spec = @import("spec.zig");

const options = [_]spec.Option{
    .{ .long = "region", .value = "X,Y,W,H", .kind = .rect, .help = "Record this area (logical pixels) without the picker" },
    .{ .long = "full", .help = "Record the whole monitor under the pointer" },
    .{ .long = "format", .value = "FORMAT", .kind = .choice, .choices = &.{ "mp4", "gif" }, .help = "mp4 or gif (default: the settings' record_format, mp4)" },
    .{ .long = "gif", .help = "Record a GIF (the same as --format gif)" },
    .{ .long = "mp4", .help = "Record an MP4 (the same as --format mp4)" },
    .{ .long = "fps", .value = "N", .kind = .int, .min = 1, .max = 60, .help = "Frames per second (MP4 15 to 60, GIF 10 to 30)" },
    .{ .long = "seconds", .value = "N", .kind = .int, .min = 1, .max = 1 << 20, .help = "Stop after N seconds" },
    .{ .long = "out", .value = "FILE", .kind = .file, .help = "Write to FILE (default: in the Videos folder)" },
    .{ .long = "mic", .help = "Record the microphone" },
    .{ .long = "system-audio", .help = "Record what the computer plays" },
    .{ .long = "clicks", .help = "Show mouse clicks" },
    .{ .long = "keys", .help = "Show the keys pressed (GNOME)" },
    .{ .long = "no-countdown", .help = "Start at once, without the countdown" },
    .{ .long = "no-control", .help = "No floating stop/pause control" },
    .{ .long = "stop", .help = "Stop the recording under way and keep it" },
    .{ .long = "pause", .help = "Pause the recording under way" },
    .{ .long = "resume", .help = "Resume a paused recording" },
    .{ .long = "discard", .help = "Stop the recording under way and throw it away" },
};

pub const list = [_]spec.Command{.{
    .id = .record,
    .name = "record",
    .group = .record,
    .summary = "Record an area or a screen as MP4 or GIF (again: stop)",
    .usage = &.{
        "record [--region X,Y,W,H | --full] [--format mp4|gif] [OPTION...]",
        "record --stop | --pause | --resume | --discard",
    },
    .description = "Pick an area (or a screen) and record it. While a recording runs, " ++
        "`shotlet record` again stops it, so one shortcut starts and stops. " ++
        "Options not given come from the settings (Settings > Recording); " ++
        "the picker's choices are remembered.",
    .options = &options,
    .examples = &.{
        .{ .cmd = "record", .what = "Pick an area, then record it" },
        .{ .cmd = "record --full --gif --seconds 5", .what = "A 5 second GIF of the screen" },
        .{ .cmd = "record --region 0,0,1280,720 --mic", .what = "An area, with the microphone" },
        .{ .cmd = "record --stop", .what = "Stop the recording under way" },
    },
}};
