// Screen recordings without prompts, for Shotlet only.
//
// StartRecording(a{sv}) asks mutter, from inside the shell, for a
// screencast of an area (org.gnome.Mutter.ScreenCast, RecordArea with
// is-recording, so GNOME shows its recording indicator) and answers with
// the PipeWire node; Shotlet reads the pictures from that node and
// encodes them itself. StopRecording() ends it. Like Capture(), both are
// honoured only for a caller running the shotlet binary the extension
// starts (ShotletExtension._checkCaller), one recording at a time, never
// on the lock screen; and the screencast ends as soon as that caller
// leaves the bus, whatever happens to it.
//
// While recording, a thin outline is drawn just outside the area (so it
// is not recorded), a stop button sits in the top bar, and, when asked,
// clicks (ripples) and keystrokes (a small label) are drawn inside the
// area, where they are recorded. Key presses are looked at only then.
//
// The record shortcut (record-shortcut, default <Shift><Super>r) starts
// Shotlet's area picker in record mode, or asks the running recording
// to stop (the RecordingStopRequested signal, which Shotlet listens to).

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Graphene from 'gi://Graphene';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const MUTTER = 'org.gnome.Mutter.ScreenCast';
const RECORD_KEY = 'record-shortcut';
const RIPPLE_MS = 450;
const KEY_HUD_MS = 1200;

function mutterCall(path, iface, method, params, type) {
    return new Promise((resolve, reject) => {
        Gio.DBus.session.call(MUTTER, path, iface, method, params,
            type ? new GLib.VariantType(type) : null, Gio.DBusCallFlags.NONE, 5000, null,
            (conn, res) => {
                try {
                    resolve(conn.call_finish(res));
                } catch (e) {
                    reject(e);
                }
            });
    });
}

export class Recorder {
    constructor(ext) {
        this._ext = ext;
        this._rec = null;
        this._bound = false;
        this._settingsId = ext._settings.connect(`changed::${RECORD_KEY}`, () => this._bind());
        this._bind();
    }

    destroy() {
        this._unbind();
        this._ext._settings.disconnect(this._settingsId);
        this._stop();
    }

    get active() {
        return this._rec !== null;
    }

    _bind() {
        this._unbind();
        if (this._ext._settings.get_strv(RECORD_KEY).filter(a => a).length === 0)
            return;
        const action = Main.wm.addKeybinding(RECORD_KEY, this._ext._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
            Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
            () => this._onShortcut());
        this._bound = action !== Meta.KeyBindingAction.NONE;
    }

    _unbind() {
        if (this._bound)
            Main.wm.removeKeybinding(RECORD_KEY);
        this._bound = false;
    }

    _onShortcut() {
        if (this._rec) {
            this.requestStop();
            return;
        }
        const t0 = Math.floor(GLib.get_monotonic_time() / 1000);
        this._ext._capture(t0, false, ['--then', 'record']).catch(e =>
            console.warn(`Shotlet: record failed: ${e.message}`));
    }

    requestStop() {
        this._ext._dbus?.emit_signal('RecordingStopRequested', null);
    }

    // StartRecording(a{sv} options) -> (u node)
    async startCall(params, invocation) {
        try {
            const sender = invocation.get_sender();
            await this._ext._checkCaller(sender);
            if (this._rec)
                throw this._error('Busy', 'a recording is under way');
            if (Main.sessionMode.isLocked)
                throw this._error('Locked', 'the screen is locked');
            const [opts] = params;
            const o = {};
            for (const [k, v] of Object.entries(opts))
                o[k] = v.deepUnpack();
            const node = await this._start(sender, o);
            invocation.return_value(new GLib.Variant('(u)', [node]));
        } catch (e) {
            invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
        }
    }

    // RecordSelect(): the picker in record mode, on a capture taken here
    async selectCall(_params, invocation) {
        try {
            await this._ext._checkCaller(invocation.get_sender());
            if (this._rec)
                throw this._error('Busy', 'a recording is under way');
            const t0 = Math.floor(GLib.get_monotonic_time() / 1000);
            await this._ext._capture(t0, true, ['--then', 'record']);
            invocation.return_value(new GLib.Variant('(b)', [true]));
        } catch (e) {
            invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
        }
    }

