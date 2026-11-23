//! A left press: whatever lies under the pointer takes it, in order of
//! priority (help, colour picker, chrome, popover, extra tools, text
//! handle, text being edited, shape handles, selection, then the active
//! tool), and usually starts a drag (see drag.zig).

const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const text_mod = @import("../../gfx/text.zig");
const ui = @import("../editor_ui.zig");
const tools = @import("../tools/mod.zig");
const caretAt = @import("../caret.zig").caretAt;
const session = @import("session.zig");
const hit = @import("hit.zig");
const caches = @import("caches.zig");
const props = @import("props.zig");
const commands = @import("commands.zig");
const selection = @import("selection.zig");
const text_edit = @import("text_edit.zig");
const drawing = @import("drawing.zig");
const winpick = @import("winpick.zig");

const Editor = editor.Editor;
const Point = shapes_mod.Point;

/// First run: the hint goes away at the first action.
pub fn dismissHint(ed: *Editor) void {
    if (!ed.show_hint) return;
    ed.show_hint = false;
    ed.needs_render = true;
}

pub fn onPress(ed: *Editor) !void {
    dismissHint(ed);
    const m = ed.mouse;
    props.breakCoalescing(ed);
    if (ed.help_open) {
        ed.help_open = false;
        ed.needs_render = true;
        return;
    }
    if (ed.picker.open and try pressPicker(ed, m)) return;
    // the chrome gets priority; a click outside an open popover or
    // menu only closes it
    if (hit.onToolbar(ed, m)) return pressChrome(ed, m);
    if (ed.popover != .none) return commands.closePopover(ed);
    if (try tools.onPress(ed)) return;
    const ip = ed.imgAt(m);
    const double = countClick(ed, m);
    // a text box's width handle: drag to fix the width (lines wrap),
    // double-click to go back to fitting the text
    if (hit.textHandleAt(ed, m)) |i| return text_edit.pressTextHandle(ed, i, double);
    if (ed.text != null and try pressWhileEditing(ed, m, ip, double)) return;
    if (ed.selected) |i| if (hit.shapeHandleAt(ed, i, m)) |h| return grabShapeHandle(ed, i, h);
    if (ed.doc.sel == null or ed.tool == .select) return pressSelect(ed, m, ip, double);
    selection.deselectShape(ed);
    switch (ed.tool) {
        .counter => try addCounter(ed, ip),
        .text => try pressTextTool(ed, ip),
        else => try drawing.start(ed, ip),
    }
}

/// A press while the colour picker is open: on its parts it picks
/// (and drags); elsewhere it closes the picker. True when consumed.
fn pressPicker(ed: *Editor, m: Point) !bool {
    if (if (ed.mouse_pane == ed.tb_pane) ui.pickPartAt(ed, m) else null) |part| {
        ed.drag = .{ .picking = part };
        ui.pickAt(ed, part, m);
        try props.applyPickerColor(ed);
        return true;
    }
    if ((ed.mouse_pane == ed.tb_pane and ed.picker.rect.contains(m.x, m.y))) return true;
    ed.picker.open = false;
    ed.needs_render = true;
    return false;
}

/// A press on the toolbar, popover or menu.
fn pressChrome(ed: *Editor, m: Point) !void {
    const bi = ui.buttonAt(ed, m) orelse return;
    const b = ed.buttons.items[bi];
    if (b.kind == .thickness) {
        ed.drag = .size_slider;
        try props.setThickness(ed, ui.sliderValue(ed, m));
        return;
    }
    if (ed.popover != .none and b.layer == .bar and b.kind != .colors and b.kind != .more) commands.closePopover(ed);
    try commands.onButton(ed, b.kind);
}

/// Record a click at `m`; true when it completes a double click.
fn countClick(ed: *Editor, m: Point) bool {
    const now = session.nowMs();
    const last = ed.last_click;
    const double = now - last.ms < 400 and @abs(m.x - last.at.x) < 5 and @abs(m.y - last.at.y) < 5;
    ed.last_click = .{ .ms = now, .at = m };
    return double;
}

