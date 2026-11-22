#!/usr/bin/python3
# A long page for the scrolling-capture e2e test: a maximized GTK 4 window
# whose scrolled view holds LEN pixels of bands, each with its own colour
# and a block at its own x (no two rows alike), and one magenta marker
# band in the middle. Prints "viewport H" (the visible height of the page)
# and "scrolled Y" as it scrolls.
# usage: scrolltarget.py [LEN [CTL]]
# CTL, a file read every 0.1 s, makes the page misbehave for the stop
# reasons of a scrolling capture: "lock" (the wheel does nothing),
# "jump" (each notch jumps two views on: nothing lines up), "goto Y"
# (scroll to Y, once per change); anything else, or no file: normal.
import sys
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

LEN = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
CTL = sys.argv[2] if len(sys.argv) > 2 else None
BAND = 50
MARKER = (LEN // 2 // BAND) * BAND  # the marker band starts here
MARKER_H = 30


def out(*parts):
    print(*parts, flush=True)


def band_colour(i):
    return ((i * 67) % 200 + 30) / 255, ((i * 131) % 200 + 30) / 255, ((i * 29) % 200 + 30) / 255


def draw(_area, cr, width, height):
    for i in range(0, LEN // BAND + 1):
        y = i * BAND
        cr.set_source_rgb(*band_colour(i))
        cr.rectangle(0, y, width, BAND)
        cr.fill()
        # a dark block whose position changes with every row of the band
        cr.set_source_rgb(0.05, 0.05, 0.05)
        for k in range(BAND):
            cr.rectangle((i * 37 + k * 11) % max(1, width - 40), y + k, 24, 1)
        cr.fill()
    cr.set_source_rgb(1, 0, 1)
    cr.rectangle(0, MARKER, width, MARKER_H)
    cr.fill()


class Control:
    def __init__(self, adj):
        self.adj = adj
        self.mode = ""
        self.last = None

    def poll(self):
        try:
            with open(CTL) as f:
                cmd = f.read().strip()
        except OSError:
            cmd = ""
        if cmd != self.last:
            self.last = cmd
            out("control", cmd or "-")
            if cmd.startswith("goto "):
                self.adj.set_value(int(cmd.split()[1]))
        self.mode = cmd
        return GLib.SOURCE_CONTINUE

    def scroll(self, _ctl, _dx, dy):
        if self.mode == "lock":
            return True
        if self.mode == "jump" and dy > 0:
            a = self.adj
            a.set_value(min(a.get_upper() - a.get_page_size(), a.get_value() + 2 * a.get_page_size()))
            return True
        return False


class Page(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="org.shotlet.E2eScroll", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def do_activate(self):
        win = Gtk.ApplicationWindow(application=self, title="e2e page")
        sw = Gtk.ScrolledWindow()
        area = Gtk.DrawingArea(content_height=LEN, hexpand=True)
        area.set_draw_func(draw)
        sw.set_child(area)
        win.set_child(sw)
        adj = sw.get_vadjustment()
        adj.connect("notify::page-size", lambda a, _p: out("viewport", int(a.get_page_size())))
        adj.connect("value-changed", lambda a: out("scrolled", int(a.get_value())))
        if CTL:
            self.ctl = Control(adj)
            GLib.timeout_add(100, self.ctl.poll)
            wheel = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.VERTICAL)
            wheel.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            wheel.connect("scroll", self.ctl.scroll)
            win.add_controller(wheel)
        win.maximize()
        win.present()


Page().run([])
