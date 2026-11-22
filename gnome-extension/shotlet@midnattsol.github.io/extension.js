// Shotlet integration for GNOME Shell 45+.
//
// Mutter has no layer-shell protocol, and a Wayland client cannot place its
// own window or keep it above others. This extension does that for
// Shotlet's floating windows only (windows.js): toplevels titled with a
// role tag, the after-capture thumbnail (shotlet:quick), pins
// (shotlet:pin) and a recording's control (shotlet:rec), kept above other
// windows and out of Alt+Tab.
//
// It also owns dev.shotlet.Shell1 on the session bus, so Shotlet can tell
// that it is active, with Place(title, x, y) to move one of these windows.
// No polling: everything hangs off window and settings signals, and
// disable() undoes it.
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
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {RECORDER_IFACE, Recorder} from './recorder.js';
import {MODES, ModeShortcuts, countdown, modeArgs} from './modes.js';
import {captureWindow, pickWindow} from './windowpick.js';
import {ScrollSessions} from './scroll.js';
import {APP_ID, CaptureError, fileId, monotonicMs, normalizeAccel, roleOf} from './util.js';
import {ShotletWindows} from './windows.js';

const BUS_NAME = 'dev.shotlet.Shell1';
const OBJECT_PATH = '/dev/shotlet/Shell1';
const IFACE = `<node>
  <interface name="dev.shotlet.Shell1">
    <property name="Version" type="u" access="read"/>
    <property name="Shortcuts" type="as" access="read"/>
    <property name="BlockedShortcuts" type="as" access="read"/>
    <property name="ModeShortcuts" type="as" access="read"/>
    <method name="Capture">
      <arg type="b" name="started" direction="out"/>
    </method>
    ${RECORDER_IFACE}
    <method name="CaptureMode">
      <arg type="s" name="mode" direction="in"/>
      <arg type="u" name="delay" direction="in"/>
      <arg type="b" name="started" direction="out"/>
    </method>
    <method name="ScrollBegin">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="b" name="auto" direction="in"/>
      <arg type="s" name="session" direction="out"/>
    </method>
    <method name="ScrollStep">
      <arg type="s" name="session" direction="in"/>
      <arg type="i" name="clicks" direction="in"/>
      <arg type="s" name="capture" direction="out"/>
    </method>
    <method name="ScrollEnd">
      <arg type="s" name="session" direction="in"/>
    </method>
    <method name="Place">
      <arg type="s" name="title" direction="in"/>
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="b" name="found" direction="out"/>
    </method>
  </interface>
</node>`;

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

export default class ShotletExtension extends Extension {
    enable() {
        this._windows = new ShotletWindows();

        this._settings = this.getSettings();
        this._gnomeKeys = new Gio.Settings({schema_id: 'org.gnome.shell.keybindings'});
        this._bound = false;
        this._busy = false;
        this._lastBusCapture = -BUS_INTERVAL_MS;
        this._settingsIds = [
            this._settings.connect(`changed::${SHORTCUT_KEY}`, () => this._bindShortcut()),
            ...GNOME_KEYS.map(k => this._gnomeKeys.connect(`changed::${k}`, () => this._bindShortcut())),
        ];
        this._modes = new ModeShortcuts(this._settings, this._gnomeKeys, GNOME_KEYS,
            normalizeAccel, (mode, delay, t0) => this._capture(t0, false, mode, delay),
            () => this._shotletPath());
        this._bindShortcut();
        this._scroll = new ScrollSessions(s => this._checkCaller(s), () => this._captureDir(),
            () => this._windows.showing('scroll'));
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
        this._scroll.destroy();
        this._scroll = null;
        this._modes.destroy();
        this._modes = null;
        this._unbindShortcut();
        for (const id of this._settingsIds.slice(0, 1))
            this._settings.disconnect(id);
        for (const id of this._settingsIds.slice(1))
            this._gnomeKeys.disconnect(id);
        this._settingsIds = [];
        this._settings = null;
        this._gnomeKeys = null;
        this._windows.destroy();
        this._windows = null;
        Gio.bus_unown_name(this._nameId);
        this._nameId = 0;
        this._dbus.unexport();
        this._dbus = null;
    }

    get Version() {
        return 3;
    }

    get Shortcuts() {
        return this._bound ? this._settings.get_strv(SHORTCUT_KEY) : [];
    }

    // the capture modes' bound keys, "mode=accel"
    get ModeShortcuts() {
        return this._modes?.describe() ?? [];
    }

    get BlockedShortcuts() {
        return this._bound ? [] : this._blocked ?? [];
    }

    // --- capture