/// A press while text is being edited: inside the box it places the
/// caret (Shift extends, a drag selects, a double click selects a word);
/// outside it commits the text. True when consumed.
fn pressWhileEditing(ed: *Editor, m: Point, ip: Point, double: bool) !bool {
    const t = &ed.text.?;
    const s = &ed.doc.shapes.items[t.idx];
    if (!ed.pn().view.rectToBuf(s.frame()).expand(ed.sc(4)).contains(m.x, m.y)) {
        try text_edit.endText(ed);
        return ed.tool == .text; // a click outside just commits
    }
    const at = caretAt(s, ip);
    t.goal_x = null;
    if (double) {
        t.te.selectWord(s.str.items, at.off);
        t.upstream = false;
    } else {
        if (!ed.mod_shift) t.te.anchor = at.off else if (t.te.anchor == null) t.te.anchor = t.te.caret;
        t.te.caret = at.off;
        t.upstream = at.upstream;
        ed.drag = .text_select;
    }
    ed.needs_render = true;
    return true;
}

/// Start resizing the selected shape `i` by its handle `h`.
fn grabShapeHandle(ed: *Editor, i: usize, h: u3) !void {
    try ed.doc.checkpoint();
    const orig = try ed.doc.shapes.items[i].clone(ed.alloc);
    try selection.lift(ed, i);
    ed.drag = .{ .resizing_shape = .{ .handle = h, .orig = orig } };
}

/// The select tool (or no selection yet): pick a shape, grab the
/// selection's handles or body, or start a new selection.
fn pressSelect(ed: *Editor, m: Point, ip: Point, double: bool) !void {
    if (ed.doc.sel != null) {
        if (ed.doc.hit(ip, hit.hitTol(ed))) |i| return grabShape(ed, i, ip, double);
        selection.deselectShape(ed);
        const n = ed.selBuf().?;
        if (shapes_mod.handleAt(n, m, ed.handleRadius())) |h| {
            ed.drag = .{ .resizing_sel = .{ .handle = h, .orig = ed.doc.sel.?.normalized() } };
            ed.sel_edge = h;
            return;
        }
        ed.sel_edge = null;
        if (n.contains(m.x, m.y)) {
            ed.drag = .{ .moving_sel = .{ .orig = ed.doc.sel.?.normalized(), .start = ip } };
            return;
        }
    }
    selection.deselectShape(ed);
    caches.selDirty(ed);
    winpick.onPress(ed);
    const a = hit.clampImg(ed, ip);
    ed.doc.sel = .{ .x = a.x, .y = a.y, .w = 0, .h = 0 };
    ed.drag = .{ .selecting = a };
    ed.drag_anchor = a;
    ed.space.last = null;
    caches.selDirty(ed);
}

/// Select shape `i` and start moving it; a double click on a text edits it.
fn grabShape(ed: *Editor, i: usize, ip: Point, double: bool) !void {
    selection.selectShape(ed, i);
    if (double and ed.doc.shapes.items[i].tool == .text) return text_edit.startText(ed, i, false, ip);
    try ed.doc.checkpoint();
    try selection.lift(ed, i);
    ed.drag = .{ .moving_shape = .{ .start = ip, .applied = .{ .x = 0, .y = 0 } } };
}

fn addCounter(ed: *Editor, ip: Point) !void {
    try ed.doc.checkpoint();
    const i = try ed.doc.add(.{
        .tool = .counter,
        .color = ed.color(),
        .thickness = ed.imgThickness(),
        .p0 = ip,
        .number = ed.doc.nextNumber(),
    });
    try caches.paintTop(ed, i);
}

/// The text tool: edit the text under the pointer, else add a new one
/// centred on it.
fn pressTextTool(ed: *Editor, ip: Point) !void {
    if (ed.doc.hit(ip, hit.hitTol(ed))) |i| {
        if (ed.doc.shapes.items[i].tool == .text) return text_edit.startText(ed, i, false, ip);
    }
    const t = ed.imgThickness();
    const lh = text_mod.height(shapes_mod.textFontPx(t));
    const i = try ed.doc.add(.{
        .tool = .text,
        .color = ed.color(),
        .thickness = t,
        .p0 = .{ .x = ip.x, .y = ip.y - @divTrunc(lh, 2) },
        .pill = (ed.styles.get(.text) & 1) != 0,
    });
    try text_edit.startText(ed, i, true, ip);
}
