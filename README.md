# Shotlet

Fast screenshot tool for **Linux on Wayland** with a Flameshot-style
annotation editor. Written in Zig, zero build dependencies — it speaks the
Wayland and DBus wire protocols directly.

- Instant capture (~0.3s) via the ScreenCast portal + PipeWire, with a
  Screenshot-portal fallback. One consent dialog ever.
- Multi-monitor: every monitor you share in the picker is captured and
  laid out as on your desktop, at the sharpest monitor's pixel density.
- Region selection (with a magnifier), then annotate: pencil, line, arrow,
  rectangle (outline, filled, rounded), ellipse, highlighter, blur,
  pixelate, solid redaction, counter badges, editable multi-line text.
  Every annotation can be selected again to move, resize, recolour or
  delete. Undo/redo, 11 colours plus a custom picker, mouse-wheel size,
  and a "beautify" frame (gradient, solid or transparent background,
  padding, rounded corners, shadow).
- One floating toolbar in a translucent, blurred material; colour, size
  and style in a popover, the rest under More. Light or dark and the
  accent colour follow the desktop (Settings portal), and transitions
  stop when the desktop asks for reduced motion.
- Copies straight to the clipboard (nothing written to disk), saves to
  your Pictures folder, or asks where to save (Save As, through the
  desktop's file chooser). `Enter`/`Ctrl+C` copy and close, `Ctrl+S`
  save, `Esc` cancels then quits. Saved files are named `shotlet-YYYYMMDD-HHMMSS.png` in local
  time and never overwrite an existing file (`-2`, `-3`, ... are added).
- After Copy or Save, a floating thumbnail (as in CleanShot X) stays in
  the bottom-left corner for a few seconds: copy it again, save it, drag
  it into any app, annotate it again, pin it to the screen. Every copied
  or saved capture is kept in a Recent captures panel.
- Tray icon with menu, and a Settings window (general, editor and
  shortcut views) with rebindable shortcuts and a save folder picker.

Shotlet was called **cliptux** until its rename; settings in
`~/.config/cliptux` (or `$XDG_CONFIG_HOME/cliptux`) are moved to the new
place on first run.

Built GNOME-first (where grim/slurp/flameshot struggle); any compositor
with the standard portals should work.

## Install

Requires Zig 0.17 to build. At runtime: a Wayland session with
xdg-desktop-portal (PipeWire recommended for fast capture).

```sh
zig build -Doptimize=safe
./install.sh               # into ~/.local; --autostart starts the tray at login
./uninstall.sh             # removes it again (settings and history are kept)
```

`install.sh` puts `shotlet` in `~/.local/bin`, its desktop entry
(`io.github.midnattsol.Shotlet.desktop`) and icon in `~/.local/share`, and
on GNOME offers the Shell integration (`--gnome-extension` /
`--no-gnome-extension` to answer up front). Or grab a prebuilt binary
(x86_64 / arm64) from the [releases](../../releases) page — built against
glibc 2.31, so they run on any distro from around 2020 onward (Ubuntu
20.04+, Debian 11+, etc.); the tarball has the same `install.sh`.

Shotlet's app id is `io.github.midnattsol.Shotlet`. It tells
xdg-desktop-portal so at start (the portal's `Registry`, 1.19 and later;
older portals learn it from a systemd scope), which is what lets GNOME
remember the screen-sharing and screenshot consent however Shotlet is
started. Consent given to versions before this id is not carried over:
expect to be asked once more after updating.

## Usage

```sh
shotlet            # capture + editor
shotlet --daemon   # tray icon (autostart: ./install.sh --autostart)
shotlet settings   # preferences and shortcut bindings
```

Tip: bind a key to `shotlet` in GNOME Settings > Keyboard > Custom Shortcuts
(on GNOME, the integration below brings its own shortcut).

```sh
shotlet history                       # Recent captures (history clear: forget them)
shotlet pin FILE.png                  # pin an image to the screen
shotlet gnome-integration install     # GNOME: no prompts; thumbnail and pins above
shotlet gnome-integration shortcut '<Shift><Super>s'   # its capture key
```

## After a capture

After Copy or Save the editor closes and a 240×150 thumbnail appears in
the bottom-left corner for 8 seconds (longer while the pointer is on it);
later captures stack above it. On hover:

| Control | Action |
| --- | --- |
| Copy / Save | copy to the clipboard again / save to the screenshots folder |
| right-click | menu, with Save As... |
| pencil | annotate: reopens the editor with the annotations still editable |
| pin | pin the capture to the screen |
| × | close |
| drag | drop the image into any app (offered as `image/png` and as a file, `text/uri-list`) |

Keyboard (after clicking it): `Ctrl+C`, `Ctrl+S`, `Ctrl+Shift+S`, `E`
annotate, `P` pin, `Esc`/`Delete` close, `Tab` and `Enter` to reach every
button. Turn it off with `quick_access=false` (Copy and Save then behave as
before); `quick_access_seconds=8` sets how long it stays.

**Pins** show the capture at 1:1 in a frameless window: scroll (or `-`
`=` `0`) to zoom, drag to move, `Esc` or the × to close. Any number of
them.

**Recent captures** (`shotlet history`, or the tray menu) lists the last
captures that were copied or saved, newest first, with when they were
taken. Pick one to copy, save, annotate, pin or delete it (`Enter` copies,
`Delete` removes); "Clear" empties the history. When Tesseract is
installed (`libtesseract.so.5`, plus its language data, e.g.
`tesseract-ocr-eng`), captures are read in the background and a search
field finds them by their text (`SHOTLET_OCR_LANG=eng+spa` for other
languages); without it there is no search field. Settings: `history=false`
keeps nothing, `history_max=50` captures and `history_max_mb=500` cap it.
All of these are also in `shotlet settings` (General), with Clear history
and the GNOME integration's state.

### Where the floating windows go (and GNOME)

A Wayland app cannot place its own window or keep it above others.
Compositors with the `wlr-layer-shell` protocol (KDE Plasma, Sway,
Hyprland, and other wlroots compositors) let Shotlet put the thumbnail in
an overlay layer anchored to the bottom-left corner, never taking the
keyboard unless clicked, and pins in the top layer; that is used
automatically.

GNOME's mutter has no such protocol (and will not add it), so Shotlet
ships a small GNOME Shell extension (`gnome-extension/`, GNOME 45 to 50)
that does it for Shotlet's windows only: it places the thumbnail
bottom-left on the monitor under the pointer, keeps it and pins above
other windows on every workspace, leaves them out of Alt+Tab, and hands the keyboard focus straight
back to the app you were in when the thumbnail appears. Install it with
`shotlet gnome-integration install` (or the link on the thumbnail):
GNOME Shell on Wayland only picks up a newly installed extension at your
next login. `shotlet gnome-integration status` tells whether it is active.

### Captures without prompts on GNOME

With the extension active, capturing never shows a consent dialog:
installing the extension is the consent. The extension takes the
screenshot itself, inside GNOME Shell, and starts Shotlet's editor on it:

- **Its own shortcut**, `capture-shortcut` in its settings, default
  `Print`. On stock GNOME, Print opens GNOME's screenshot tool:
  `shotlet gnome-integration install` offers to give Print to Shotlet
  (it asks on a terminal, yes by default; the Enable button in Settings
  just does it and says so), moving GNOME's screenshot tool to
  Shift+Super+S when nothing else uses that key. Only the GNOME shortcuts
  holding Print change, what they held is remembered
  (`~/.config/shotlet/gnome-moved-keys`), and `uninstall` restores them
  exactly. Decline, and the extension leaves the key alone and binds
  nothing (Settings and `status` say so); pick another key with
  `shotlet gnome-integration shortcut '<Shift><Super>s'` (`none` for no
  key). install also finds custom shortcuts that run `shotlet`, offers
  to move them to the extension's key, and `uninstall` puts them back.
- **`shotlet` and the tray's Take screenshot** ask the extension
  (`dev.shotlet.Shell1.Capture()`), so they need no prompt either.

How it stays safe: no D-Bus method returns screen contents. `Capture()`
only starts the same flow, which ends in Shotlet's editor on screen; it is
honoured only for a caller whose executable is the shotlet binary the
extension starts, one capture at a time and at most one a second, never
while the screen is locked. The pixels go from
`Shell.Screenshot.screenshot_area` (every monitor at its own scale, a few
strips of it encoded in parallel; no cursor, and no flash or shutter
sound: those belong to GNOME's screenshot UI) into fresh 0600 files in
`$XDG_RUNTIME_DIR/shotlet` (a 0700 directory the extension checks is
its own), and nowhere else; Shotlet opens them without following
symlinks, refuses files that are not private and its own, and deletes
them as soon as they are read (leftovers from a Shotlet that failed to
start are deleted after a minute). Sandboxed (Flatpak) apps cannot reach
the extension's bus name or that directory.

When the extension is missing, older, or cannot capture, Shotlet uses the
screen-sharing portal as before. `shotlet gnome-integration status` and
Settings › General say which way captures go.

Timings in the private headless GNOME (software rendering, release
build), from the key press to the editor on screen, through the
extension: one 1600×900 monitor 68–75 ms (40–45 ms of it in the shell);
2560×1440 at 2 next to 1280×720 at 1, about 230 ms. The portal path with
its remembered grant takes 52–66 ms and about 225 ms from the start of
`shotlet` (plus launching it, and GNOME's screen-sharing indicator
flashes), and seconds with its dialog the first time.

Without the extension everything still works, but the thumbnail is an
ordinary window wherever GNOME opens it (and it takes the keyboard focus,
as any new window does), and a pin stays above other windows only if you
choose "Always on Top" in its window menu (right-click the pin). The
thumbnail never covers more than itself: around the cards it lets clicks
through to the window below.

On GNOME the tray needs the AppIndicator extension. Without the GNOME
integration, the first capture shows
a one-time screen-share picker: select every monitor you want captured.
The choice is remembered. Cancelling the picker just ends the capture.

## Editor shortcuts

Defaults follow CleanShot X and Flameshot where they agree; the tool keys
and the main actions can be rebound in `shotlet settings`. Press `?` in
the editor for the full list.

| Key | Action |
| --- | --- |
| Drag | select a region (`Shift` square, `Alt` from the centre, hold `Space` to move it) |
| `Enter` / `Ctrl+C` | copy to the clipboard and close |
| `Ctrl+S` / `Ctrl+Shift+S` | save / save as |
| `Esc` / right click | cancel the current action; `Esc` again closes |
| `V` `P` `L` `A` `R` `E` `M` | select, pen, line, arrow, rectangle, ellipse, marker |
| `X` (again) | blur, then pixelate, then solid redaction |
| `N` `T` | counter badge, text |
| `F` | outline / filled / rounded (text: background) |
| `B` | beautify frame |
| `1`-`8`, `9` | preset colours, custom colour |
| wheel, `-` `=` | size |
| `Shift` while drawing | square, circle, 45° lines and arrows (`Alt`: from the centre) |
| arrows, `Shift`+arrows | move the selection or shape by 1 / 10 px (`Alt`: resize) |
| `Delete`, `Ctrl+D`, `Ctrl+]` | delete, duplicate, bring to front |
| `Ctrl+Z` / `Ctrl+Shift+Z`, `Ctrl+Y` | undo / redo |
| `Tab`, `Enter` | move through the toolbar, activate |
| Text: `Ctrl+Enter` or `Esc` | finish editing (`Enter` is a new line) |

## Files

| What | Where |
| --- | --- |
| Settings | `$XDG_CONFIG_HOME/shotlet/config` (default `~/.config/shotlet/config`), mode 0600 |
| Daemon log | `$XDG_STATE_HOME/shotlet/daemon.log` (default `~/.local/state/shotlet`), rotated at 1 MiB |
| Screenshots | the `save_dir` setting, else your XDG Pictures folder (`XDG_PICTURES_DIR` / `user-dirs.dirs`), else `~/Pictures` |
| Recent captures | `$XDG_STATE_HOME/shotlet/history/<id>/`: `image.png`, `thumb.png`, `meta` (time, size, saved path, recognised text), `source.png` + `doc` (to annotate again); private (0700/0600) |
| Thumbnails with the history off, dragged files | `$XDG_CACHE_HOME/shotlet/` (`quick/`, `drag/`) |
| GNOME Shell extension | `~/.local/share/gnome-shell/extensions/shotlet@midnattsol.github.io` |

The settings file is plain `key=value`. Shotlet only rewrites the keys it
changes, so editing it by hand while Shotlet runs is safe.

## Tests

```sh
zig build test --summary all   # unit tests (+ a portal test on a private dbus-daemon)
zig build e2e                  # end-to-end suite, see below
zig build e2e -- keyboard ime  # only some scenarios
```

The end-to-end suite runs the real binary against real portal dialogs,
PipeWire and the clipboard, inside a private, invisible GNOME session
(`tools/e2e/session.sh`: its own `HOME`, session bus, PipeWire and
`gnome-shell --headless` with virtual monitors). Nothing reaches the desktop
you are logged into. `shotlet-drive` (`tools/e2e/drive.zig`) holds a Mutter
RemoteDesktop session for a virtual keyboard and pointer, and ScreenCast
streams to aim the pointer and screenshot each monitor. `tools/e2e.sh`
prints PASS/FAIL per check and skips when the session cannot run.

Needs `gnome-shell`, `xdg-desktop-portal-gnome`, `pipewire`, `wireplumber`,
`wl-clipboard`, `python3` and `gdbus`; the IME scenario also uses
`ibus-hangul` (skipped without it), and the quick-access scenarios
(`quick`, `quick-plain`, `annotate`, `history`) use Python's GTK 4
bindings for "another app" (`tools/e2e/target.py`: focus, clicks, drops;
`python3-gi gir1.2-gtk-4.0`). They load the bundled GNOME Shell extension
into the private session (`HL_EXTENSIONS`), except `quick-plain`, which
checks the fallback without it. So do the prompt-free capture scenarios:
`shell` (stock bindings: install takes Print, Print captures with no
dialog and nothing in the permission store, the capture files gone and
no PNG written anywhere else, the pixels, a Capture() from another
program refused, uninstall restoring GNOME's keys), `shell-owner`
(a custom shortcut running shotlet on Print, moved and put back),
`shell-mixed` (two monitors at scales 2
and 1, checked across the seam), `shell-tray` (the tray's Activate and
menu, the rate limit) and `shell-terminal` (`shotlet` from a terminal,
and the portal when the extension cannot capture). The portal scenarios
run without the extension. On Debian/Ubuntu:
`apt install gnome-shell xdg-desktop-portal-gnome pipewire wireplumber wl-clipboard ibus-hangul python3-gi gir1.2-gtk-4.0`.
`E2E_OUT=dir` keeps the logs and screenshots of a run. CI runs the suite
nightly and on demand (`.github/workflows/e2e.yml`), never on pull requests.

## License

GPL-3.0 — see [LICENSE](LICENSE).
