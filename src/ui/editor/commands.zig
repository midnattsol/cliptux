//! What the chrome's buttons do (toolbar, colour popover, More menu,
//! beautify panel), also reached from keys and scripts, and opening and
//! closing the popover and menu.

const editor = @import("../editor.zig");
const doc_mod = @import("../doc.zig");
const ui = @import("../editor_ui.zig");
const motion = @import("../motion.zig");
const tools = @import("../tools/mod.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const selection = @import("selection.zig");
const text_edit = @import("text_edit.zig");
const history = @import("history.zig");
const exporter = @import("export.zig");
const hit = @import("hit.zig");
const discard = @import("discard.zig");

const Editor = editor.Editor;
const Tool = editor.Tool;

pub fn onButton(ed: *Editor, kind: ui.ButtonKind) !void {
    ed.needs_render = true;
    switch (kind) {
        .tool => |t| try pickTool(ed, t),
        .colors => togglePopover(ed, .colors),
        .more => togglePopover(ed, .more),
        .seg => |sg| try applySeg(ed, sg),
        .color => |c| try props.pickPaletteColor(ed, c),
        .custom_color => {
            ed.picker.open = !ed.picker.open;
            if (ed.picker.open) ui.pickerFrom(ed, ed.custom_color);
        },
        .style => try props.cycleStyle(ed),
        .text_width => try text_edit.toggleTextWidth(ed),
        .thickness => try props.setThickness(ed, if (ed.thickness >= 16) 1 else ed.thickness + 1),
        .beautify, .background, .padding, .corners, .shadow => beautifyButton(ed, kind),
        .beautify_always => ed.beautify_always = !ed.beautify_always,
        .undo => try history.undo(ed),
        .redo => try history.redo(ed),
        .copy => try exporter.copyToClipboard(ed),
        .save => finish(ed, .save),
        .save_as, .capture_window, .capture_scroll, .capture_timer, .help, .cancel => menuButton(ed, kind),
        .ext => |e| try tools.onButton(ed, e),
    }
}

/// A tool button. Blur stands for all three redactions: again cycles
/// them.
fn pickTool(ed: *Editor, t: Tool) !void {
    try text_edit.endText(ed);
    selection.deselectShape(ed);
    ed.tool = if (t == .blur and ed.tool.isRedaction()) switch (ed.tool) {
        .blur => .pixelate,
        .pixelate => .redact,
        else => .blur,
    } else t;
}

/// The beautify panel's switches.
fn beautifyButton(ed: *Editor, kind: ui.ButtonKind) void {
    const b = &ed.beautify;
    switch (kind) {
        .beautify => {
            if (ed.popover == .more) closePopover(ed);
            b.enabled = !b.enabled;
        },
        .background => b.bg = @intCast((b.bg + 1) % doc_mod.backgrounds.len),
        .padding => b.padding +%= 1,
        .corners => b.rounded = !b.rounded,
        .shadow => b.shadow = !b.shadow,
        else => unreachable,
    }
    caches.selDirty(ed);
    // the frame's size changes: what was around it shows again
    if (kind == .beautify or kind == .padding) caches.dirtyAll(ed, true);
}

/// The More menu's entries (and Help, Cancel): close it, then act.
fn menuButton(ed: *Editor, kind: ui.ButtonKind) void {
    closePopover(ed);
    switch (kind) {
        .save_as => finish(ed, .save_as),
        .capture_window, .capture_scroll, .capture_timer => {
            ed.next_capture = switch (kind) {
                .capture_window => "window",
                .capture_scroll => "scroll",
                else => "timer",
            };
            finish(ed, .new_capture);
        },
        .help => ed.help_open = !ed.help_open,
        .cancel => discard.close(ed),
        else => unreachable,
    }
}

/// A segment of the popover's segmented controls.
fn applySeg(ed: *Editor, sg: ui.Seg) !void {
    switch (sg) {
        .outline, .plain, .filled, .pill, .rounded => try props.applyStyleSeg(ed, sg),
        .mode_blur => try props.applyRedactionSeg(ed, .blur),
        .mode_pixelate => try props.applyRedactionSeg(ed, .pixelate),
        .mode_solid => try props.applyRedactionSeg(ed, .redact),
        .width_fit, .width_fixed => {
            const i = hit.textHandleShape(ed) orelse return;
            const fixed = ed.doc.shapes.items[i].box_w > 0;
            if (fixed != (sg == .width_fixed)) try text_edit.toggleTextWidth(ed);
        },
        else => try tools.applySeg(ed, sg),
    }
    ed.needs_render = true;
}

pub fn togglePopover(ed: *Editor, which: ui.Popover) void {
    if (ed.popover == which) return closePopover(ed);
    ed.popover = which;
    ed.picker.open = false;
    const t = motion.now();
    ed.pop_open.snap(0);
    ed.pop_open.to(1, t);
    // a keyboard user lands inside it
    if (ed.focus != null) ed.focus_into_popover = true;
    ed.needs_render = true;
}

pub fn closePopover(ed: *Editor) void {
    if (ed.popover == .none) return;
    // focus was inside: back to the button that opened it
    if (ed.focus) |fi| {
        if (fi < ed.buttons.items.len and (ed.buttons.items[fi].layer == .popover or ed.buttons.items[fi].layer == .menu)) {
            ed.focus = null;
            for (ed.buttons.items, 0..) |b, i| {
                if (b.layer == .bar and ((ed.popover == .colors and b.kind == .colors) or (ed.popover == .more and b.kind == .more))) ed.focus = i;
            }
        }
    }
    ed.popover = .none;
    ed.picker.open = false;
    ed.needs_render = true;
}

pub fn finish(ed: *Editor, action: editor.Action) void {
    ed.action = action;
    ed.running = false;
}
