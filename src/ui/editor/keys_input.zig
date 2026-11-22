//! Key presses, in order of priority: help and the colour picker, the
//! text being edited, the extra tools, fixed chords, the configurable
//! binds (config.zig), popover navigation, the capture modes' letters
//! (before a selection), then the plain keys.

const std = @import("std");
const editor = @import("../editor.zig");
const window = @import("../../platform/linux/window.zig");
const config = @import("../../app/config.zig");
const ui = @import("../editor_ui.zig");
const tools = @import("../tools/mod.zig");
const keys = @import("keys.zig");
const pointer = @import("pointer.zig");
const props = @import("props.zig");
const commands = @import("commands.zig");
const selection = @import("selection.zig");
const text_edit = @import("text_edit.zig");
const history = @import("history.zig");
const exporter = @import("export.zig");
const hit = @import("hit.zig");
const discard = @import("discard.zig");
const capmode = @import("capmode.zig");

const Editor = editor.Editor;
const Key = window.Key;

pub fn onKey(ed: *Editor, k: Key) !void {
    pointer.dismissHint(ed);
    // Space during a drag moves the box (see events.trackModifiers)
    if (k.code == window.KEY_SPACE and ed.drag != .none) return;
    if (k.repeat and !repeats(ed, k)) return;
    ed.needs_render = true;
    if (ed.help_open) {
        ed.help_open = false;
        return;
    }
    if (ed.picker.open) {
        if (ui.pickerKey(ed, k)) |changed| {
            if (changed) try props.applyPickerColor(ed);
            return;
        }
    }
    if (try textKey(ed, k)) return;
    if (try tools.onKey(ed, k)) return;
    if (try fixedChord(ed, k)) return;
    if (!k.alt) {
        if (bindFor(ed, k)) |a| return runBind(ed, a);
    }
    if (ed.popover != .none and !k.ctrl and !k.alt) switch (k.code) {
        keys.KEY_UP, keys.KEY_LEFT => return ui.moveFocus(ed, -1),
        keys.KEY_DOWN, keys.KEY_RIGHT => return ui.moveFocus(ed, 1),
        else => {},
    };
    if (try capmode.onKey(ed, k)) return;
    try plainKey(ed, k);
}

/// Held keys repeat for movement, deletion and typing only.
fn repeats(ed: *const Editor, k: Key) bool {
    return switch (k.code) {
        keys.KEY_LEFT, keys.KEY_RIGHT, keys.KEY_UP, keys.KEY_DOWN, keys.KEY_MINUS, keys.KEY_EQUAL, keys.KEY_KPMINUS, keys.KEY_KPPLUS => true,
        window.KEY_ESC => false,
        else => ed.text != null,
    };
}

/// Keys for text: paste, Alt+W (a text's width between fitting the text
/// and fixed), and editing. Other Ctrl chords (copy, save, undo...) end
/// the edit and go on. True when consumed.
fn textKey(ed: *Editor, k: Key) !bool {
    if (ed.text != null and ((k.ctrl and k.code == keys.KEY_V) or (k.shift and k.code == keys.KEY_INSERT))) {
        try text_edit.pasteText(ed);
        return true;
    }
    if (k.alt and !k.ctrl and k.code == keys.KEY_W and hit.textHandleShape(ed) != null) {
        try text_edit.toggleTextWidth(ed);
        return true;
    }
    if (ed.text == null) return false;
    const editing_chord = switch (k.code) {
        window.KEY_ENTER, keys.KEY_KPENTER, window.KEY_BACKSPACE, window.KEY_DELETE, keys.KEY_LEFT, keys.KEY_RIGHT, keys.KEY_HOME, keys.KEY_END, keys.KEY_MINUS, keys.KEY_EQUAL, keys.KEY_A => true,
        // copy/cut stay in the text when something is selected
        keys.KEY_C, keys.KEY_X => ed.text.?.te.selection() != null,
        else => false,
    };
    if (!k.ctrl or editing_chord) {
        try text_edit.onTextKey(ed, k);
        return true;
    }
    try text_edit.endText(ed);
    return false;
}

