//! The table's capture commands: the default capture, text and the
//! capture modes (app/modes/mode.zig).

const spec = @import("spec.zig");
const Command = spec.Command;
const Option = spec.Option;

const delay: Option = .{
    .long = "delay",
    .value = "SECONDS",
    .kind = .int,
    .max = 60,
    .choices = &.{ "3", "5", "10" },
    .help = "Count down SECONDS (0 to 60) first: the self-timer",
    .default = "0",
};

/// `shot` and `text`: development options and the GNOME extension's
/// hand-off (`shotlet --from-shell ID ...`).
const shot_options = [_]Option{
    .{ .long = "from", .value = "FILE", .kind = .file, .vis = .dev, .help = "Use a PNG instead of capturing the screen" },
    .{ .long = "sel", .value = "X,Y,W,H", .kind = .rect, .vis = .dev, .help = "Start with this area selected" },
    .{ .long = "smoke", .value = "MS", .kind = .int, .vis = .dev, .help = "Cancel by itself after MS milliseconds (leak checks)" },
    .{ .long = "from-monitors", .value = "FILES", .vis = .hidden, .help = "One PNG per monitor, comma separated, side by side" },
    .{ .long = "from-shell", .value = "ID", .vis = .hidden, .help = "A capture the GNOME Shell extension took" },
    .{ .long = "monitors", .value = "LAYOUT", .vis = .hidden, .help = "The extension's monitor layout" },
    .{ .long = "pieces", .value = "LAYOUT", .vis = .hidden, .help = "The extension's captured pieces" },
    .{ .long = "t0", .value = "MS", .kind = .int, .min = -(1 << 62), .max = 1 << 62, .vis = .hidden, .help = "When the shortcut was pressed" },
    .{ .long = "mode", .value = "MODE", .vis = .hidden, .help = "The capture mode the extension started" },
    .{ .long = "pointer", .value = "X,Y", .vis = .hidden, .help = "Where the pointer was" },
    .{ .long = "then", .value = "ACTION", .vis = .hidden, .help = "\"record\": the recording picker on this capture." },
};

fn mode(comptime id: spec.Id, comptime summary: []const u8, comptime description: []const u8) Command {
    return .{
        .id = id,
        .name = @tagName(id),
        .group = .capture,
        .summary = summary,
        .usage = &.{@tagName(id) ++ " [--delay SECONDS]"},
        .description = description,
        .options = &.{delay},
        .examples = &.{
            .{ .cmd = @tagName(id), .what = summary },
            .{ .cmd = @tagName(id) ++ " --delay 5", .what = "The same after a 5 second countdown" },
        },
    };
}

pub const list = [_]Command{
    .{
        .id = .shot,
        .name = "shot",
        .group = .capture,
        .summary = "Select an area and annotate it (also: shotlet shot)",
        .usage = &.{ "", "shot" },
        .description = "Captures the screen and opens the editor to select an area, annotate it " ++
            "and copy (Enter, Ctrl+C) or save it (Ctrl+S). Plain `shotlet` does the same.",
        .options = &shot_options,
        .examples = &.{
            .{ .cmd = "", .what = "Capture an area and annotate it" },
            .{ .cmd = "shot --from a.png --sel 0,0,800,600", .what = "a.png, an area selected" },
        },
    },
    mode(.fullscreen, "Capture the screen under the pointer", "Captures the monitor under the pointer (the first one where that is unknown) and does " ++
        "what after_fullscreen says in the settings: copy and show the thumbnail, copy, save, or the editor."),
    mode(.screens, "Capture all screens", "Captures every monitor as one image, laid out as on the desktop."),
    mode(.previous, "Capture the last area again", "Opens the editor with the area copied or saved last time selected again " ++
        "(remembered per monitor layout)."),
    mode(.window, "Capture a window", "Outlines the windows; a click captures just that window, with its corners " ++
        "and a shadow. Where the compositor tells nothing about windows, it selects an area instead."),
    mode(.scroll, "Capture a scrolling area", "Drag over what scrolls, then Start (or Enter): Shotlet scrolls it step by " ++
        "step and stitches the frames until the page stops moving or you press Stop."),
    .{
        .id = .timer,
        .name = "timer",
        .group = .capture,
        .summary = "Capture an area after a countdown (3, 5 or 10)",
        .usage = &.{"timer [SECONDS]"},
        .description = "A small countdown in the middle of the screen, then an area capture. " ++
            "Without SECONDS it counts timer_seconds from the settings.",
        .args = &.{.{
            .name = "SECONDS",
            .kind = .int,
            .max = 60,
            .choices = &.{ "3", "5", "10" },
            .help = "How long to count down (0 to 60; the settings offer 3, 5 and 10)",
        }},
        .examples = &.{
            .{ .cmd = "timer", .what = "Count down the configured seconds, then capture" },
            .{ .cmd = "timer 10", .what = "Count down 10 seconds" },
        },
    },
    mode(.area, "Select an area, optionally after a --delay", "Captures the screen and opens the editor to select an area, like `shotlet`, " ++
        "and takes the self-timer option."),
    .{
        .id = .text,
        .name = "text",
        .group = .capture,
        .summary = "Copy the text in an area (OCR)",
        .usage = &.{"text"},
        .description = "Select an area: the text in it is read locally (Tesseract, " ++
            "libtesseract.so.5) and copied to the clipboard.",
        .options = &shot_options,
        .examples = &.{.{ .cmd = "text", .what = "Select an area and copy its text" }},
    },
};
