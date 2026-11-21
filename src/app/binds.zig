//! The editor's configurable actions, their default key bindings and
//! how keys are named (Settings, tooltips, the config file).

const std = @import("std");

pub const Action = enum {
    select,
    pen,
    line,
    arrow,
    rect,
    ellipse,
    highlight,
    pixelate,
    counter,
    text,
    copy,
    save,
    undo,
    redo,
    // added later; config files name binds, so order only sets defaults
    save_as,
    beautify,
    style,
    // the editor's extra tools (src/ui/tools/)
    eyedropper,
    ruler,
    spotlight,
    crop,
    copy_text,
    redact_sensitive,
    pin,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .select => "Select tool",
            .pen => "Pencil",
            .line => "Line",
            .arrow => "Arrow",
            .rect => "Rectangle",
            .ellipse => "Ellipse",
            .highlight => "Highlighter",
            .pixelate => "Blur / pixelate / redact",
            .counter => "Counter badge",
            .text => "Text",
            .copy => "Copy to clipboard",
            .save => "Save and exit",
            .undo => "Undo",
            .redo => "Redo",
            .save_as => "Save as...",
            .beautify => "Beautify frame",
            .style => "Fill / rounded / text background",
            .eyedropper => "Colour picker",
            .ruler => "Ruler",
            .spotlight => "Spotlight",
            .crop => "Crop",
            .copy_text => "Copy text (OCR)",
            .redact_sensitive => "Redact sensitive data",
            .pin => "Pin to screen",
        };
    }
};

pub const n_actions = @typeInfo(Action).@"enum".field_names.len;

pub const Bind = struct {
    code: u32 = 0, // evdev key code; 0 = unbound
    ctrl: bool = false,
    shift: bool = false,

    pub fn matches(self: Bind, code: u32, ctrl: bool, shift: bool) bool {
        return self.code != 0 and self.code == code and self.ctrl == ctrl and self.shift == shift;
    }
};

pub const default_binds = [n_actions]Bind{
    .{ .code = 47 }, // V select
    .{ .code = 25 }, // P pen
    .{ .code = 38 }, // L line
    .{ .code = 30 }, // A arrow
    .{ .code = 19 }, // R rect
    .{ .code = 18 }, // E ellipse
    .{ .code = 50 }, // M highlight (marker, as CleanShot X and Flameshot)
    .{ .code = 45 }, // X pixelate
    .{ .code = 49 }, // N counter
    .{ .code = 20 }, // T text
    .{ .code = 46, .ctrl = true }, // Ctrl+C copy
    .{ .code = 31, .ctrl = true }, // Ctrl+S save
    .{ .code = 44, .ctrl = true }, // Ctrl+Z undo
    .{ .code = 44, .ctrl = true, .shift = true }, // Ctrl+Shift+Z redo
    .{ .code = 31, .ctrl = true, .shift = true }, // Ctrl+Shift+S save as
    .{ .code = 48 }, // B beautify (CleanShot X's background tool)
    .{ .code = 33 }, // F fill style (CleanShot X: filled rectangle)
    .{ .code = 23 }, // I colour picker (eyedropper)
    .{ .code = 22 }, // U ruler
    .{ .code = 31 }, // S spotlight
    .{ .code = 46 }, // C crop (CleanShot X)
    .{ .code = 46, .ctrl = true, .shift = true }, // Ctrl+Shift+C copy text
    .{ .code = 19, .ctrl = true, .shift = true }, // Ctrl+Shift+R redact sensitive data
    .{ .code = 25, .ctrl = true }, // Ctrl+P pin
};

/// Human-readable name for an evdev key code (US-position based).
pub fn keyCodeName(code: u32) []const u8 {
    return switch (code) {
        1 => "Esc",
        2...11 => |c| ([_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" })[c - 2],
        12 => "-",
        13 => "=",
        14 => "Backspace",
        15 => "Tab",
        16...25 => |c| ([_][]const u8{ "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" })[c - 16],
        28 => "Enter",
        30...38 => |c| ([_][]const u8{ "A", "S", "D", "F", "G", "H", "J", "K", "L" })[c - 30],
        44...50 => |c| ([_][]const u8{ "Z", "X", "C", "V", "B", "N", "M" })[c - 44],
        51 => ",",
        52 => ".",
        53 => "/",
        57 => "Space",
        59...68 => |c| ([_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10" })[c - 59],
        87 => "F11",
        88 => "F12",
        102 => "Home",
        103 => "Up",
        104 => "PgUp",
        105 => "Left",
        106 => "Right",
        107 => "End",
        108 => "Down",
        109 => "PgDn",
        110 => "Insert",
        111 => "Delete",
        else => "key?",
    };
}

/// Format a binding like "Ctrl+Shift+Z". Returns slice of buf.
pub fn bindName(b: Bind, buf: []u8) []const u8 {
    if (b.code == 0) return "unset";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        if (b.ctrl) "Ctrl+" else "",
        if (b.shift) "Shift+" else "",
        keyCodeName(b.code),
    }) catch "?";
}
