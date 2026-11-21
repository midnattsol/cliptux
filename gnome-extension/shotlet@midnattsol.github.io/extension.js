// Shotlet integration for GNOME Shell 45+.
//
// Mutter has no layer-shell protocol, and a Wayland client cannot place its
// own window or keep it above others. This extension does that for
// Shotlet's floating windows only: toplevels whose app id is
// "io.github.midnattsol.Shotlet" and
// whose title is a role tag.
//
//   shotlet:quick       the after-capture thumbnail stack: bottom-left of
//                       the monitor under the pointer, above other windows,
//                       on every workspace, and the keyboard focus goes
//                       back to the window that had it when it appeared
//   shotlet:pin[:...]   a pinned screenshot: above other windows, on every
//                       workspace (it may take the focus when clicked)
//
// It also owns dev.shotlet.Shell1 on the session bus, so Shotlet can tell
// that it is active, with Place(title, x, y) to move one of these windows.
// No polling: everything hangs off window signals, and disable() undoes it.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const APP_ID = 'io.github.midnattsol.Shotlet';
const BUS_NAME = 'dev.shotlet.Shell1';
const OBJECT_PATH = '/dev/shotlet/Shell1';
const IFACE = `<node>
  <interface name="dev.shotlet.Shell1">
    <property name="Version" type="u" access="read"/>
    <method name="Place">
      <arg type="s" name="title" direction="in"/>
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="b" name="found" direction="out"/>
    </method>
  </interface>
</node>`;

// gap between the thumbnail window and the work area's edges (its own
// transparent margin adds to it)
const EDGE = 8;
// a focus change this soon after the thumbnail appears is mutter's
// focus-on-map, not the person clicking it
const FOCUS_ON_MAP_MS = 1000;

function roleOf(win) {
    if (!win || win.get_wm_class() !== APP_ID)
        return null;
    const title = win.get_title() ?? '';
    if (!title.startsWith('shotlet:'))
        return null;
    return title.split(':')[1] || null;
}

export default class ShotletExtension extends Extension {
    enable() {
        // window -> {ids: [signal ids], role, monitor, handed_back, born}
        this._windows = new Map();
        this._idleId = 0;
        this._createdId = global.display.connect('window-created',
            (_display, win) => this._watch(win));
        for (const actor of global.get_window_actors())
            this._watch(actor.meta_window);

        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session,
            BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        if (this._idleId)
            GLib.source_remove(this._idleId);
        this._idleId = 0;
        global.display.disconnect(this._createdId);
        this._createdId = 0;
        for (const [win, st] of this._windows) {
            for (const id of st.ids)
                win.disconnect(id);
            if (st.role) {
                win.unmake_above();
                win.unstick();
            }
        }
        this._windows.clear();
        this._windows = null;
        Gio.bus_unown_name(this._nameId);
        this._nameId = 0;
        this._dbus.unexport();
        this._dbus = null;
    }

    get Version() {
        return 1;
    }

    Place(title, x, y) {
        for (const win of this._windows.keys()) {
            if (roleOf(win) && win.get_title() === title) {
                win.move_frame(true, x, y);
                return true;
            }
        }
        return false;
    }

    _watch(win) {
        // a new Wayland window has no app id yet: decide once it has one
        const cls = win?.get_wm_class();
        if (!win || this._windows.has(win) || (cls && cls !== APP_ID))
            return;
        const st = {
            ids: [],
            role: null,
            monitor: global.display.get_current_monitor(),
            handed_back: false,
            born: GLib.get_monotonic_time() / 1000,
        };
        this._windows.set(win, st);
        // the title can arrive after the window: wait for the tag
        st.ids.push(win.connect('notify::title', () => this._apply(win)));
        st.ids.push(win.connect('notify::wm-class', () => {
            if (win.get_wm_class() === APP_ID)
                this._apply(win);
            else
                this._forget(win);
        }));
        st.ids.push(win.connect('size-changed', () => this._place(win)));
        // mutter places a window when it maps: move it after that
        st.ids.push(win.connect('shown', () => this._place(win)));
        st.ids.push(win.connect('focus', () => this._onFocus(win)));
        st.ids.push(win.connect('unmanaged', () => this._forget(win)));
        this._apply(win);
    }

    _forget(win) {
        const st = this._windows?.get(win);
        if (!st)
            return;
        for (const id of st.ids)
            win.disconnect(id);
        this._windows.delete(win);
    }

    _apply(win) {
        const st = this._windows.get(win);
        const role = roleOf(win);
        if (!st || !role || st.role)
            return;
        st.role = role;
        // no zoom-in effect for a corner thumbnail
        const actor = win.get_compositor_private();
        if (actor && role === 'quick')
            Main.wm.skipNextEffect(actor);
        win.make_above();
        win.stick();
        this._place(win);
    }

    _place(win) {
        const st = this._windows.get(win);
        if (!st || st.role !== 'quick')
            return;
        const r = win.get_frame_rect();
        if (r.width === 0 || r.height === 0)
            return;
        const monitors = global.display.get_n_monitors();
        const area = win.get_work_area_for_monitor(Math.min(st.monitor, monitors - 1));
        const x = area.x + EDGE;
        const y = area.y + area.height - r.height - EDGE;
        if (r.x !== x || r.y !== y)
            win.move_frame(true, x, y);
    }

    _onFocus(win) {
        const st = this._windows.get(win);
        if (!st || st.role !== 'quick')
            return;
        const now = GLib.get_monotonic_time() / 1000;
        if (st.handed_back || now - st.born > FOCUS_ON_MAP_MS)
            return;
        st.handed_back = true;
        // focus-on-map: hand the keyboard back, without raising anything,
        // to the most recently used window that is not Shotlet's (the
        // editor that just closed is Shotlet's too)
        const ws = global.workspace_manager.get_active_workspace();
        const prev = global.display.get_tab_list(Meta.TabList.NORMAL_ALL, ws)
            .find(w => w !== win && w.get_wm_class() !== APP_ID);
        if (!prev)
            return;
        if (this._idleId)
            GLib.source_remove(this._idleId);
        this._idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._idleId = 0;
            if (this._windows?.has(win))
                prev.focus(global.get_current_time());
            return GLib.SOURCE_REMOVE;
        });
    }
}