    // Bind capture-shortcut unless GNOME's screenshot shortcuts hold one
    // of its keys (two bindings for one key: mutter picks either).
    _bindShortcut() {
        this._unbindShortcut();
        this._modes?.bind();
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

    // CaptureMode(mode, delay): Capture() for one of the capture modes,
    // after a countdown of `delay` seconds (at most 60).
    async CaptureModeAsync([mode, delay], invocation) {
        const t0 = monotonicMs();
        try {
            await this._checkCaller(invocation.get_sender());
            if (!MODES.includes(mode) || delay > 60)
                throw new CaptureError('Failed', 'no such capture mode');
            const now = monotonicMs();
            if (this._busy || now - this._lastBusCapture < BUS_INTERVAL_MS)
                throw new CaptureError('Busy', 'one capture at a time, at most one a second');
            this._lastBusCapture = now;
            // the reply goes out once the capture (or the countdown, or the
            // window picker) is under way
            const started = this._capture(t0, true, mode, delay);
            started.catch(e => console.warn(`Shotlet: ${mode} capture failed: ${e.message}`));
            invocation.return_value(new GLib.Variant('(b)', [true]));
        } catch (e) {
            invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
        }
    }

    async ScrollBeginAsync([x, y, w, h, auto], invocation) {
        await this._reply(invocation, 's', () => this._scroll.begin(invocation.get_sender(), x, y, w, h, auto));
    }

    async ScrollStepAsync([id, clicks], invocation) {
        await this._reply(invocation, 's', () => this._scroll.step(invocation.get_sender(), id, clicks));
    }

    async ScrollEndAsync([id], invocation) {
        await this._reply(invocation, null, () => this._scroll.end(invocation.get_sender(), id));
    }

    async _reply(invocation, type, fn) {
        try {
            const v = await fn();
            invocation.return_value(type ? new GLib.Variant(`(${type})`, [v]) : null);
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

    // Take the screenshot (of every monitor, or of the window picked) and
    // start shotlet on it, after `delay` seconds.
    async _capture(t0, fromBus, mode = 'area', delay = 0, extra = []) {
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
            if (delay > 0 && !await countdown(delay))
                return;
            if (mode === 'window')
                await this._captureWindow(t0, exe, files);
            else
                await this._captureScreens(t0, exe, mode, extra, files);
        } finally {
            this._busy = false;
            for (const f of files) {
                try {
                    f.delete(null);
                } catch {}
            }
        }
    }

    // Every monitor in a few areas (_plan), then shotlet started on them;
    // `files` holds the capture files until shotlet owns them.
    async _captureScreens(t0, exe, mode, extra, files) {
        this._removeStale();
        const dir = this._captureDir();
        const id = GLib.uuid_string_random().replace(/-/g, '');
        const plan = this._plan();
        // every area is painted now, in this one main loop iteration
        // (the same frame); the PNGs are written on worker threads
        const shots = plan.pieces.map((p, k) => this._shoot(p, dir, `shot-${id}-${k}.png`, files));
        // the overview would hold the editor as one more window
        if (Main.overview.visible)
            Main.overview.hide();
        await Promise.all(shots);
        const t1 = monotonicMs();
        Util.trySpawn([exe, '--from-shell', id, '--monitors', plan.monitors,
            '--pieces', plan.piecesArg, '--t0', `${t0}`, ...modeArgs(mode), ...extra]);
        console.log(`Shotlet: captured ${plan.pieces.length} areas in ${t1 - t0} ms, started shotlet`);
        files.length = 0;
    }

    // Paint the area `p` now and write it as a PNG to a new file `name` in
    // `dir` (added to `files`) on a worker thread; resolves once written.
    _shoot(p, dir, name, files) {
        const file = Gio.File.new_for_path(GLib.build_filenamev([dir, name]));
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
    }

    // Pick a window and capture just that window (windowpick.js).
    async _captureWindow(t0, exe, files) {
        const win = await pickWindow(w => roleOf(w) !== null);
        if (!win)
            return;
        const id = GLib.uuid_string_random().replace(/-/g, '');
        const file = Gio.File.new_for_path(GLib.build_filenamev([this._captureDir(), `shot-${id}-0.png`]));
        files.push(file);
        const r = await captureWindow(win, file);
        const layout = [r.x, r.y, r.w, r.h, r.scale].join(',');
        Util.trySpawn([exe, '--from-shell', id, '--monitors', layout, '--pieces', layout,
            '--t0', `${t0}`, '--mode', 'window']);
        console.log(`Shotlet: captured a ${r.pw}x${r.ph} window, started shotlet`);
        files.length = 0;
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
        return this._windows.place(title, x, y);
    }
}