/// Fixed chords that must win over configurable binds. True when one ran.
fn fixedChord(ed: *Editor, k: Key) !bool {
    if (!k.ctrl) return false;
    if (!k.shift and k.code == keys.KEY_Y) {
        try history.redo(ed);
    } else if (k.code == keys.KEY_D) {
        try selection.duplicateSelected(ed);
    } else if (k.code == keys.KEY_RIGHTBRACE) {
        try selection.bringSelectedToFront(ed);
    } else return false;
    return true;
}

/// The first configured bind `k` matches.
fn bindFor(ed: *const Editor, k: Key) ?config.Action {
    for (ed.binds, 0..) |b, i| {
        if (b.matches(k.code, k.ctrl, k.shift)) return @as(config.Action, @fromBackingInt(@intCast(i)));
    }
    return null;
}

fn runBind(ed: *Editor, a: config.Action) !void {
    switch (a) {
        .select => try props.setTool(ed, .select),
        .pen => try props.setTool(ed, .pen),
        .line => try props.setTool(ed, .line),
        .arrow => try props.setTool(ed, .arrow),
        .rect => try props.setTool(ed, .rect),
        .ellipse => try props.setTool(ed, .ellipse),
        .highlight => try props.setTool(ed, .highlight),
        // blur first; pressing again cycles pixelate and solid redaction
        .pixelate => try props.setTool(ed, switch (ed.tool) {
            .blur => .pixelate,
            .pixelate => .redact,
            else => .blur,
        }),
        .counter => try props.setTool(ed, .counter),
        .text => try props.setTool(ed, .text),
        .copy => try exporter.copyToClipboard(ed),
        .save => commands.finish(ed, .save),
        .undo => try history.undo(ed),
        .redo => try history.redo(ed),
        .save_as => commands.finish(ed, .save_as),
        .beautify => try commands.onButton(ed, .beautify),
        .style => try props.cycleStyle(ed),
        else => try tools.onAction(ed, a),
    }
}

/// Keys with no modifier meaning of their own.
fn plainKey(ed: *Editor, k: Key) !void {
    switch (k.code) {
        window.KEY_ESC => if (!try history.cancelOne(ed)) discard.close(ed),
        keys.KEY_TAB => ui.moveFocus(ed, if (k.shift) -1 else 1),
        window.KEY_ENTER, keys.KEY_KPENTER, window.KEY_SPACE => try activate(ed, k),
        window.KEY_DELETE, window.KEY_BACKSPACE => try selection.deleteSelected(ed),
        keys.KEY_LEFT, keys.KEY_RIGHT, keys.KEY_UP, keys.KEY_DOWN => try selection.arrowKey(ed, k),
        keys.KEY_MINUS, keys.KEY_KPMINUS => try props.setThickness(ed, ed.thickness - 1),
        keys.KEY_EQUAL, keys.KEY_KPPLUS => try props.setThickness(ed, ed.thickness + 1),
        keys.KEY_F1 => ed.help_open = true,
        keys.KEY_1...keys.KEY_1 + 7 => if (!k.ctrl and !k.alt) try props.pickPaletteColor(ed, @intCast(k.code - keys.KEY_1)),
        keys.KEY_9 => if (!k.ctrl) try commands.onButton(ed, .custom_color),
        else => {
            if (std.mem.eql(u8, k.text(), "?")) ed.help_open = true;
        },
    }
}

/// Enter or Space: press the focused button; without focus, Enter edits
/// the selected text, else copies.
fn activate(ed: *Editor, k: Key) !void {
    if (ed.focus) |f| {
        if (f < ed.buttons.items.len) try commands.onButton(ed, ed.buttons.items[f].kind);
        return;
    }
    if (k.code == window.KEY_SPACE) return;
    if (ed.selected) |i| {
        if (ed.doc.shapes.items[i].tool == .text) return text_edit.startText(ed, i, false, .{ .x = std.math.maxInt(i32) / 2, .y = std.math.maxInt(i32) / 2 });
    }
    try exporter.copyToClipboard(ed);
}