    async stopCall(_params, invocation) {
        try {
            await this._ext._checkCaller(invocation.get_sender());
            this._stop();
            invocation.return_value(null);
        } catch (e) {
            invocation.return_dbus_error(e.dbusName ?? 'dev.shotlet.Shell1.Error.Failed', e.message);
        }
    }

    _error(name, message) {
        const e = new Error(message);
        e.dbusName = `dev.shotlet.Shell1.Error.${name}`;
        return e;
    }

    async _start(sender, o) {
        const area = {x: o.x | 0, y: o.y | 0, w: o.w | 0, h: o.h | 0};
        if (area.w <= 0 || area.h <= 0)
            throw this._error('Invalid', 'empty area');
        const rec = {sender, area, session: null, watch: 0, actors: [], eventId: 0, indicator: null};
        this._rec = rec;
        try {
            const [session] = (await mutterCall('/org/gnome/Mutter/ScreenCast', MUTTER,
                'CreateSession', new GLib.Variant('(a{sv})', [{}]), '(o)')).deepUnpack();
            rec.session = session;
            const [stream] = (await mutterCall(session, `${MUTTER}.Session`, 'RecordArea',
                new GLib.Variant('(iiiia{sv})', [area.x, area.y, area.w, area.h, {
                    'is-recording': new GLib.Variant('b', true),
                    'cursor-mode': new GLib.Variant('u', o.cursor === false ? 0 : 1),
                }]), '(o)')).deepUnpack();
            const node = await new Promise((resolve, reject) => {
                const id = Gio.DBus.session.signal_subscribe(MUTTER, `${MUTTER}.Stream`,
                    'PipeWireStreamAdded', stream, null, Gio.DBusSignalFlags.NONE,
                    (_c, _s, _p, _i, _n, args) => {
                        Gio.DBus.session.signal_unsubscribe(id);
                        resolve(args.deepUnpack()[0]);
                    });
                mutterCall(session, `${MUTTER}.Session`, 'Start', null, null).catch(e => {
                    Gio.DBus.session.signal_unsubscribe(id);
                    reject(e);
                });
            });
            // the screencast never outlives the Shotlet that asked for it
            rec.watch = Gio.bus_watch_name_on_connection(Gio.DBus.session, sender,
                Gio.BusNameWatcherFlags.NONE, null, () => {
                    if (this._rec === rec)
                        this._stop();
                });
            this._decorate(rec, o);
            console.log(`Shotlet: recording ${area.w}x${area.h}+${area.x}+${area.y} (node ${node})`);
            return node;
        } catch (e) {
            if (this._rec === rec)
                this._stop();
            throw e;
        }
    }

    _stop() {
        const rec = this._rec;
        if (!rec)
            return;
        this._rec = null;
        if (rec.watch)
            Gio.bus_unwatch_name(rec.watch);
        if (rec.eventId)
            global.stage.disconnect(rec.eventId);
        for (const a of rec.actors)
            a.destroy();
        rec.indicator?.destroy();
        if (rec.session)
            mutterCall(rec.session, `${MUTTER}.Session`, 'Stop', null, null).catch(() => {});
        console.log('Shotlet: recording stopped');
    }

    // --- what is drawn while recording

    _decorate(rec, o) {
        this._outline(rec);
        this._indicator(rec);
        if (o.clicks || o.keys) {
            rec.eventId = global.stage.connect('captured-event', (_a, ev) => {
                const t = ev.type();
                if (o.clicks && t === Clutter.EventType.BUTTON_PRESS)
                    this._ripple(rec, ...ev.get_coords());
                else if (o.keys && t === Clutter.EventType.KEY_PRESS)
                    this._key(rec, ev);
                return Clutter.EVENT_PROPAGATE;
            });
        }
    }

    _add(rec, actor) {
        Main.layoutManager.uiGroup.add_child(actor);
        rec.actors.push(actor);
        return actor;
    }

