//! The table's editing, history, settings and integration commands.

const spec = @import("spec.zig");
const Command = spec.Command;

const smoke: spec.Option = .{ .long = "smoke", .value = "MS", .kind = .int, .vis = .dev, .help = "Close by itself after MS milliseconds (leak checks)" };

const shortcut_words = [_][]const u8{ "area", "fullscreen", "screens", "previous", "window", "scroll", "timer", "thumbnail", "none" };

const gnome_subs = [_]Command{
    .{
        .id = .gnome_status,
        .name = "status",
        .group = .settings,
        .summary = "Whether the extension is installed and active (default)",
        .usage = &.{"gnome-integration status"},
        .description = "Shows the desktop, the extension's state (not installed, disabled, loads at the next login, active), how captures go and the capture shortcut.",
        .examples = &.{.{ .cmd = "gnome-integration status", .what = "Show the integration's state" }},
    },
    .{
        .id = .gnome_install,
        .name = "install",
        .group = .settings,
        .summary = "Install and enable the GNOME Shell extension",
        .usage = &.{"gnome-integration install [--move-shortcut | --keep-shortcut]"},
        .description = "Installs the extension that captures without consent dialogs and keeps the thumbnail and pins above other windows. " ++
            "GNOME Shell loads a new extension at the next login. On a terminal it asks whether to give the Print key to Shotlet.",
        .options = &.{
            .{ .long = "move-shortcut", .help = "Give Print (and custom shortcuts running shotlet) to the extension without asking" },
            .{ .long = "keep-shortcut", .help = "Leave GNOME's shortcuts alone without asking" },
        },
        .examples = &.{
            .{ .cmd = "gnome-integration install", .what = "Asks about the Print key" },
            .{ .cmd = "gnome-integration install --keep-shortcut", .what = "Leaves Print alone" },
        },
    },
    .{
        .id = .gnome_uninstall,
        .name = "uninstall",
        .group = .settings,
        .summary = "Remove the extension and give back the shortcuts it took",
        .usage = &.{"gnome-integration uninstall"},
        .description = "Restores GNOME's screenshot shortcuts and the custom shortcuts install moved, resets the extension's settings, disables it and removes its files.",
        .examples = &.{.{ .cmd = "gnome-integration uninstall", .what = "Remove the integration" }},
    },
    .{
        .id = .gnome_shortcut,
        .name = "shortcut",
        .group = .settings,
        .summary = "Show or set the extension's capture shortcuts",
        .usage = &.{ "gnome-integration shortcut [KEY... | none]", "gnome-integration shortcut MODE [KEY... | none]" },
        .description = "Without arguments, shows the area capture's key and each capture mode's. KEY... sets the area capture's keys " ++
            "(default Print); MODE KEY... sets a mode's (area, fullscreen, screens, previous, window, scroll, timer) or the key that " ++
            "shows the last thumbnail again (thumbnail); none unbinds it. Keys are written as Shift+Super+S.",
        .args = &.{.{ .name = "KEY", .repeat = true, .choices = &shortcut_words, .help = "A mode name, then shortcuts such as Shift+Super+S, or none" }},
        .examples = &.{
            .{ .cmd = "gnome-integration shortcut Shift+Super+S", .what = "Area: Shift+Super+S" },
            .{ .cmd = "gnome-integration shortcut window Super+W", .what = "Window: Super+W" },
            .{ .cmd = "gnome-integration shortcut screens none", .what = "No key for all screens" },
        },
    },
};

const help_words = [_][]const u8{ "shot", "area", "text", "fullscreen", "screens", "previous", "window", "scroll", "timer", "record", "edit", "pin", "history", "thumbnail", "settings", "daemon", "gnome-integration", "permissions", "completions" };

