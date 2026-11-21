// Small helpers of the Shotlet extension (extension.js).

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const APP_ID = 'io.github.midnattsol.Shotlet';

// "<Ctrl><Shift>s", "<Shift><Control>S": the same key
export function normalizeAccel(accel) {
    const mods = [];
    const key = accel.replace(/<([^>]+)>/g, (_m, mod) => {
        mod = mod.toLowerCase();
        mods.push({ctrl: 'control', primary: 'control', ctl: 'control'}[mod] ?? mod);
        return '';
    }).toLowerCase();
    return [...mods.sort(), key].join('+');
}

// errors Capture() answers with: dev.shotlet.Shell1.Error.<name>
export class CaptureError extends Error {
    constructor(name, message) {
        super(message);
        this.dbusName = `dev.shotlet.Shell1.Error.${name}`;
    }
}

export function monotonicMs() {
    return Math.floor(GLib.get_monotonic_time() / 1000);
}

// device and inode of what a path finally names (symlinks followed)
export function fileId(path) {
    try {
        const info = Gio.File.new_for_path(path).query_info(
            'unix::device,unix::inode', Gio.FileQueryInfoFlags.NONE, null);
        return `${info.get_attribute_uint32('unix::device')}:${info.get_attribute_uint64('unix::inode')}`;
    } catch {
        return null;
    }
}

export function roleOf(win) {
    if (!win || win.get_wm_class() !== APP_ID)
        return null;
    const title = win.get_title() ?? '';
    if (!title.startsWith('shotlet:'))
        return null;
    return title.split(':')[1] || null;
}
