// Window capture for the Shotlet extension, as on macOS: an overlay over
// every monitor outlines the windows of the current workspace, the one
// under the pointer lights up, a click captures just that window and Esc
// (or a right click) cancels.
//
// The window is painted from its own actor (Meta.WindowActor
// paint_to_content), so other windows covering it do not show, and cut to
// its frame: client-side shadows are left out and its rounded corners stay
// transparent. The PNG goes into the extension's private capture
// directory like every other capture.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const OUTLINE = 'border: 1px solid rgba(255, 255, 255, 0.45); border-radius: 12px;';
const HIGHLIGHT = 'background-color: rgba(10, 132, 255, 0.16);' +
    ' border: 3px solid rgba(10, 132, 255, 0.95); border-radius: 12px;';
const HINT = 'background-color: rgba(30, 30, 32, 0.82); color: #ffffff; border-radius: 999px;' +
    ' padding: 8px 18px; font-size: 13px; border: 1px solid rgba(255, 255, 255, 0.14);';

// Normal, visible windows of the active workspace, topmost first; not
// Shotlet's own floating windows.
function candidates(isShotlet) {
    const ws = global.workspace_manager.get_active_workspace();
    const list = global.display.get_tab_list(Meta.TabList.NORMAL_ALL, ws)
        .filter(w => !w.minimized && w.showing_on_its_workspace() && !isShotlet(w));
    return global.display.sort_windows_by_stacking(list).reverse();
}

function contains(r, x, y) {
    return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

// Let the person pick a window. Resolves the Meta.Window, or null.
export function pickWindow(isShotlet) {
    return new Promise(resolve => {
        const windows = candidates(isShotlet);
        const overlay = new St.Widget({
            reactive: true,
            x: 0, y: 0,
            width: global.stage.width, height: global.stage.height,
        });
        for (const w of windows) {
            const r = w.get_frame_rect();
            overlay.add_child(new St.Widget({style: OUTLINE, x: r.x, y: r.y, width: r.width, height: r.height}));
        }
        const highlight = new St.Widget({style: HIGHLIGHT, visible: false});
        overlay.add_child(highlight);
        const monitor = Main.layoutManager.primaryMonitor;
        const hint = new St.Label({text: 'Click a window to capture it · Esc to cancel', style: HINT});
        overlay.add_child(hint);
        Main.uiGroup.add_child(overlay);
        hint.set_position(monitor.x + Math.floor((monitor.width - hint.width) / 2), monitor.y + 24);
        const grab = Main.pushModal(overlay, {actionMode: Shell.ActionMode.POPUP});

        let hovered = null;
        const hover = (x, y) => {
            hovered = windows.find(w => contains(w.get_frame_rect(), x, y)) ?? null;
            highlight.visible = hovered !== null;
            if (hovered) {
                const r = hovered.get_frame_rect();
                highlight.set_position(r.x, r.y);
                highlight.set_size(r.width, r.height);
            }
        };
        const done = w => {
            Main.popModal(grab);
            overlay.destroy();
            resolve(w);
        };
        overlay.connect('motion-event', (_a, ev) => {
            hover(...ev.get_coords());
            return Clutter.EVENT_STOP;
        });
        overlay.connect('button-press-event', (_a, ev) => {
            if (ev.get_button() !== Clutter.BUTTON_PRIMARY)
                done(null);
            else {
                hover(...ev.get_coords());
                done(hovered);
            }
            return Clutter.EVENT_STOP;
        });
        overlay.connect('key-press-event', (_a, ev) => {
            if (ev.get_key_symbol() === Clutter.KEY_Escape)
                done(null);
            return Clutter.EVENT_STOP;
        });
        const [px, py] = global.get_pointer();
        hover(px, py);
        console.log(`Shotlet: picking one of ${windows.length} windows`);
    });
}

// Write the window's own picture, cut to its frame at its buffer scale,
// to the new 0600 `file`. Resolves its logical frame and scale.
export async function captureWindow(win, file) {
    const actor = win.get_compositor_private();
    if (!actor)
        throw new Error('the window has no actor');
    const frame = win.get_frame_rect();
    const buffer = win.get_buffer_rect();
    const scale = actor.get_resource_scale();
    const texture = actor.paint_to_content(null).get_texture();
    const x = Math.round((frame.x - buffer.x) * scale);
    const y = Math.round((frame.y - buffer.y) * scale);
    const w = Math.min(Math.round(frame.width * scale), texture.get_width() - x);
    const h = Math.min(Math.round(frame.height * scale), texture.get_height() - y);
    const stream = file.create(Gio.FileCreateFlags.PRIVATE, null);
    await new Promise((resolve, reject) => {
        Shell.Screenshot.composite_to_stream(texture, x, y, w, h, scale,
            null, 0, 0, 1, stream, (_o, res) => {
                try {
                    Shell.Screenshot.composite_to_stream_finish(res);
                    resolve();
                } catch (e) {
                    reject(e);
                }
            });
    });
    stream.close(null);
    // the logical size of exactly the pixels written
    return {x: frame.x, y: frame.y, w: Math.round(w / scale), h: Math.round(h / scale), scale, pw: w, ph: h};
}