pub const list = [_]Command{
    .{
        .id = .edit,
        .name = "edit",
        .group = .edit_pin,
        .summary = "Open an image (PNG, JPEG, WebP) in the editor",
        .usage = &.{"edit FILE"},
        .description = "Opens FILE in the annotation editor, to annotate, crop, copy or save it.",
        .args = &.{
            .{ .name = "FILE", .kind = .file, .required = true, .help = "The image to open" },
            .{ .name = "ID", .hidden = true, .help = "With a history directory as FILE: edit that capture again" },
        },
        .examples = &.{.{ .cmd = "edit ~/Pictures/shot.png", .what = "Annotate an image" }},
    },
    .{
        .id = .pin,
        .name = "pin",
        .group = .edit_pin,
        .summary = "Pin an image (default: the clipboard's) on top",
        .usage = &.{"pin [FILE]"},
        .description = "Shows the image at 1:1 in a frameless window: scroll (or - = 0) to zoom, drag to move, Esc to close.",
        .args = &.{.{ .name = "FILE", .kind = .file, .help = "The image to pin (PNG, JPEG, WebP); without it, the clipboard's image" }},
        .options = &.{.{ .long = "at", .value = "X,Y", .vis = .hidden, .help = "Centre it there (logical pixels): where the capture was" }},
        .examples = &.{
            .{ .cmd = "pin", .what = "Pin the image in the clipboard" },
            .{ .cmd = "pin diagram.png", .what = "Pin a file" },
        },
    },
    .{
        .id = .history,
        .name = "history",
        .group = .history,
        .summary = "Recent captures: copy, save, annotate or pin them again",
        .usage = &.{ "history", "history clear" },
        .description = "Lists the captures that were copied or saved, newest first. With Tesseract installed, a search field finds them by their text.",
        .options = &.{smoke},
        .subs = &.{.{
            .id = .history_clear,
            .name = "clear",
            .group = .history,
            .summary = "Forget every capture in the history",
            .usage = &.{"history clear"},
            .description = "Deletes the capture history ($XDG_STATE_HOME/shotlet/history).",
            .examples = &.{.{ .cmd = "history clear", .what = "Empty the history" }},
        }},
        .examples = &.{
            .{ .cmd = "history", .what = "Open Recent captures" },
            .{ .cmd = "history clear", .what = "Forget them all" },
        },
    },
    .{
        .id = .thumbnail,
        .name = "thumbnail",
        .group = .history,
        .summary = "Show the last capture's thumbnail again",
        .usage = &.{"thumbnail"},
        .description = "Brings back the floating thumbnail of the last capture or recording kept (in the history, or the " ++
            "thumbnail's cache when the history is off), to copy, save, drag, annotate or pin it again. " ++
            "With the GNOME integration, Shift+Super+T does the same (shotlet gnome-integration shortcut thumbnail KEY).",
        .examples = &.{.{ .cmd = "thumbnail", .what = "The last thumbnail again" }},
    },
    .{
        .id = .settings,
        .name = "settings",
        .group = .settings,
        .summary = "Preferences and shortcut bindings",
        .usage = &.{"settings"},
        .description = "Opens the Settings window (general, editor, recording and shortcut views). " ++
            "The settings live in $XDG_CONFIG_HOME/shotlet/config.",
        .options = &.{smoke},
        .examples = &.{.{ .cmd = "settings", .what = "Open Settings" }},
    },
    .{
        .id = .daemon,
        .name = "daemon",
        .aliases = &.{"--daemon"},
        .group = .settings,
        .summary = "Run the tray icon (detaches; -f stays in the foreground)",
        .usage = &.{ "daemon [-f]", "--daemon [-f]" },
        .description = "Starts the tray icon and its menu, detached from the terminal; its log goes to $XDG_STATE_HOME/shotlet. " ++
            "./install.sh --autostart starts it at login.",
        .options = &.{.{ .long = "foreground", .short = 'f', .help = "Stay in the foreground, logging to the terminal" }},
        .examples = &.{
            .{ .cmd = "--daemon", .what = "Start the tray icon" },
            .{ .cmd = "daemon -f", .what = "Run it in this terminal" },
        },
    },
    .{
        .id = .gnome_integration,
        .name = "gnome-integration",
        .group = .settings,
        .summary = "GNOME Shell extension: no capture prompts, windows on top",
        .usage = &.{ "gnome-integration [status]", "gnome-integration install | uninstall", "gnome-integration shortcut [MODE] [KEY... | none]" },
        .description = "GNOME has no protocol for keeping windows above others, nor for capturing without a consent dialog; " ++
            "Shotlet's small GNOME Shell extension (GNOME 45 to 50) does both for Shotlet only.",
        .subs = &gnome_subs,
        .examples = &.{
            .{ .cmd = "gnome-integration install", .what = "Install the extension" },
            .{ .cmd = "gnome-integration shortcut Shift+Super+S", .what = "Its capture key" },
        },
    },
    .{
        .id = .permissions,
        .name = "permissions",
        .group = .settings,
        .summary = "What Shotlet captures with and what it remembered",
        .usage = &.{ "permissions", "permissions reset [--dry-run]" },
        .description = "Shows the path a capture takes now and the last one took, whether a ScreenCast restore token is stored " ++
            "and Shotlet's entries in the portal permission store.",
        .subs = &.{.{
            .id = .permissions_reset,
            .name = "reset",
            .group = .settings,
            .summary = "Forget them all: the next capture asks again",
            .usage = &.{"permissions reset [--dry-run]"},
            .description = "Removes the ScreenCast restore token and Shotlet's screen-cast and screenshot permissions from the portal permission store.",
            .options = &.{.{ .long = "dry-run", .help = "Say what would be removed, change nothing" }},
            .examples = &.{
                .{ .cmd = "permissions reset --dry-run", .what = "See what reset would remove" },
                .{ .cmd = "permissions reset", .what = "Remove it" },
            },
        }},
        .examples = &.{
            .{ .cmd = "permissions", .what = "Show how captures go" },
            .{ .cmd = "permissions reset", .what = "Forget the permissions" },
        },
    },
    .{
        .id = .completions,
        .name = "completions",
        .group = .settings,
        .summary = "Print the shell completions for bash, zsh or fish",
        .usage = &.{"completions bash|zsh|fish"},
        .description = "install.sh installs them. By hand: save the output as " ++
            "~/.local/share/bash-completion/completions/shotlet, as _shotlet in a directory " ++
            "of zsh's fpath (e.g. ~/.local/share/zsh/site-functions), or as " ++
            "~/.config/fish/completions/shotlet.fish.",
        .args = &.{.{ .name = "SHELL", .kind = .choice, .required = true, .choices = &.{ "bash", "zsh", "fish" }, .help = "bash, zsh or fish" }},
        .examples = &.{.{ .cmd = "completions fish > shotlet.fish", .what = "The fish completions" }},
    },
    .{
        .id = .help,
        .name = "help",
        .group = .other,
        .summary = "Show the help of shotlet or of a command",
        .usage = &.{"help [COMMAND [SUBCOMMAND]]"},
        .description = "The same as `shotlet COMMAND --help`. `man shotlet` has all of it.",
        .args = &.{.{ .name = "COMMAND", .repeat = true, .choices = &help_words, .help = "The command to explain" }},
        .examples = &.{.{ .cmd = "help record", .what = "Explain record" }},
    },
};
