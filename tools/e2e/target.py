#!/usr/bin/python3
# A stand-in for "another app" in the e2e tests: a maximized GTK 4 window
# with a text entry (keyboard focus), a click area and a drop target for
# image/png and text/uri-list. Reports on stdout, one line per event:
#   active True|False      window focus changed
#   text STRING            the entry's text changed
#   click X Y              a primary click on the window
#   drop MIME BYTES HEAD   a drop was read (HEAD: first bytes, hex or text)
# usage: target.py [MIME...]   types to ask for on drop, best first
import sys
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

PREFER = sys.argv[1:] or ["image/png", "text/uri-list"]


def out(*parts):
    print(*parts, flush=True)


class Target(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.shotlet.E2eTarget", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title="e2e target")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        entry = Gtk.Entry()
        entry.connect("changed", lambda e: out("text", e.get_text()))
        box.append(entry)
        area = Gtk.Label(label="drop here", vexpand=True, hexpand=True)
        box.append(area)
        win.set_child(box)

        click = Gtk.GestureClick()
        click.connect("pressed", self.on_click, win)
        win.add_controller(click)

        formats = Gdk.ContentFormats.new(PREFER)
        drop = Gtk.DropTargetAsync.new(formats, Gdk.DragAction.COPY)
        drop.connect("accept", lambda t, d: True)
        drop.connect("drag-enter", lambda t, d, x, y: Gdk.DragAction.COPY)
        drop.connect("drag-motion", lambda t, d, x, y: Gdk.DragAction.COPY)
        drop.connect("drop", self.on_drop)
        win.add_controller(drop)

        win.connect("notify::is-active", lambda w, _p: out("active", w.is_active()))
        win.maximize()
        win.present()
        entry.grab_focus()

    def on_click(self, gesture, _n, x, y, win):
        # translate to window coordinates (the window is maximized)
        out("click", int(x), int(y))

    def on_drop(self, _target, drop, _x, _y):
        def got(d, res):
            try:
                stream, mime = d.read_finish(res)
                data = b""
                while True:
                    chunk = stream.read_bytes(65536, None).get_data()
                    if not chunk:
                        break
                    data += chunk
                head = data[:8].hex() if mime == "image/png" else data.decode(errors="replace").strip()
                out("drop", mime, len(data), head)
                d.finish(Gdk.DragAction.COPY)
            except GLib.Error as e:
                out("drop-error", e.message)
                d.finish(0)

        drop.read_async(PREFER, GLib.PRIORITY_DEFAULT, None, got)
        return True


Target().run([])
