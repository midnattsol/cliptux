// Capture modes for the Shotlet extension: one shortcut per mode, the
// self-timer's countdown, and the arguments a mode adds to the shotlet
// the extension starts.
//
//   fullscreen-shortcut  the monitor under the pointer
//   screens-shortcut     every monitor
//   previous-shortcut    the last selection again
//   window-shortcut      click a window (windowpick.js)
//   scroll-shortcut      a region scrolled and stitched (scroll.js)
//   timer-shortcut       area capture after timer-seconds
//
// Each is bound like capture-shortcut: left unbound while one of GNOME's
// own screenshot shortcuts (or capture-shortcut) holds the same key. The
// countdown is drawn by the shell and gone before the screenshot is
// taken, and it never takes the keyboard focus (a menu left open for the
// timer stays open).

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export const MODES = ['area', 'fullscreen', 'screens', 'previous', 'window', 'scroll'];

// shortcut key -> [mode, delay from timer-seconds]
const KEYS = {
    'fullscreen-shortcut': ['fullscreen', false],
    'screens-shortcut': ['screens', false],
    'previous-shortcut': ['previous', false],
    'window-shortcut': ['window', false],
    'scroll-shortcut': ['scroll', false],
    'timer-shortcut': ['area', true],
};

export class ModeShortcuts {
    // capture(mode, delaySeconds, t0) starts a capture; normalize maps an
    // accelerator to a comparable string
    constructor(settings, gnomeKeys, gnomeKeyNames, normalize, capture) {
        this._settings = settings;
        this._gnomeKeys = gnomeKeys;
        this._gnomeKeyNames = gnomeKeyNames;
        this._normalize = normalize;
        this._capture = capture;
        this._bound = new Set();
        this._ids = Object.keys(KEYS).map(k =>
            settings.connect(`changed::${k}`, () => this.bind()));
    }

    destroy() {
        this.unbind();
        for (const id of this._ids)
            this._settings.disconnect(id);
        this._ids = [];
    }

    // keys held by GNOME's screenshot shortcuts or by the area capture
    _taken() {
        const keys = this._gnomeKeyNames.flatMap(k => this._gnomeKeys.get_strv(k));
        keys.push(...this._settings.get_strv('capture-shortcut'));
        return new Set(keys.map(this._normalize));
    }

    bind() {
        this.unbind();
        const taken = this._taken();
        for (const [key, [mode, timer]] of Object.entries(KEYS)) {
            const accels = this._settings.get_strv(key).filter(a => a);
            if (accels.length === 0 || accels.some(a => taken.has(this._normalize(a))))
                continue;
            const action = Main.wm.addKeybinding(key, this._settings,
                Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
                Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
                () => {
                    const t0 = Math.floor(GLib.get_monotonic_time() / 1000);
                    const delay = timer ? this._settings.get_uint('timer-seconds') : 0;
                    this._capture(mode, delay, t0).catch(e =>
                        console.warn(`Shotlet: ${mode} capture failed: ${e.message}`));
                });
            if (action !== Meta.KeyBindingAction.NONE)
                this._bound.add(key);
        }
    }

    unbind() {
        for (const key of this._bound)
            Main.wm.removeKeybinding(key);
        this._bound.clear();
    }

    // the bound mode shortcuts, "mode=accel"
    describe() {
        return [...this._bound].map(k => `${KEYS[k][1] ? 'timer' : KEYS[k][0]}=${this._settings.get_strv(k)[0]}`);
    }
}

// Extra arguments for the shotlet that edits a mode's capture.
export function modeArgs(mode) {
    if (mode === 'area')
        return [];
    const [x, y] = global.get_pointer();
    return ['--mode', mode, '--pointer', `${x},${y}`];
}

// A small countdown in the middle of the monitor under the pointer, in
// Shotlet's glass style. Resolves true when it ran out, false when
// clicked away; it is destroyed before resolving.
export function countdown(seconds) {
    return new Promise(resolve => {
        const monitor = Main.layoutManager.monitors[global.display.get_current_monitor()] ??
            Main.layoutManager.primaryMonitor;
        const box = new St.Bin({
            reactive: true,
            style: 'background-color: rgba(30, 30, 32, 0.82); border-radius: 32px;' +
                ' border: 1px solid rgba(255, 255, 255, 0.14); padding: 14px 34px;',
        });
        const label = new St.Label({
            text: `${seconds}`,
            style: 'font-size: 64px; font-weight: 600; color: #ffffff;',
        });
        box.set_child(label);
        Main.layoutManager.addTopChrome(box);
        const place = () => {
            box.set_position(
                monitor.x + Math.floor((monitor.width - box.width) / 2),
                monitor.y + Math.floor((monitor.height - box.height) / 2));
        };
        place();
        let left = seconds;
        let timer = 0;
        const finish = ran => {
            if (timer)
                GLib.source_remove(timer);
            timer = 0;
            Main.layoutManager.removeChrome(box);
            box.destroy();
            // one frame for the stage to repaint without it
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, () => resolve(ran) ?? GLib.SOURCE_REMOVE);
        };
        box.connect('button-press-event', () => {
            finish(false);
            return Clutter.EVENT_STOP;
        });
        timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            left -= 1;
            if (left <= 0) {
                timer = 0;
                finish(true);
                return GLib.SOURCE_REMOVE;
            }
            label.text = `${left}`;
            place();
            return GLib.SOURCE_CONTINUE;
        });
        console.log(`Shotlet: timer ${seconds} s`);
    });
}
