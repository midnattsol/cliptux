// Scrolling captures for the Shotlet extension: Shotlet picks a region,
// then asks for one frame of it after each scroll step and stitches them.
//
//   ScrollBegin(x, y, w, h, auto) -> session   (logical region)
//   ScrollStep(session, clicks)   -> capture id (one PNG, shot-ID-0.png)
//   ScrollEnd(session)
//
// How it stays safe:
// - only the shotlet binary may begin a session (the same caller check as
//   Capture), one session at a time, never on the lock screen; only the
//   bus connection that began it may step or end it, and it ends by
//   itself when that connection goes away, after 30 s without a step, or
//   after 5 minutes;
// - a step is honoured only while Shotlet's scrolling control (a window
//   of the Shotlet app titled "shotlet:scroll") is on screen;
// - frames are only ever of the region given at the start, written like
//   every capture: fresh 0600 files in the private capture directory;
// - with `auto`, a virtual pointer exists for the session only: it puts
//   the pointer in the middle of the region and turns the wheel there
//   (at most 10 notches a step, at most 25 steps a second); the pointer
//   goes back where it was at the end. Nothing else is injected.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import System from 'system';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const IDLE_MS = 30 * 1000;
const MAX_MS = 5 * 60 * 1000;
const MIN_STEP_MS = 40;
const MAX_CLICKS = 10;
// time for the app to scroll and paint before the frame is taken
const SETTLE_MS = 160;

class ScrollError extends Error {
    constructor(name, message) {
        super(message);
        this.dbusName = `dev.shotlet.Shell1.Error.${name}`;
    }
}

function wait(ms) {
    return new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => resolve() ?? GLib.SOURCE_REMOVE));
}

export class ScrollSessions {
    // checkCaller(sender) throws unless it is shotlet; captureDir() is the
    // private directory; hudShown() says whether the control is up
    constructor(checkCaller, captureDir, hudShown) {
        this._checkCaller = checkCaller;
        this._captureDir = captureDir;
        this._hudShown = hudShown;
        this._session = null;
    }

    destroy() {
        this._end();
    }

    _inMonitors(x, y, w, h) {
        return Main.layoutManager.monitors.some(m =>
            x >= m.x && y >= m.y && x + w <= m.x + m.width && y + h <= m.y + m.height);
    }

    async begin(sender, x, y, w, h, auto) {
        await this._checkCaller(sender);
        if (Main.sessionMode.isLocked)
            throw new ScrollError('Locked', 'the screen is locked');
        if (this._session)
            throw new ScrollError('Busy', 'a scrolling capture is under way');
        if (w < 16 || h < 16 || !this._inMonitors(x, y, w, h))
            throw new ScrollError('Failed', 'the region must lie on one monitor');
        const id = GLib.uuid_string_random().replace(/-/g, '').slice(0, 16);
        const s = {id, sender, x, y, w, h, n: 0, last: 0, dev: null, pointer: null, born: Date.now()};
        if (auto) {
            const seat = Clutter.get_default_backend().get_default_seat();
            s.dev = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
            s.pointer = global.get_pointer().slice(0, 2);
        }
        s.watch = Gio.bus_watch_name_on_connection(Gio.DBus.session, sender,
            Gio.BusNameWatcherFlags.NONE, null, () => this._end());
        s.timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1000, () => {
            const now = Date.now();
            if (now - s.born > MAX_MS || now - (s.last || s.born) > IDLE_MS || Main.sessionMode.isLocked) {
                s.timer = 0;
                this._end();
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._session = s;
        console.log(`Shotlet: scrolling capture of ${w}x${h} at ${x},${y}${auto ? ', scrolling for the person' : ''}`);
        return id;
    }

    _own(sender, id) {
        const s = this._session;
        if (!s || s.id !== id || s.sender !== sender)
            throw new ScrollError('AccessDenied', 'not this caller\'s scrolling capture');
        return s;
    }

    async step(sender, id, clicks) {
        const s = this._own(sender, id);
        if (!this._hudShown())
            throw new ScrollError('AccessDenied', 'Shotlet\'s scrolling control is not on screen');
        const now = Date.now();
        if (now - s.last < MIN_STEP_MS)
            throw new ScrollError('Busy', 'too many steps');
        s.last = now;
        if (clicks > 0 && s.dev) {
            this._wheel(s, Math.min(clicks, MAX_CLICKS));
            await wait(SETTLE_MS);
        }
        if (this._session !== s)
            throw new ScrollError('Failed', 'the scrolling capture ended');
        return this._grab(s);
    }

    _wheel(s, clicks) {
        const t = GLib.get_monotonic_time();
        s.dev.notify_absolute_motion(t, s.x + s.w / 2, s.y + s.h / 2);
        for (let i = 0; i < clicks; i++)
            s.dev.notify_discrete_scroll(t + i + 1, Clutter.ScrollDirection.DOWN, Clutter.ScrollSource.WHEEL);
    }

    async _grab(s) {
        const fid = `${s.id}s${s.n++}`;
        const file = Gio.File.new_for_path(GLib.build_filenamev([this._captureDir(), `shot-${fid}-0.png`]));
        const stream = file.create(Gio.FileCreateFlags.PRIVATE, null);
        try {
            await new Promise((resolve, reject) => {
                new Shell.Screenshot().screenshot_area(s.x, s.y, s.w, s.h, stream, (obj, res) => {
                    try {
                        obj.screenshot_area_finish(res);
                        resolve();
                    } catch (e) {
                        reject(e);
                    }
                });
            });
            stream.close(null);
        } catch (e) {
            try {
                file.delete(null);
            } catch {}
            throw e;
        }
        return fid;
    }

    end(sender, id) {
        this._own(sender, id);
        this._end();
    }

    _end() {
        const s = this._session;
        if (!s)
            return;
        this._session = null;
        if (s.timer)
            GLib.source_remove(s.timer);
        Gio.bus_unwatch_name(s.watch);
        if (s.dev) {
            if (s.pointer)
                s.dev.notify_absolute_motion(GLib.get_monotonic_time(), ...s.pointer);
            // the last reference: the device goes when it is collected
            s.dev = null;
            System.gc();
        }
        console.log(`Shotlet: scrolling capture ended after ${s.n} frames`);
    }
}