    // just outside the area: never in the recording
    _outline(rec) {
        const {x, y, w, h} = rec.area;
        const b = 2;
        const covers = Main.layoutManager.monitors.some(m =>
            m.x === x && m.y === y && m.width === w && m.height === h);
        if (covers)
            return;
        this._add(rec, new St.Widget({
            x: x - b, y: y - b, width: w + 2 * b, height: h + 2 * b,
            style: `border: ${b}px solid rgba(255,59,48,0.9); border-radius: 1px;`,
            reactive: false,
        }));
    }

    _indicator(rec) {
        const button = new St.Button({
            style_class: 'panel-button',
            reactive: true,
            can_focus: true,
            child: new St.Label({text: '● Stop', style: 'color: #ff453a; font-weight: bold;', y_align: Clutter.ActorAlign.CENTER}),
        });
        button.connect('clicked', () => this.requestStop());
        Main.panel._rightBox.insert_child_at_index(button, 0);
        rec.indicator = button;
    }

    _ripple(rec, x, y) {
        const {area} = rec;
        if (x < area.x || y < area.y || x >= area.x + area.w || y >= area.y + area.h)
            return;
        const r = 22;
        const dot = this._add(rec, new St.Widget({
            x: x - r, y: y - r, width: 2 * r, height: 2 * r,
            style: `background-color: rgba(10,132,255,0.35); border: 3px solid rgba(10,132,255,0.9); border-radius: ${r}px;`,
            reactive: false,
            pivot_point: new Graphene.Point({x: 0.5, y: 0.5}),
        }));
        dot.set_scale(0.4, 0.4);
        dot.ease({
            scale_x: 1.2, scale_y: 1.2, opacity: 0,
            duration: RIPPLE_MS, mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => this._drop(rec, dot),
        });
    }

    _key(rec, ev) {
        const text = keyLabel(ev);
        if (!text)
            return;
        const {area} = rec;
        rec.keyLabel?.destroy();
        const label = this._add(rec, new St.Label({
            text,
            style: 'background-color: rgba(28,28,30,0.82); color: white; font-size: 20px; font-weight: bold; padding: 8px 16px; border-radius: 12px;',
            reactive: false,
        }));
        rec.keyLabel = label;
        // bottom centre of the area
        const [, w] = label.get_preferred_width(-1);
        const [, h] = label.get_preferred_height(w);
        label.set_position(Math.round(area.x + (area.w - w) / 2), area.y + area.h - h - 24);
        label.ease({
            opacity: 0, delay: KEY_HUD_MS, duration: 250, mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => this._drop(rec, label),
        });
    }

    _drop(rec, actor) {
        const i = rec.actors.indexOf(actor);
        if (i >= 0) {
            rec.actors.splice(i, 1);
            actor.destroy();
        }
        if (rec.keyLabel === actor)
            rec.keyLabel = null;
    }
}

const MOD_KEYS = new Set(['Control_L', 'Control_R', 'Shift_L', 'Shift_R', 'Alt_L', 'Alt_R', 'Super_L', 'Super_R', 'Meta_L', 'Meta_R', 'ISO_Level3_Shift']);
const NAMES = {Return: '⏎', space: 'Space', BackSpace: '⌫', Escape: 'Esc', Tab: '⇥', Delete: 'Del', Up: '↑', Down: '↓', Left: '←', Right: '→'};

// "Ctrl+Shift+S", "⏎", "a"; null for a modifier alone
export function keyLabel(ev) {
    const sym = ev.get_key_symbol();
    const name = Clutter.keyval_name(sym) ?? '';
    if (MOD_KEYS.has(name))
        return null;
    const st = ev.get_state();
    const mods = [];
    if (st & Clutter.ModifierType.CONTROL_MASK)
        mods.push('Ctrl');
    if (st & Clutter.ModifierType.MOD1_MASK)
        mods.push('Alt');
    if (st & Clutter.ModifierType.SUPER_MASK)
        mods.push('Super');
    const ch = String.fromCodePoint(Clutter.keysym_to_unicode(sym) || 0);
    let key = NAMES[name] ?? (ch > ' ' ? ch : name);
    if (mods.length > 0 && key.length === 1)
        key = key.toUpperCase();
    if (st & Clutter.ModifierType.SHIFT_MASK && (mods.length > 0 || key.length > 1))
        mods.push('Shift');
    return [...mods, key].join('+');
}
