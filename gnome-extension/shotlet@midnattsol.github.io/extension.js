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
// Tagged windows are left out of Alt+Tab (both switchers build their lists
// from Meta.Display.get_tab_list, filtered here): a Wayland client cannot
// set skip-taskbar itself.
//
// It also owns dev.shotlet.Shell1 on the session bus, so Shotlet can tell
// that it is active, with Place(title, x, y) to move one of these windows.
// No polling: everything hangs off window signals, and disable() undoes it.
//
// Captures without prompts. Installing this extension is the consent: it
// takes the screenshot itself, inside the shell, and hands it to a new
// Shotlet process. No method here returns screen contents to a caller.
//   - its own keybinding (capture-shortcut in its GSettings schema,
//     default Print), left unbound while one of GNOME's own screenshot
//     shortcuts holds the same key: it never fights GNOME for a key
//   - Capture() on the bus, for Shotlet's tray menu and a `shotlet` run
//     from a terminal: only honoured for a caller running the shotlet
//     binary, one at a time and at most once a second, never on the lock
//     screen; it replies only whether a capture was started
// The capture: Shell.Screenshot.screenshot_area for each monitor (a few
// strips of it at an integer scale, encoded in parallel), each painted at
// its monitor's own scale and without the cursor; that API has no flash or
// shutter sound (those belong to the shell's screenshot UI). Each area is a
// PNG in a fresh 0600 file in $XDG_RUNTIME_DIR/shotlet (a 0700 directory,
// checked to be ours), then
//   shotlet --from-shell ID --monitors "x,y,w,h,scale;..."
//           --pieces "x,y,w,h,scale;..." --t0 MS
// starts with the logical layout; it reads the files and deletes them at
// once. Nothing is written anywhere else; leftovers older than a minute (a
// Shotlet that failed to start) are deleted.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Util from 'resource:///org/gnome/shell/misc/util.js';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';
import {Recorder} from './recorder.js';

