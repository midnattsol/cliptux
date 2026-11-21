#!/usr/bin/python3
# A stand-in for "another app" in the e2e tests: a maximized GTK 4 window
# with a text entry (keyboard focus), a click area and a drop target for
# image/png and text/uri-list. Reports on stdout, one line per event:
#   active True|False      window focus changed
#   text STRING            the entry's text changed
#   click X Y              a primary click on the window
#   drop texture W H       an image was dropped (read as image/png)
#   drop files PATH...     files were dropped (text/uri-list)
#   drag begin|end         a drag of FILE out of it started or ended
# usage: target.py [MIME...]   types to ask for on drop, best first
#        target.py --source FILE   offers FILE (text/uri-list) to drag out
import sys
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, GObject, Gtk  # noqa: E402

SOURCE = sys.argv[2] if sys.argv[1:2] == ["--source"] else None
PREFER = [] if SOURCE else sys.argv[1:] or ["image/png", "text/uri-list"]


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

        # the way apps take dropped images: as a texture or as files
        drop = Gtk.DropTarget.new(GObject.TYPE_NONE, Gdk.DragAction.COPY)
        types = {"image/png": Gdk.Texture, "text/uri-list": Gdk.FileList}
        drop.set_gtypes([types[m].__gtype__ for m in PREFER if m in types])
        drop.connect("drop", self.on_drop)
        win.add_controller(drop)

        if SOURCE:
            self.add_source(area)
        win.connect("notify::is-active", lambda w, _p: out("active", w.is_active()))
        win.maximize()
        win.present()
        entry.grab_focus()

    def add_source(self, widget):
        files = Gdk.FileList.new_from_list([Gio.File.new_for_path(SOURCE)])
        src = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        src.set_content(Gdk.ContentProvider.new_for_value(files))
        src.connect("drag-begin", lambda *_: out("drag begin"))
        src.connect("drag-end", lambda *_: out("drag end"))
        widget.add_controller(src)

    def on_click(self, gesture, _n, x, y, win):
        # translate to window coordinates (the window is maximized)
        out("click", int(x), int(y))

    def on_drop(self, _target, value, _x, _y):
        if isinstance(value, Gdk.Texture):
            out("drop texture", value.get_width(), value.get_height())
        elif isinstance(value, Gdk.FileList):
            out("drop files", " ".join(f.get_path() or "" for f in value.get_files()))
        else:
            out("drop other", type(value).__name__)
        return True


Target().run([])
