//! The chrome's controls: button kinds and layers, their script names,
//! tooltip and menu labels, icons, and whether each shows as active or
//! disabled.

const std = @import("std");
const config = @import("../../app/config.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const icons = @import("../icons.zig");
const tools = @import("../tools/mod.zig");
const tui = @import("../tools/tui.zig");

const Editor = editor_mod.Editor;
const Tool = shapes_mod.Tool;
const Rect = shapes_mod.Rect;
const Icon = icons.Icon;

/// Segments of the popover's segmented controls.
pub const Seg = enum {
    outline,
    filled,
    rounded,
    plain,
    pill,
    mode_blur,
    mode_pixelate,
    mode_solid,
    width_fit,
    width_fixed,
    // spotlight and ruler (tools/mod.zig)
    spot_rect,
    spot_ellipse,
    dim_light,
    dim_medium,
    dim_strong,
    measure_show,
    measure_hide,
};

pub const ButtonKind = union(enum) {
    tool: Tool,
    color: u4,
    custom_color,
    /// the toolbar's colour and size button: opens the popover
    colors,
    /// the size slider in the popover
    thickness,
    seg: Seg,
    /// F: cycle the target's style (kept for keyboard and scripts)
    style,
    /// a text's width: fits the text, or fixed (lines wrap)
    text_width,
    beautify,
    background,
    padding,
    corners,
    shadow,
    /// beautify every new capture, not just this one
    beautify_always,
    undo,
    redo,
    copy,
    save,
    save_as,
    more,
    help,
    cancel,
    /// the extra tools' controls (tools/mod.zig)
    ext: tools.Ext,
    // other capture modes (app/modes/): the editor closes and they start
    capture_window,
    capture_scroll,
    capture_timer,
};

/// Which floating surface a control sits on.
pub const Layer = enum { bar, panel, popover, menu };

pub const Button = struct {
    rect: Rect,
    kind: ButtonKind,
    group: u8 = 0,
    row: u8 = 0,
    layer: Layer = .bar,
};

pub const Popover = enum { none, colors, more };

/// The tool buttons; Blur stands for blur, pixelate and solid.
pub const tool_list = [_]Tool{ .select, .pen, .arrow, .rect, .ellipse, .line, .highlight, .blur, .spotlight, .counter, .text, .ruler };

pub fn buttonName(kind: ButtonKind) []const u8 {
    return switch (kind) {
        .tool => |t| @tagName(t),
        .color => |c| shapes_mod.palette_names[c],
        .seg => |s| @tagName(s),
        .ext => |e| tui.name(e),
        else => @tagName(kind),
    };
}

/// Whether `name` lives in the colour popover or the More menu (the
/// script's `button` command opens them first).
pub fn nameLayer(name: []const u8) ?Layer {
    for (shapes_mod.palette_names) |n| if (std.mem.eql(u8, n, name)) return .popover;
    inline for (@typeInfo(Seg).@"enum".field_names) |n| if (std.mem.eql(u8, n, name)) return .popover;
    for ([_][]const u8{ "custom_color", "thickness" }) |n| if (std.mem.eql(u8, n, name)) return .popover;
    for ([_][]const u8{ "save_as", "help", "cancel", "beautify", "capture_window", "capture_scroll", "capture_timer" }) |n| if (std.mem.eql(u8, n, name)) return .menu;
    return tui.nameLayer(name);
}

pub const Label = struct { name: []const u8, key: []const u8 = "" };

/// A control's name and its shortcut, for tooltips and menu rows.
pub fn buttonLabel(self: *const Editor, kind: ButtonKind, kb: []u8) Label {
    const name: []const u8, const action: ?config.Action, const fixed: []const u8 = switch (kind) {
        .tool => |t| blk: {
            const name, const action = toolLabel(t);
            break :blk .{ name, action, "" };
        },
        .color => |c| return .{ .name = shapes_mod.palette_labels[c], .key = if (c < 8) (std.fmt.bufPrint(kb, "{d}", .{@as(u8, c) + 1}) catch "") else "" },
        .custom_color => .{ "Custom colour", null, "9" },
        .colors => .{ "Colour and size", null, "" },
        .thickness => .{ "Size", null, "- =" },
        .seg => |s| .{ segName(s), null, "" },
        .style => .{ "Fill / rounded / text background", .style, "" },
        .text_width => .{ "Text width", null, "Alt+W" },
        .beautify => .{ "Beautify", .beautify, "" },
        .background => return .{ .name = self.beautify.background().name },
        .padding => return .{ .name = paddingName(self.beautify.padding) },
        .corners => .{ "Rounded corners", null, "" },
        .shadow => .{ "Shadow", null, "" },
        .beautify_always => .{ if (self.beautify_always) "Applied to every capture" else "Apply to every capture", null, "" },
        .undo => .{ "Undo", .undo, "" },
        .redo => .{ "Redo", .redo, "" },
        .copy => .{ "Copy and close", null, "Enter" },
        .save => .{ "Save", .save, "" },
        .save_as => .{ "Save as\u{2026}", .save_as, "" },
        .more => .{ "More", null, "" },
        .help => .{ "Shortcuts", null, "?" },
        .cancel => .{ "Close", null, "Esc" },
        .ext => |e| return tui.label(self, e, kb),
        .capture_window => .{ "Capture window", null, "" },
        .capture_scroll => .{ "Scrolling capture", null, "" },
        .capture_timer => .{ "Timer\u{2026}", null, "" },
    };
    const key = if (action) |a| config.bindName(self.binds[@backingInt(a)], kb) else fixed;
    return .{ .name = name, .key = if (std.mem.eql(u8, key, "unset")) "" else key };
}

/// A tool button's name and the key binding that picks it.
fn toolLabel(t: Tool) struct { []const u8, config.Action } {
    return switch (t) {
        .select => .{ "Select", .select },
        .pen => .{ "Pencil", .pen },
        .line => .{ "Line", .line },
        .arrow => .{ "Arrow", .arrow },
        .rect => .{ "Rectangle", .rect },
        .ellipse => .{ "Ellipse", .ellipse },
        .highlight => .{ "Highlighter", .highlight },
        .blur, .pixelate, .redact => .{ "Blur, pixelate, redact", .pixelate },
        .counter => .{ "Counter", .counter },
        .text => .{ "Text", .text },
        .spotlight => .{ "Spotlight", .spotlight },
        .ruler => .{ "Ruler", .ruler },
    };
}

fn segName(s: Seg) []const u8 {
    return switch (s) {
        .outline => "Outline",
        .filled => "Filled",
        .rounded => "Rounded",
        .plain => "Plain",
        .pill => "Background",
        .mode_blur => "Blur",
        .mode_pixelate => "Pixelate",
        .mode_solid => "Solid",
        .width_fit => "Fit text",
        .width_fixed => "Wrap",
        else => tools.segLabel(s),
    };
}

fn paddingName(p: u2) []const u8 {
    return switch (p) {
        0 => "No padding",
        1 => "Small padding",
        2 => "Medium padding",
        3 => "Large padding",
    };
}

/// The tool whose options the popover shows: the edited/selected shape's.
pub fn targetTool(self: *const Editor) Tool {
    if (self.text) |t| return self.doc.shapes.items[t.idx].tool;
    if (self.selected) |i| return self.doc.shapes.items[i].tool;
    return self.tool;
}

pub fn toolButtonActive(self: *const Editor, t: Tool) bool {
    if (t == .blur) return self.tool.isRedaction();
    return t == self.tool;
}

pub fn buttonActive(self: *const Editor, kind: ButtonKind) bool {
    return switch (kind) {
        .tool => |t| toolButtonActive(self, t),
        .colors => self.popover == .colors,
        .more => self.popover == .more,
        .corners => self.beautify.rounded,
        .shadow => self.beautify.shadow,
        .beautify_always => self.beautify_always,
        .beautify => self.beautify.enabled,
        .help => self.help_open,
        .ext => |e| tui.active(self, e),
        else => false,
    };
}

/// Why a control cannot be used right now, or null when it can. A
/// disabled control shows dimmed, ignores clicks and keys, and its
/// tooltip says why.
pub fn disabledWhy(self: *const Editor, kind: ButtonKind) ?[]const u8 {
    return switch (kind) {
        .undo => if (canUndo(self)) null else "Nothing to undo",
        .redo => if (self.doc.redo_stack.items.len > 0) null else "Nothing to redo",
        .ext => |e| tui.disabledWhy(e),
        else => null,
    };
}

/// History to undo, or an edit in progress that undo would end.
fn canUndo(self: *const Editor) bool {
    return self.doc.undo_stack.items.len > 0 or self.text != null or self.drag != .none or self.lifted != null;
}

pub fn toolIcon(self: *const Editor, t: Tool) Icon {
    return switch (t) {
        .select => .select,
        .pen => .pen,
        .arrow => .arrow,
        .rect => .rect,
        .ellipse => .ellipse,
        .line => .line,
        .highlight => .highlight,
        .blur, .pixelate, .redact => switch (self.tool) {
            .pixelate => .pixelate,
            .redact => .redact,
            else => .blur,
        },
        .counter => .counter,
        .text => .text,
        .spotlight => .spotlight,
        .ruler => .ruler,
    };
}

pub fn kindIcon(self: *const Editor, kind: ButtonKind) ?Icon {
    return switch (kind) {
        .tool => |t| toolIcon(self, t),
        .undo => .undo,
        .redo => .redo,
        .save => .save,
        .save_as => .save_as,
        .more => .more,
        .copy => .copy,
        .help => .keyboard,
        .cancel => .close,
        .beautify => .beautify,
        .background => .background,
        .padding => .padding,
        .corners => .corners,
        .shadow => .shadow,
        .beautify_always => .pin,
        .ext => |e| tui.icon(e),
        .capture_window => .capture_window,
        .capture_scroll => .capture_scroll,
        .capture_timer => .timer,
        else => null,
    };
}

pub fn segOn(self: *const Editor, s: Seg) bool {
    const target = targetTool(self);
    const st = self.styles.get(target);
    const fixed = if (self.textHandleShape()) |i| self.doc.shapes.items[i].box_w > 0 else false;
    const mode = if (self.selected) |i| self.doc.shapes.items[i].tool else self.tool;
    return switch (s) {
        .outline => st & 1 == 0,
        .filled, .pill => st & 1 != 0,
        .plain => st & 1 == 0,
        .rounded => st & 2 != 0,
        .mode_blur => mode == .blur,
        .mode_pixelate => mode == .pixelate,
        .mode_solid => mode == .redact,
        .width_fit => !fixed,
        .width_fixed => fixed,
        else => tools.segOn(self, s),
    };
}

test "every button has a script name and popover names are known" {
    try std.testing.expectEqualStrings("blur", buttonName(.{ .tool = .blur }));
    try std.testing.expectEqualStrings("red", buttonName(.{ .color = 0 }));
    try std.testing.expectEqualStrings("grey", buttonName(.{ .color = 10 }));
    try std.testing.expectEqualStrings("filled", buttonName(.{ .seg = .filled }));
    try std.testing.expectEqual(Layer.popover, nameLayer("cyan").?);
    try std.testing.expectEqual(Layer.menu, nameLayer("save_as").?);
    try std.testing.expect(nameLayer("copy") == null);
}