const APP_ID = 'io.github.midnattsol.Shotlet';
const BUS_NAME = 'dev.shotlet.Shell1';
const OBJECT_PATH = '/dev/shotlet/Shell1';
const IFACE = `<node>
  <interface name="dev.shotlet.Shell1">
    <property name="Version" type="u" access="read"/>
    <property name="Shortcuts" type="as" access="read"/>
    <property name="BlockedShortcuts" type="as" access="read"/>
    <method name="Capture">
      <arg type="b" name="started" direction="out"/>
    </method>
    <method name="StartRecording">
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="u" name="node" direction="out"/>
    </method>
    <method name="StopRecording"/>
    <method name="RecordSelect">
      <arg type="b" name="started" direction="out"/>
    </method>
    <signal name="RecordingStopRequested"/>
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

const SHORTCUT_KEY = 'capture-shortcut';
// GNOME's own screenshot shortcuts: a key one of these holds stays GNOME's
const GNOME_KEYS = ['show-screenshot-ui', 'screenshot', 'screenshot-window', 'show-screen-recording-ui'];
// Capture() over the bus: at most this often
const BUS_INTERVAL_MS = 1000;
// capture files nobody picked up are deleted after this
const STALE_MS = 60 * 1000;
const DESKTOP_ID = `${APP_ID}.desktop`;
// strips of a monitor: about this many pixels each, at most MAX_STRIPS
const PIXELS_PER_PIECE = 500 * 1000;
const MAX_STRIPS = 6;

// "<Ctrl><Shift>s", "<Shift><Control>S": the same key
function normalizeAccel(accel) {
    const mods = [];
    const key = accel.replace(/<([^>]+)>/g, (_m, mod) => {
        mod = mod.toLowerCase();
        mods.push({ctrl: 'control', primary: 'control', ctl: 'control'}[mod] ?? mod);
        return '';
    }).toLowerCase();
    return [...mods.sort(), key].join('+');
}

// errors Capture() answers with: dev.shotlet.Shell1.Error.<name>
class CaptureError extends Error {
    constructor(name, message) {
        super(message);
        this.dbusName = `dev.shotlet.Shell1.Error.${name}`;
    }
}

function monotonicMs() {
    return Math.floor(GLib.get_monotonic_time() / 1000);
}

// device and inode of what a path finally names (symlinks followed)
function fileId(path) {
    try {
        const info = Gio.File.new_for_path(path).query_info(
            'unix::device,unix::inode', Gio.FileQueryInfoFlags.NONE, null);
        return `${info.get_attribute_uint32('unix::device')}:${info.get_attribute_uint64('unix::inode')}`;
    } catch {
        return null;
    }
}

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

        this._injections = new InjectionManager();
        this._injections.overrideMethod(Meta.Display.prototype, 'get_tab_list',
            original => function (...args) {
                return original.call(this, ...args).filter(w => !roleOf(w));
            });

        this._settings = this.getSettings();
        this._gnomeKeys = new Gio.Settings({schema_id: 'org.gnome.shell.keybindings'});
        this._bound = false;
        this._busy = false;
        this._lastBusCapture = -BUS_INTERVAL_MS;
        this._settingsIds = [
            this._settings.connect(`changed::${SHORTCUT_KEY}`, () => this._bindShortcut()),
            ...GNOME_KEYS.map(k => this._gnomeKeys.connect(`changed::${k}`, () => this._bindShortcut())),
        ];
        this._bindShortcut();
        this._removeStale();

        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session,
            BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
        this._recorder = new Recorder(this);
    }

    disable() {
        this._recorder.destroy();
        this._recorder = null;
        this._unbindShortcut();
        for (const id of this._settingsIds.slice(0, 1))
            this._settings.disconnect(id);
        for (const id of this._settingsIds.slice(1))
            this._gnomeKeys.disconnect(id);
        this._settingsIds = [];
        this._settings = null;
        this._gnomeKeys = null;
        if (this._idleId)
            GLib.source_remove(this._idleId);
        this._idleId = 0;
        this._injections.clear();
        this._injections = null;
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
        return 3;
    }

    // recordings (recorder.js)
    StartRecordingAsync(params, invocation) {
        this._recorder.startCall(params, invocation);
    }

    StopRecordingAsync(params, invocation) {
        this._recorder.stopCall(params, invocation);
    }

    RecordSelectAsync(params, invocation) {
        this._recorder.selectCall(params, invocation);
    }

    get Shortcuts() {
        return this._bound ? this._settings.get_strv(SHORTCUT_KEY) : [];
    }

    get BlockedShortcuts() {
        return this._bound ? [] : this._blocked ?? [];
    }

    // --- capture

    // Bind capture-shortcut unless GNOME's screenshot shortcuts hold one
    // of its keys (two bindings for one key: mutter picks either).
    _bindShortcut() {
        this._unbindShortcut();
        const ours = this._settings.get_strv(SHORTCUT_KEY).filter(a => a);
        const gnome = new Set(GNOME_KEYS.flatMap(k => this._gnomeKeys.get_strv(k)).map(normalizeAccel));
        this._blocked = ours.filter(a => gnome.has(normalizeAccel(a)));
        if (ours.length === 0)
            return;
        if (this._blocked.length > 0) {
            console.log(`Shotlet: ${this._blocked.join(', ')} is GNOME's screenshot shortcut; Shotlet's stays unbound (shotlet gnome-integration shortcut KEY picks another)`);
            return;
        }
        const action = Main.wm.addKeybinding(SHORTCUT_KEY, this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
            () => {
                this._capture(monotonicMs(), false).catch(e =>
                    console.warn(`Shotlet: capture failed: ${e.message}`));
            });
        this._bound = action !== Meta.KeyBindingAction.NONE;
    }

    _unbindShortcut() {
        if (this._bound)
            Main.wm.removeKeybinding(SHORTCUT_KEY);
        this._bound = false;
    }

    // Capture() from the bus: the reply says whether a capture started.
    async CaptureAsync(_params, invocation) {
        const t0 = monotonicMs();
        try {
            await this._checkCaller(invocation.get_sender());
            const now = monotonicMs();
            if (this._busy || now - this._lastBusCapture < BUS_INTERVAL_MS)
                throw new CaptureError('Busy', 'one capture at a time, at most one a second');
            this._lastBusCapture = now;
            await this._capture(t0, true);
            invocation.return_value(new GLib.Variant('(b)', [true]));
        } catch (e) {
            invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
        }
    }

    // Only the shotlet program itself may ask: the caller's executable
    // must be the very file we would start.
    async _checkCaller(sender) {
        const pid = await new Promise((resolve, reject) => {
            Gio.DBus.session.call('org.freedesktop.DBus',
                '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetConnectionUnixProcessID',
                new GLib.Variant('(s)', [sender]), new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE, 2000, null, (conn, res) => {
                    try {
                        resolve(conn.call_finish(res).deepUnpack()[0]);
                    } catch (e) {
                        reject(e);
                    }
                });
        });
        const caller = fileId(`/proc/${pid}/exe`);
        const ours = this._shotletPath();
        if (!caller || !ours || caller !== fileId(ours))
            throw new CaptureError('AccessDenied', 'only Shotlet may ask for a capture');
    }

    _shotletPath() {
        const configured = this._settings.get_string('shotlet-path');
        if (configured && GLib.path_is_absolute(configured))
            return configured;
        const exe = Gio.DesktopAppInfo.new(DESKTOP_ID)?.get_executable();
        if (exe && GLib.path_is_absolute(exe))
            return exe;
        return GLib.find_program_in_path(exe || 'shotlet');
    }

    // $XDG_RUNTIME_DIR/shotlet: a 0700 directory of ours (not a symlink)
    _captureDir() {
        const dir = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'shotlet']);
        GLib.mkdir_with_parents(dir, 0o700);
        const info = Gio.File.new_for_path(dir).query_info('standard::type,unix::uid,unix::mode',
            Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        if (info.get_file_type() !== Gio.FileType.DIRECTORY ||
            info.get_attribute_uint32('unix::uid') !== new Gio.Credentials().get_unix_user() ||
            (info.get_attribute_uint32('unix::mode') & 0o077) !== 0)
            throw new Error(`${dir} is not a private directory`);
        return dir;
    }

    _removeStale() {
        try {
            const dir = Gio.File.new_for_path(this._captureDir());
            const now = Date.now();
            const it = dir.enumerate_children('standard::name,time::modified',
                Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            for (let info; (info = it.next_file(null));) {
                const name = info.get_name();
                const age = now - info.get_attribute_uint64('time::modified') * 1000;
                if (/^shot-[A-Za-z0-9]+-[0-9]+\.png$/.test(name) && age > STALE_MS)
                    dir.get_child(name).delete(null);
            }
            it.close(null);
        } catch (e) {
            console.warn(`Shotlet: ${e.message}`);
        }
    }

    // The areas to grab: each monitor, a monitor at an integer scale in a
    // few strips so the PNG encoding (Shell.Screenshot does it on a
    // worker thread per call) runs in parallel. A fractional monitor stays
    // whole: a strip's edge would fall between its pixels.
    _plan() {
        const monitors = Main.layoutManager.monitors.map(m => ({
            x: m.x, y: m.y, w: m.width, h: m.height,
            scale: global.display.get_monitor_scale(m.index),
        }));
        const pieces = [];
        for (const m of monitors) {
            const px = m.w * m.h * m.scale * m.scale;
            const n = Number.isInteger(m.scale)
                ? Math.min(MAX_STRIPS, Math.max(1, Math.min(m.h, Math.ceil(px / PIXELS_PER_PIECE))))
                : 1;
            for (let i = 0; i < n; i++) {
                const y0 = m.y + Math.floor(i * m.h / n);
                const y1 = m.y + Math.floor((i + 1) * m.h / n);
                pieces.push({x: m.x, y: y0, w: m.w, h: y1 - y0, scale: m.scale});
            }
        }
        const fmt = list => list.map(r => [r.x, r.y, r.w, r.h, r.scale].join(',')).join(';');
        return {monitors: fmt(monitors), pieces, piecesArg: fmt(pieces)};
    }

    // Take the screenshot and start shotlet on it.
    async _capture(t0, fromBus, extra = []) {
        if (this._busy)
            throw new CaptureError('Busy', 'a capture is under way');
        if (Main.sessionMode.isLocked)
            throw new CaptureError('Locked', 'the screen is locked');
        const exe = this._shotletPath();
        if (!exe)
            throw new Error('shotlet not found');
        this._busy = true;
        const files = [];
        try {
            // a menu (the tray's) that asked for this closes first
            if (fromBus)
                await this._popupsClosed();
            this._removeStale();
            const dir = this._captureDir();
            const id = GLib.uuid_string_random().replace(/-/g, '');
            const plan = this._plan();
            // every area is painted now, in this one main loop iteration
            // (the same frame); the PNGs are written on worker threads
            const shots = plan.pieces.map((p, k) => {
                const file = Gio.File.new_for_path(GLib.build_filenamev([dir, `shot-${id}-${k}.png`]));
                // O_EXCL, mode 0600
                const stream = file.create(Gio.FileCreateFlags.PRIVATE, null);
                files.push(file);
                return new Promise((resolve, reject) => {
                    new Shell.Screenshot().screenshot_area(p.x, p.y, p.w, p.h, stream, (obj, res) => {
                        try {
                            obj.screenshot_area_finish(res);
                            stream.close(null);
                            resolve();
                        } catch (e) {
                            reject(e);
                        }
                    });
                });
            });
            // the overview would hold the editor as one more window
            if (Main.overview.visible)
                Main.overview.hide();
            await Promise.all(shots);
            const t1 = monotonicMs();
            Util.trySpawn([exe, '--from-shell', id, '--monitors', plan.monitors,
                '--pieces', plan.piecesArg, '--t0', `${t0}`, ...extra]);
            console.log(`Shotlet: captured ${plan.pieces.length} areas in ${t1 - t0} ms, started shotlet`);
            files.length = 0;
        } finally {
            this._busy = false;
            for (const f of files) {
                try {
                    f.delete(null);
                } catch {}
            }
        }
    }

    _popupsClosed() {
        return new Promise(resolve => {
            let waited = 0, sawPopup = false;
            const step = () => {
                if (Main.actionMode === Shell.ActionMode.POPUP && waited < 500) {
                    sawPopup = true;
                    waited += 20;
                    return GLib.SOURCE_CONTINUE;
                }
                // let its fade-out finish
                if (sawPopup)
                    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => resolve() ?? GLib.SOURCE_REMOVE);
                else
                    resolve();
                return GLib.SOURCE_REMOVE;
            };
            if (step() === GLib.SOURCE_CONTINUE)
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, 20, step);
        });
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
        if (!st || (st.role !== 'quick' && st.role !== 'rec'))
            return;
        const r = win.get_frame_rect();
        if (r.width === 0 || r.height === 0)
            return;
        const monitors = global.display.get_n_monitors();
        const area = win.get_work_area_for_monitor(Math.min(st.monitor, monitors - 1));
        // a recording's control: "shotlet:rec:X:Y", where Shotlet wants it
        const [x, y] = st.role === 'rec' ? win.get_title().split(':').slice(2, 4).map(Number)
            : [area.x + EDGE, area.y + area.height - r.height - EDGE];
        if (r.x !== x || r.y !== y)
            win.move_frame(true, x, y);
    }

    _onFocus(win) {
        const st = this._windows.get(win);
        if (!st || (st.role !== 'quick' && st.role !== 'rec'))
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
