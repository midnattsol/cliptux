//! The editor's configurable actions, their default key bindings and
//! how they are named (Settings, tooltips).

const std = @import("std");
const KeyCode = @import("../platform/api/keys.zig").Code;

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
    /// the physical key; none = unbound
    code: KeyCode = .none,
    ctrl: bool = false,
    shift: bool = false,

    pub fn matches(self: Bind, code: KeyCode, ctrl: bool, shift: bool) bool {
        return self.code != .none and self.code == code and self.ctrl == ctrl and self.shift == shift;
    }
};

pub const default_binds = [n_actions]Bind{
    .{ .code = .v }, // select
    .{ .code = .p }, // pen
    .{ .code = .l }, // line
    .{ .code = .a }, // arrow
    .{ .code = .r }, // rect
    .{ .code = .e }, // ellipse
    .{ .code = .m }, // highlight (marker, as CleanShot X and Flameshot)
    .{ .code = .x }, // pixelate
    .{ .code = .n }, // counter
    .{ .code = .t }, // text
    .{ .code = .c, .ctrl = true }, // Ctrl+C copy
    .{ .code = .s, .ctrl = true }, // Ctrl+S save
    .{ .code = .z, .ctrl = true }, // Ctrl+Z undo
    .{ .code = .z, .ctrl = true, .shift = true }, // Ctrl+Shift+Z redo
    .{ .code = .s, .ctrl = true, .shift = true }, // Ctrl+Shift+S save as
    .{ .code = .b }, // beautify (CleanShot X's background tool)
    .{ .code = .f }, // fill style (CleanShot X: filled rectangle)
    .{ .code = .i }, // colour picker (eyedropper)
    .{ .code = .u }, // ruler
    .{ .code = .s }, // spotlight
    .{ .code = .c }, // crop (CleanShot X)
    .{ .code = .c, .ctrl = true, .shift = true }, // Ctrl+Shift+C copy text
    .{ .code = .r, .ctrl = true, .shift = true }, // Ctrl+Shift+R redact sensitive data
    .{ .code = .p, .ctrl = true }, // Ctrl+P pin
};

/// Format a binding like "Ctrl+Shift+Z" (the key as printed on a US
/// keyboard). Returns slice of buf.
pub fn bindName(b: Bind, buf: []u8) []const u8 {
    if (b.code == .none) return "unset";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        if (b.ctrl) "Ctrl+" else "",
        if (b.shift) "Shift+" else "",
        b.code.label(),
    }) catch "?";
}
